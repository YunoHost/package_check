import sys
import json
import os
import time
import imgkit

def load_tests(test_folder):

    for test in sorted(os.listdir(test_folder + "/tests")):

        j = json.load(open(test_folder + "/tests/" + test))
        j["id"] = os.path.basename(test).split(".")[0]
        j["results"] = json.load(open(test_folder + "/results/" + j["id"] + ".json"))
        j["notes"] = list(test_notes(j))

        yield j


# We'll laterdisplay the result of these sort of "meta" or "tranversal" checks performed during each checks
# regarding nginx path traversal issue or install dir permissions... we want to display those in the summary
# Also we want to display the number of warnings for linter results
def test_notes(test):

    # (We ignore these for upgrades from older commits)
    if test["test_type"] == "TEST_UPGRADE" and test["test_arg"]:
        return

    if test["test_type"] == "PACKAGE_LINTER" and test['results']['main_result'] == 'success' and test['results'].get("warning"):
        yield '<style=warning>%s warnings</style>' % len(test['results'].get("warning"))

    if test["test_type"] == "PACKAGE_LINTER" and test['results']['main_result'] == 'success' and test['results'].get("info"):
        yield '%s possible improvements' % len(set(test['results'].get("info")))

    if test['results'].get("witness"):
        yield '<style=danger>Missing witness file</style>'

    if test['results'].get("alias_traversal"):
        yield '<style=danger>Nginx path traversal issue</style>'

    if test['results'].get("too_many_warnings"):
        yield '<style=warning>Bad UX because shitload of warnings</style>'

    if test['results'].get("install_dir_permissions"):
        yield '<style=danger>Unsafe install dir permissions</style>'


levels = []


def level(level_, descr):
    def decorator(f):
        f.descr = descr
        f.level = level_
        levels.insert(level_, f)
        return f
    return decorator


###############################################################################


@level(0, "Broken")
def level_0(tests):
    return True


@level(1, "Installable in at least one scenario")
def level_1(tests):
    """
    Any install test succeded
    And there are no critical issues in the linter
    """

    linter_tests = [t for t in tests if t["test_type"] == "PACKAGE_LINTER"]
    install_tests = [t for t in tests if t["test_type"] == "TEST_INSTALL"]
    witness_missing_detected = any(t["results"].get("witness") for t in tests)

    return linter_tests != [] \
        and linter_tests[0]["results"]["critical"] == [] \
        and not witness_missing_detected \
        and any(t["results"]["main_result"] == "success" for t in install_tests)


@level(2, "Installable in all scenarios")
def level_2(tests):
    """
    All install tests succeeded (and at least one test was made)
    """

    install_tests = [t for t in tests if t["test_type"] == "TEST_INSTALL"]

    return install_tests != [] \
        and all(t["results"]["main_result"] == "success" for t in install_tests)


@level(3, "Can be upgraded")
def level_3(tests):
    """
    All upgrade tests succeeded (and at least one test was made)
    """

    upgrade_same_version_tests = [t for t in tests if t["test_type"] == "TEST_UPGRADE" and not t["test_arg"]]

    return upgrade_same_version_tests != [] \
        and all(t["results"]["main_result"] == "success" for t in upgrade_same_version_tests)


@level(4, "Can be backup/restored")
def level_4(tests):
    """
    All backup/restore tests succeded (and at least one test was made)
    """

    backup_tests = [t for t in tests if t["test_type"] == "TEST_BACKUP_RESTORE"]

    return backup_tests != [] \
        and all(t["results"]["main_result"] == "success" for t in backup_tests)


@level(5, "No linter errors")
def level_5(tests):
    """
    Linter returned no errors (= main_result is success)
    and no alias/path traversal issue detected during tests
    and not too many warnings in log outputs
    """

    alias_traversal_detected = any(t["results"].get("alias_traversal") for t in tests)
    linter_tests = [t for t in tests if t["test_type"] == "PACKAGE_LINTER"]

    return not alias_traversal_detected \
        and linter_tests != [] \
        and linter_tests[0]["results"]["main_result"] == "success"


@level(6, "App is in a community-operated git org")
def level_6(tests):
    """
    The app is in the Yunohost-Apps organization
    (the linter will report a warning named "is_in_github_org" if it's not)
    """

    linter_tests = [t for t in tests if t["test_type"] == "PACKAGE_LINTER"]

    return linter_tests != [] \
        and "is_in_github_org" not in linter_tests[0]["results"]["warning"]


@level(7, "Pass all tests + no linter warnings")
def level_7(tests):
    """
    All tests succeeded + no warning in linter (that part is tested by the
    linter which will report a "qualify_for_level_7" in successes)
    """

    linter_tests = [t for t in tests if t["test_type"] == "PACKAGE_LINTER"]
    
    # For runtime warnings, ignore stuff happening during upgrades from previous versions
    tests_on_which_to_check_for_runtime_warnings = [t for t in tests if not (t["test_type"] == "TEST_UPGRADE" and t["test_arg"])]
    too_many_warnings = any(t["results"].get("too_many_warnings") for t in tests_on_which_to_check_for_runtime_warnings)
    unsafe_install_dir_perms = any(t["results"].get("install_dir_permissions") for t in tests_on_which_to_check_for_runtime_warnings)
    alias_traversal = any(t["results"].get("alias_traversal") for t in tests_on_which_to_check_for_runtime_warnings)
    witness = any(t["results"].get("witness") for t in tests_on_which_to_check_for_runtime_warnings)

    return all(t["results"]["main_result"] == "success" for t in tests) \
        and linter_tests != [] \
        and not witness \
        and not alias_traversal \
        and not too_many_warnings \
        and not unsafe_install_dir_perms \
        and "App.qualify_for_level_7" in linter_tests[0]["results"]["success"]


@level(8, "Maintained and long-term good quality")
def level_8(tests):
    """
    App is maintained and long-term good quality (this is tested by the linter
    which will report a "qualify_for_level_8")
    """

    linter_tests = [t for t in tests if t["test_type"] == "PACKAGE_LINTER"]

    return linter_tests != [] \
        and "App.qualify_for_level_8" in linter_tests[0]["results"]["success"]


@level(9, "Flagged high-quality in app catalog")
def level_9(tests):
    """
    App is flagged high-quality in the app catalog (this is tested by the linter
    which will rpeort a "qualify_for_level_9")
    """
    linter_tests = [t for t in tests if t["test_type"] == "PACKAGE_LINTER"]

    return linter_tests != [] \
        and "App.qualify_for_level_9" in linter_tests[0]["results"]["success"]


def make_summary():

    test_types = {
        "PACKAGE_LINTER": "Package linter",
        "TEST_INSTALL": "Install",
        "TEST_UPGRADE": "Upgrade",
        "TEST_BACKUP_RESTORE": "Backup/restore",
        "TEST_CHANGE_URL": "Change url",
        "TEST_PORT_ALREADY_USED": "Port already used",
        "ACTIONS_CONFIG_PANEL": "Config/panel"
    }

    latest_test_serie = "default"
    yield ""
    for test in tests:
        test_display_name = test_types[test["test_type"]]
        if test["test_arg"]:
            test_display_name += " (%s)" % test["test_arg"][:8]
        test_display_name += ":"
        if test["test_serie"] != latest_test_serie:
            latest_test_serie = test["test_serie"]
            yield "------------- %s -------------" % latest_test_serie

        result = " <style=success>OK</style>" if test["results"]["main_result"] == "success" else "<style=danger>fail</style>"

        if test["notes"]:
            result += "  (%s)" % ', '.join(test["notes"])

        yield "{test: <30}{result}".format(test=test_display_name, result=result)

    yield ""
    yield "Level results"
    yield "============="

    stop_global_level_bump = False

    global global_level
    global_level = level_0

    for level in levels[1:]:
        level.passed = level(tests)

        if not level.passed:
            stop_global_level_bump = True

        if not stop_global_level_bump:
            global_level = level
            display = " <style=success>OK</style>"
        else:
            display = " ok " if level.passed else ""

        yield "Level {i} {descr: <40} {result}".format(i=level.level,
                                                       descr="(%s)" % level.descr[:38],
                                                       result=display)

    yield ""
    yield "<style=bold>Global level for this application: %s (%s)</style>" % (global_level.level, global_level.descr)
    yield ""


def render_for_terminal(text):
    return text \
            .replace("<style=success>", "\033[1m\033[92m") \
            .replace("<style=warning>", "\033[93m") \
            .replace("<style=danger>", "\033[91m") \
            .replace("<style=bold>", "\033[1m") \
            .replace("</style>", "\033[0m")


def export_as_image(text, output):
    text = text \
            .replace("<style=success>", '<span style="color: chartreuse; font-weight: bold;">') \
            .replace("<style=warning>", '<span style="color: gold;">') \
            .replace("<style=danger>", '<span style="color: red;">') \
            .replace("<style=bold>", '<span style="font-weight: bold;">') \
            .replace("</style>", '</span>')

    text = f"""
<html style="color: #eee; background-color: #222; font-family: monospace">
<body>
<pre>
{text}
</pre>
</body>
</html>"""

    imgkit.from_string(text, output, options={"crop-w": 600, "quiet": ""})


test_context = sys.argv[1]
tests = list(load_tests(test_context))

global_level = None

summary = '\n'.join(make_summary())
print(render_for_terminal(summary))

if os.path.exists("/usr/bin/wkhtmltoimage"):
    export_as_image(summary, f"{test_context}/summary.png")
    if os.path.exists("/usr/bin/optipng"):
        os.system(f"/usr/bin/optipng --quiet '{test_context}/summary.png'")
else:
    print("(Protip™ for CI admin: you should 'apt install wkhtmltopdf optipng --no-install-recommends' to enable result summary export to .png)")

summary = {
    "app": open(test_context + "/app_id").read().strip(),
    "commit": open(test_context + "/commit").read().strip(),
    "architecture": open(test_context + "/architecture").read().strip(),
    "yunohost_version": open(test_context + "/ynh_version").read().strip(),
    "yunohost_branch": open(test_context + "/ynh_branch").read().strip(),
    "timestamp": int(time.time()),
    "tests": [{
        "test_type": t["test_type"],
        "test_arg": t["test_arg"],
        "test_serie": t["test_serie"],
        "main_result": t["results"]["main_result"],
        "test_duration": t["results"]["test_duration"],
        "test_notes": t["notes"]
    } for t in tests],
    "level_results": {level.level: level.passed for level in levels[1:]},
    "level": global_level.level
}

sys.stderr.write(json.dumps(summary, indent=4))
