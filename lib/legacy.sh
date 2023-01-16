#=======================================================================
# Parse the check_process and generate jsons that describe tests to run
#=======================================================================

# Extract a section found between $1 and $2 from the file $3
extract_check_process_section () {
    local source_file="${3:-$check_process}"
    local extract=0
    local line=""
    while read line
    do
        # Extract the line
        if [ $extract -eq 1 ]
        then
            # Check if the line is the second line to found
            if echo $line | grep -q "$2"; then
                # Break the loop to finish the extract process
                break;
            fi
            # Copy the line in the partial check_process
            echo "$line"
        fi

        # Search for the first line
        if echo $line | grep -q "$1"; then
            # Activate the extract process
            extract=1
        fi
    done < "$source_file"
}


parse_check_process() {

    log_info "Parsing check_process file"

    # Remove all commented lines in the check_process
    sed --in-place '/^#/d' "$check_process"
    # Remove all spaces at the beginning of the lines
    sed --in-place 's/^[ \t]*//g' "$check_process"

    # Extract the Upgrade infos
    extract_check_process_section "^;;; Upgrade options" ";; " > $TEST_CONTEXT/check_process.upgrade_options
    mkdir -p $TEST_CONTEXT/upgrades
    local commit
    for commit in $(cat $TEST_CONTEXT/check_process.upgrade_options | grep "^; commit=.*" | awk -F= '{print $2}')
    do
        cat $TEST_CONTEXT/check_process.upgrade_options | sed -n -e "/^; commit=$commit/,/^;/ p" | grep -v "^;;" > $TEST_CONTEXT/upgrades/$commit
    done
    rm $TEST_CONTEXT/check_process.upgrade_options

    local test_serie_id="0"

    # Parse each tests serie
    while read <&3 tests_serie
    do
        test_serie_id=$((test_serie_id+1))
        local test_id=$((test_serie_id * 100))
        local test_serie_rawconf=$TEST_CONTEXT/raw_test_serie_config

        # Extract the section of the current tests serie
        extract_check_process_section "^$tests_serie"   "^;;" > $test_serie_rawconf
        # This is the arg list to be later fed to "yunohost app install"
        # Looking like domain=foo.com&path=/bar&password=stuff
        # "Standard" arguments like domain/path will later be overwritten
        # during tests
        local install_args=$(       extract_check_process_section "^; Manifest"     "^; " $test_serie_rawconf | sed 's/\s*(.*)$//g' | tr -d '"' | tr '\n' '&')
        local preinstall_template=$(extract_check_process_section "^; pre-install"  "^; " $test_serie_rawconf)
        local preupgrade_template=$(extract_check_process_section "^; pre-upgrade"  "^; " $test_serie_rawconf)

        # Add (empty) special args if they ain't provided in check_process
        echo "$install_args" | tr '&' '\n' | grep -q "^domain="    ||install_args+="domain=&"
        echo "$install_args" | tr '&' '\n' | grep -q "^path="      ||install_args+="path=&"
        echo "$install_args" | tr '&' '\n' | grep -q "^admin="     ||install_args+="admin=&"
        echo "$install_args" | tr '&' '\n' | grep -q "^is_public=" ||install_args+="is_public=&"
        echo "$install_args" | tr '&' '\n' | grep -q "^init_main_permission=" ||install_args+="init_main_permission=&"

        extract_check_process_section "^; Checks"       "^; " $test_serie_rawconf > $TEST_CONTEXT/check_process.tests_infos

        is_test_enabled () {
            # Find the line for the given check option
            local value=$(grep -m1 -o "^$1=." "$TEST_CONTEXT/check_process.tests_infos" | awk -F= '{print $2}')
            # And return this value
            [ "${value:0:1}" = "1" ]
        }

        add_test() {
            local test_type="$1"
            local test_arg="$2"
            test_id="$((test_id+1))"
            local extra="{}"
            local _install_args="$install_args"

            # Upgrades with a specific commit
            if [[ "$test_type" == "TEST_UPGRADE" ]] && [[ -n "$test_arg" ]]
            then
                if [ -f "$TEST_CONTEXT/upgrades/$test_arg" ]; then
                    local specific_upgrade_install_args="$(grep "^manifest_arg=" "$TEST_CONTEXT/upgrades/$test_arg" | cut -d'=' -f2-)"
                    [[ -n "$specific_upgrade_install_args" ]] && _install_args="$specific_upgrade_install_args"

                    local upgrade_name="$(grep "^name=" "$TEST_CONTEXT/upgrades/$test_arg" | cut -d'=' -f2)"
                else
                    local upgrade_name="$test_arg"
                fi
                extra="$(jq -n --arg upgrade_name "$upgrade_name" '{ $upgrade_name }')"
            fi

            jq -n  \
                --arg test_serie "$test_serie" \
                --arg test_type "$test_type" \
                --arg test_arg "$test_arg" \
                --arg preinstall_template "$preinstall_template" \
                --arg preupgrade_template "$preupgrade_template" \
                --arg install_args "${_install_args//\"}" \
                --argjson extra "$extra" \
                '{ $test_serie, $test_type, $test_arg, $preinstall_template, $preupgrade_template, $install_args, $extra }' \
                > "$TEST_CONTEXT/tests/$test_id.json"
        }

        test_serie=${tests_serie//;; }

        is_test_enabled pkg_linter     && add_test "TEST_PACKAGE_LINTER"
        is_test_enabled setup_root     && add_test "TEST_INSTALL" "root"
        is_test_enabled setup_sub_dir  && add_test "TEST_INSTALL" "subdir"
        is_test_enabled setup_nourl    && add_test "TEST_INSTALL" "nourl"
        is_test_enabled setup_private  && add_test "TEST_INSTALL" "private"
        is_test_enabled multi_instance && add_test "TEST_INSTALL" "multi"
        is_test_enabled backup_restore && add_test "TEST_BACKUP_RESTORE"

        # Upgrades
        while IFS= read -r LINE;
        do
            commit="$(echo $LINE | grep -o "from_commit=.*" | awk -F= '{print $2}')"
            add_test "TEST_UPGRADE" "$commit"
        done < <(grep "^upgrade=1" "$TEST_CONTEXT/check_process.tests_infos")

        # "Advanced" features

        is_test_enabled change_url       && add_test "TEST_CHANGE_URL"

        # Port already used ... do we really need this ...

        if grep -q -m1 "port_already_use=1" "$TEST_CONTEXT/check_process.tests_infos"
        then
            local check_port=$(grep -m1 "port_already_use=1" "$TEST_CONTEXT/check_process.tests_infos" | grep -o -E "\([0-9]+\)" | tr -d '()')
        else
            local check_port=6660
        fi

        is_test_enabled port_already_use && add_test "TEST_PORT_ALREADY_USED" "$check_port"

    done 3<<< "$(grep "^;; " "$check_process")"

    return 0
}

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
