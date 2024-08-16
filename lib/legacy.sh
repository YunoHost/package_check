guess_test_configuration() {

    log_error "No tests.toml file found."
    log_warning "Package check will attempt to automatically guess what tests to run."

    local test_id=100

    add_test() {
        local test_type="$1"
        local test_arg="$2"
        test_id="$((test_id+1))"
        local extra="{}"
        local preupgrade_template=""

        jq -n \
            --arg test_serie "default" \
            --arg test_type "$test_type" \
            --arg test_arg "$test_arg" \
            --arg preinstall_template "" \
            --arg preupgrade_template "$preupgrade_template" \
            --arg install_args "$install_args" \
            --argjson extra "$extra" \
            '{ $test_serie, $test_type, $test_arg, $preinstall_template, $preupgrade_template, $install_args, $extra }' \
            > "$TEST_CONTEXT/tests/$test_id.json"
    }

    local install_args=$(python3 "./lib/default_install_args.py" "$package_path"/manifest.*)

    add_test "TEST_PACKAGE_LINTER"
    add_test "TEST_INSTALL" "root"
    add_test "TEST_INSTALL" "subdir"
    if echo $install_args | grep -q "is_public=\|init_main_permission="
    then
        add_test "TEST_INSTALL" "private"
    fi
    if grep multi_instance "$package_path"/manifest.* | grep -q true
    then
        add_test "TEST_INSTALL" "multi"
    fi
    add_test "TEST_BACKUP_RESTORE"
    add_test "TEST_UPGRADE"
}
