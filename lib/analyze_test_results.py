import sys
import json
import os

def load_tests(test_folder):

    for test in sorted(os.listdir(test_folder + "/tests")):

        j = json.load(open(test_folder + "/tests/" + test))
        j["id"] = os.path.basename(test).split(".")[0]
        j["results"] = json.load(open(test_folder + "/results/" + j["id"] + ".json"))
        yield j


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

    upgrade_tests = [t for t in tests if t["test_type"] == "TEST_UPGRADE"]

    return upgrade_tests != [] \
        and all(t["results"]["main_result"] == "success" for t in upgrade_tests)


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
    # linter which will report a "qualify_for_level_7" in successes)
    """

    linter_tests = [t for t in tests if t["test_type"] == "PACKAGE_LINTER"]

    return all(t["results"]["main_result"] == "success" for t in tests) \
        and linter_tests != [] \
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


text_context = sys.argv[1]
tests = list(load_tests(test_context))

test_types = {
    "PACKAGE_LINTER": "Package linter",
    "TEST_INSTALL": "Install",
    "TEST_UPGRADE": "Upgrade",
    "TEST_BACKUP_RESTORE": "Backup/restore",
    "TEST_CHANGE_URL": "Change url",
    "TEST_PORT_ALREADY_USED": "Port already used",
    "ACTIONS_CONFIG_PANEL": "Config/panel"
}

OK = ' \033[1m\033[92mOK\033[0m '
FAIL = '\033[91mfail\033[0m'

latest_test_serie = "default"
print()
for test in tests:
    test_display_name = test_types[test["test_type"]]
    if test["test_arg"]:
        test_display_name += " (%s)" % test["test_arg"][:8]
    test_display_name += ":"
    if test["test_serie"] != latest_test_serie:
        latest_test_serie = test["test_serie"]
        print("------------- %s -------------" % latest_test_serie)

    result = OK if test["results"]["main_result"] == "success" else FAIL
    print("{test: <30}{result}".format(test=test_display_name, result=result))

print()
print("Level results")
print("=============")

stop_global_level_bump = False

global_level = level_0

for level in levels[1:]:
    level.passed = level(tests)

    if not level.passed:
        stop_global_level_bump = True

    if not stop_global_level_bump:
        global_level = level
        display = OK
    else:
        display = " ok " if level.passed else ""

    print("Level {i} {descr: <40} {result}".format(i=level.level,
        descr="(%s)"%level.descr[:38], result=display))

print()
print("\033[1mGlobal level for this application: %s (%s)\033[0m" % (global_level.level, global_level.descr))
print()


summary = {
    "commit": open(test_context + "/commit").read().strip(),
    "architecture": open(test_context + "/architecture").read().strip(),
    "yunohost_version": open(test_context + "/ynh_version").read().strip(),
    "yunohost_branch": open(test_context + "/ynh_branch").read().strip(),
    "tests": [{
        "test_type": t["test_type"],
        "test_arg": t["test_arg"],
        "test_serie": t["test_serie"],
        "main_result": t["results"]["main_result"]
    } for t in tests],
    "levels": {level.level: level.passed for level in levels[1:]},
    "global_level": global_level.level
}

sys.stderr.write(json.dumps(summary, indent=4))
