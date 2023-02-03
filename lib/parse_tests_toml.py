import sys
import os
import toml
import copy
import json


def generate_test_list_base(test_manifest, default_install_args, is_webapp, is_multi_instance):

    assert test_manifest["test_format"] == 1.0, "Only test_format 1.0 is supported for now"

    assert isinstance(test_manifest["default"], dict), "You should at least defined the 'default' test suite"

    is_full_domain_app = "domain" in default_install_args and "path" not in default_install_args

    for test_suite_id, test_suite in test_manifest.items():

        # Ignore non-testsuite stuff like "test_format"
        if not isinstance(test_suite, dict):
            continue

        install_args = copy.copy(default_install_args)
        install_args.update(test_suite.get("args", {}))

        default_meta = {
            "preinstall": test_suite.get("preinstall", ""),
            "preupgrade": test_suite.get("preupgrade", ""),
            "install_args": install_args,
        }

        yield test_suite_id, "package_linter", default_meta

        if is_webapp:
            yield test_suite_id, "install.root", default_meta
            if not is_full_domain_app:
                yield test_suite_id, "install.subdir", default_meta
        else:
            yield test_suite_id, "install.nourl", default_meta

        if is_webapp and ("is_public" in install_args or "init_main_permission" in install_args):
            yield test_suite_id, "install.private", default_meta

        if is_multi_instance:
            yield test_suite_id, "install.multi", default_meta

        yield test_suite_id, "backup_restore", default_meta

        yield test_suite_id, "upgrade", default_meta
        for commit, infos in test_suite.get("test_upgrade_from", {}).items():
            upgrade_meta = copy.copy(default_meta)
            upgrade_meta.update(infos)
            yield test_suite_id, "upgrade." + commit, upgrade_meta

        if is_webapp:
            yield test_suite_id, "change_url", default_meta


def filter_test_list(test_manifest, base_test_list):

    for test_suite_id, test_suite in test_manifest.items():

        # Ignore non-testsuite stuff like "test_format"
        if not isinstance(test_suite, dict):
            continue

        exclude = test_suite.get("exclude", [])
        only = test_suite.get("only")

        if test_suite_id == "default" and only:
            raise Exception("'only' is not allowed on the default test suite")

        if only:
            tests_for_this_suite = {test_id: meta
                                    for suite_id, test_id, meta in base_test_list
                                    if suite_id == test_suite_id and test_id in only}
        elif exclude:
            tests_for_this_suite = {test_id: meta
                                    for suite_id, test_id, meta in base_test_list
                                    if suite_id == test_suite_id and test_id not in exclude}
        else:
            tests_for_this_suite = {test_id: meta
                                    for suite_id, test_id, meta in base_test_list
                                    if suite_id == test_suite_id}

        yield test_suite_id, tests_for_this_suite


def dump_for_package_check(test_list, package_check_tests_dir):

    test_suite_i = 0

    for test_suite_id, subtest_list in test_list.items():

        test_suite_i += 1

        subtest_i = 0

        for test, meta in subtest_list.items():

            meta = copy.copy(meta)

            subtest_i += 1

            if "." in test:
                test_type, test_arg = test.split(".")
            else:
                test_type = test
                test_arg = ""

            J = {
                "test_serie": test_suite_id,
                "test_type": "TEST_" + test_type.upper(),
                "test_arg": test_arg,
                "preinstall_template": meta.pop("preinstall", ""),
                "preupgrade_template": meta.pop("preupgrade", ""),
                "install_args": '&'.join([k + "=" + str(v) for k, v in meta.pop("install_args").items()]),
                "extra": meta  # Boring legacy logic just to ship the upgrade-from-commit's name ...
            }

            test_file_id = test_suite_i * 100 + subtest_i

            json.dump(J, open(package_check_tests_dir + f"/{test_file_id}.json", "w"))


def build_test_list(basedir):

    test_manifest = toml.load(open(basedir + "/tests.toml", "r"))

    if os.path.exists(basedir + "/manifest.json"):
        manifest = json.load(open(basedir + "/manifest.json", "r"))
        is_multi_instance = manifest.get("multi_instance") is True
    else:
        manifest = toml.load(open(basedir + "/manifest.toml", "r"))
        is_multi_instance = manifest.get("integration").get("multi_instance") is True

    is_webapp = os.system(f"grep -q '^ynh_add_nginx_config' '{basedir}/scripts/install'") == 0

    from default_install_args import get_default_values_for_questions
    default_install_args = {k: v for k, v in get_default_values_for_questions(manifest, raise_if_no_default=False)}

    base_test_list = list(generate_test_list_base(test_manifest, default_install_args, is_webapp, is_multi_instance))
    test_list = {test_suite_id: tests for test_suite_id, tests in filter_test_list(test_manifest, base_test_list)}

    return test_list

if __name__ == '__main__':

    test_list = build_test_list(sys.argv[1])

    if len(sys.argv) <= 1 or sys.argv[1] in ["-h", "--help"]:
        print("""Usage:

Display generated test list:
    python3 parse_tests_toml.py /path/to/app/folder/ | jq

Dump the list (only relevant from inside package_checker's code ...)
    python3 parse_tests_toml.py /path/to/app/folder/ /tmp/dir/for/package/check/....

""")
    elif len(sys.argv) == 2:
        print(json.dumps(test_list, indent=4))
    else:
        dump_for_package_check(test_list, sys.argv[2])
