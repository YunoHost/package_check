import os
import sys
import toml
import time
import re
import tempfile
import pycurl
from bs4 import BeautifulSoup
from urllib.parse import urlencode, urljoin
from io import BytesIO

DOMAIN = os.environ["DOMAIN"]
DIST = os.environ["DIST"]
SUBDOMAIN = os.environ["SUBDOMAIN"]
USER = os.environ["USER"]
PASSWORD = os.environ["PASSWORD"]
LXC_IP = os.environ["LXC_IP"]
BASE_URL = os.environ["BASE_URL"].rstrip("/")
APP_DOMAIN = BASE_URL.replace("https://", "").replace("http://", "").split("/")[0]

DEFAULTS = {
    "base_url": BASE_URL,
    "path": "/",
    "logged_on_sso": False,
    "expect_title": None,
    "expect_content": None,
    "expect_return_code": 200,
    "expect_effective_url": None,
    "auto_test_assets": False,
}

# Example of expected conf:
# ==============================================
# #home.path = "/"
# home.expect_title = "Login - Nextcloud"
#
# #dash.path = "/"
# dash.logged_on_sso = true
# dash.expect_title = "Tableau de bord - Nextcloud"
#
# admin.path = "/settings/admin"
# admin.logged_on_sso = true
# admin.expect_title = "Paramètres d'administration - Nextcloud"
#
# asset.path = "/core/img/logo/logo.svg"
#
# file.path = "/remote.php/dav/files/__USER__/Readme.md"
# file.logged_on_sso = true
# file.expect_content = "# Welcome to Nextcloud!"
#
# caldav.base_url = "https://yolo.test"
# caldav.path = "/.well-known/caldav"
# caldav.logged_on_sso = true
# caldav.expect_content = "This is the WebDAV interface."
# ==============================================


def curl(
    base_url,
    path,
    method="GET",
    use_cookies=None,
    save_cookies=None,
    post=None,
    referer=None,
):
    domain = base_url.replace("https://", "").replace("http://", "").split("/")[0]

    c = pycurl.Curl()  # curl
    resolved_url = urljoin(base_url, path)
    c.setopt(c.URL, resolved_url)  # https://domain.tld/foo/bar
    c.setopt(c.FOLLOWLOCATION, True)  # --location
    c.setopt(c.SSL_VERIFYPEER, False)  # --insecure
    c.setopt(
        c.RESOLVE,
        [
            f"{DOMAIN}:80:{LXC_IP}",
            f"{DOMAIN}:443:{LXC_IP}",
            f"{SUBDOMAIN}:80:{LXC_IP}",
            f"{SUBDOMAIN}:443:{LXC_IP}",
        ],
    )  # --resolve
    c.setopt(c.HTTPHEADER, [f"Host: {domain}", "X-Requested-With: libcurl"])  # --header
    if use_cookies:
        c.setopt(c.COOKIEFILE, use_cookies)
    if save_cookies:
        c.setopt(c.COOKIEJAR, save_cookies)
    if post:
        c.setopt(c.POSTFIELDS, urlencode(post))
    if referer:
        c.setopt(c.REFERER, referer)
    buffer = BytesIO()
    c.setopt(c.WRITEDATA, buffer)
    c.perform()

    effective_url = c.getinfo(c.EFFECTIVE_URL)
    return_code = c.getinfo(c.RESPONSE_CODE)

    try:
        return_content = buffer.getvalue().decode()
    except UnicodeDecodeError:
        return_content = "(Binary content?)"

    c.close()

    return (return_code, return_content, effective_url, resolved_url)


def test(
    base_url,
    path,
    post=None,
    logged_on_sso=False,
    expect_return_code=200,
    expect_content=None,
    expect_title=None,
    expect_effective_url=None,
    auto_test_assets=False,
):
    domain = base_url.replace("https://", "").replace("http://", "").split("/")[0]
    if logged_on_sso:
        cookies = tempfile.NamedTemporaryFile().name

        if DIST == "bullseye":
            code, content, log_url, _ = curl(
                f"https://{DOMAIN}/yunohost/sso",
                "/",
                save_cookies=cookies,
                post={"user": USER, "password": PASSWORD},
                referer=f"https://{DOMAIN}/yunohost/sso/",
            )
            assert (
                code == 200 and os.system(f"grep -q '{DOMAIN}' {cookies}") == 0
            ), f"Failed to log in: got code {code} or cookie file was empty?"
        else:
            code, content, _, _ = curl(
                f"https://{domain}/yunohost/portalapi",
                "/login",
                save_cookies=cookies,
                post={"credentials": f"{USER}:{PASSWORD}"},
            )
            assert (
                code == 200 and content == "Logged in"
            ), f"Failed to log in: got code {code} and content: {content}"
    else:
        cookies = None

    code = None
    retried = 0
    while code is None or code in {502, 503, 504}:
        time.sleep(retried * 5)
        code, content, effective_url, _ = curl(
            base_url, path, post=post, use_cookies=cookies
        )
        retried += 1
        if retried > 3:
            break

    html = BeautifulSoup(content, features="lxml")

    try:
        title = html.find("title").string
        title = title.strip().replace("\u2013", "-")
    except Exception:
        title = ""

    content = html.find("body")
    content = content.get_text().strip() if content else ""
    content = re.sub(r"[\t\n\s]{3,}", "\n\n", content)

    base_tag = html.find('base')
    base = base_tag['href'] if base_tag else ''

    errors = []
    if expect_effective_url is None and "/yunohost/sso" in effective_url:
        errors.append(
            f"The request was redirected to yunohost's portal ({effective_url})"
        )
    if expect_effective_url and expect_effective_url != effective_url:
        errors.append(
            f"Ended up on URL '{effective_url}', but was expecting '{expect_effective_url}'"
        )
    if expect_return_code and code != expect_return_code:
        errors.append(f"Got return code {code}, but was expecting {expect_return_code}")
    if expect_title is None and "Welcome to nginx" in title:
        errors.append("The request ended up on the default nginx page?")
    if expect_title and not re.search(expect_title, title):
        errors.append(
            f"Got title '{title}', but was expecting something containing '{expect_title}'"
        )
    if expect_content and not re.search(expect_content, content):
        errors.append(
            f"Did not find pattern '{expect_content}' in the page content: '{content[:50]}' (on URL {effective_url})"
        )

    assets = []
    # Auto-check assets - though skip this if we have an unexpected return code for the main page, because there's very likely no asset to find
    if auto_test_assets and code == expect_return_code:
        assets_to_check = []
        stylesheets = html.find_all("link", rel="stylesheet", href=True)
        stylesheets = [
            s
            for s in stylesheets
            if "ynh_portal" not in s["href"]
            and "ynhtheme" not in s["href"]
            and "ynh_overlay" not in s["href"]
        ]
        if stylesheets:
            assets_to_check.append(stylesheets[0]["href"])
        js = html.find_all("script", src=True)
        js = [
            s
            for s in js
            if "ynh_portal" not in s["src"]
            and "ynhtheme" not in s["src"]
            and "ynh_overlay" not in s["src"]
        ]
        if js:
            assets_to_check.append(js[0]["src"])
        if not assets_to_check:
            print(
                "\033[1m\033[93mWARN\033[0m auto_test_assets set to true, but no js/css asset found in this page"
            )
        for asset in assets_to_check:
            # FIXME : this is pretty clumsy, should probably be replaced with a proper URL parsing to serparate domains etc...
            if asset.startswith(f"//"):
                asset = f"https:{asset}"
            if asset.startswith(f"https://") or asset.startswith(f"http://"):
                if asset.startswith(f"https://{domain}"):
                    asset = asset.replace(f"https://{domain}", "")
                else:
                    print(
                        f"\033[1m\033[93mWARN\033[0m Found asset '{asset}' which seems to be hosted on a third party, external website ... Not super great for privacy etc... ?"
                    )
                    continue
            elif asset.startswith(f"{domain}/"):
                asset = asset.replace(f"{domain}/", "")
            if not asset.startswith("/"):
                asset = urljoin(base + "/", asset)
            asset_code, _, effective_asset_url, resolved_url = curl(
                f"https://{domain}", asset, use_cookies=cookies
            )
            if asset_code != 200:
                errors.append(
                    f"Asset https://{resolved_url} (automatically derived from the page's html) answered with code {asset_code}, expected 200? Effective url: {effective_asset_url}"
                )
            assets.append((resolved_url, asset_code))

    return {
        "url": f"{urljoin(base_url, path)}",
        "effective_url": effective_url,
        "code": code,
        "title": title,
        "content": content,
        "assets": assets,
        "errors": errors,
    }


def run(tests):
    results = {}

    for name, params in tests.items():
        full_params = DEFAULTS.copy()
        full_params.update(params)
        for key, value in full_params.items():
            if isinstance(value, str):
                full_params[key] = value.replace("__USER__", USER).replace(
                    "__DOMAIN__", APP_DOMAIN
                )

        results[name] = test(**full_params)
        display_result(results[name])

        if full_params["path"] == "/":
            full_params["path"] = ""
            results[name + "_noslash"] = test(**full_params)

            # Display this result too, but only if there's really a difference compared to the regular test
            # because 99% of the time it's the same as the regular test
            if (
                results[name + "_noslash"]["effective_url"]
                != results[name]["effective_url"]
            ):
                display_result(results[name + "_noslash"])

    return results


def display_result(result):
    if result["effective_url"] != result["url"]:
        print(
            f"URL     : {result['url']}    (redirected to: {result['effective_url']})"
        )
    else:
        print(f"URL     : {result['url']}")
    if result["code"] != 200:
        print(f"Code    : {result['code']}")
    if result["title"].strip():
        print(f"Title   : {result['title'].strip()}")
    print(f"Content extract:\n{result['content'][:100].strip()}")
    if result["assets"]:
        print("Assets  :")
        for asset, code in result["assets"]:
            if code == 200:
                print(f"  - {asset}")
            else:
                print(f"  - \033[1m\033[91mFAIL\033[0m (code {code}) {asset}")
    if result["errors"]:
        print("Errors  :\n    - " + "\n    - ".join(result["errors"]))
        print("\033[1m\033[91mFAIL\033[0m")
    else:
        print("\033[1m\033[92mOK\033[0m")
    print("========")


def main():
    tests = sys.stdin.read()

    if not tests.strip():
        tests = "home.path = '/'"
        tests += "\nhome.auto_test_assets = true"

    tests = toml.loads(tests)
    results = run(tests)

    # If there was at least one error 50x
    if any(str(r["code"]).startswith("5") for r in results.values()):
        sys.exit(5)
    elif any(r["errors"] for r in results.values()):
        sys.exit(1)
    else:
        sys.exit(0)


main()
