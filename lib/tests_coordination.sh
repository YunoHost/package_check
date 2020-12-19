#!/bin/bash

source lib/lxc.sh
source lib/tests.sh
source lib/witness.sh

complete_log="./Complete.log"

# Purge some log files
rm -f "$complete_log" && touch "$complete_log"

# Redirect fd 3 (=debug steam) to complete log
exec 3>>$complete_log

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
        local install_args=$(       extract_check_process_section "^; Manifest"     "^; " $test_serie_rawconf | awk '{print $1}' | tr -d '"' | tr '\n' '&')
        local preinstall_template=$(extract_check_process_section "^; pre-install"  "^; " $test_serie_rawconf)
        local action_infos=$(       extract_check_process_section "^; Actions"      "^; " $test_serie_rawconf)
        local configpanel_infos=$(  extract_check_process_section "^; Config_panel" "^; " $test_serie_rawconf)

        # Add (empty) special args if they ain't provided in check_process
        echo "$install_args" | tr '&' '\n' | grep -q "^domain="    ||install_args+="domain=&"
        echo "$install_args" | tr '&' '\n' | grep -q "^path="      ||install_args+="path=&"
        echo "$install_args" | tr '&' '\n' | grep -q "^admin="     ||install_args+="admin=&"
        echo "$install_args" | tr '&' '\n' | grep -q "^is_public=" ||install_args+="is_public=&"

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
                local specific_upgrade_install_args="$(grep "^manifest_arg=" "$TEST_CONTEXT/upgrades/$test_arg" | cut -d'=' -f2-)"
                [[ -n "$specific_upgrade_install_args" ]] && _install_args="$specific_upgrade_install_args"

                local upgrade_name="$(grep "^name=" "$TEST_CONTEXT/upgrades/$test_arg" | cut -d'=' -f2)"
                extra="$(jq -n --arg upgrade_name "$upgrade_name" '{ $upgrade_name }')"
            elif [[ "$test_type" == "ACTIONS_CONFIG_PANEL" ]] && [[ "$test_arg" == "actions" ]]
            then
                extra="$(jq -n --arg actions "$action_infos" '{ $actions }')"
            elif [[ "$test_type" == "ACTIONS_CONFIG_PANEL" ]] && [[ "$test_arg" == "actions" ]]
            then
                extra="$(jq -n --arg configpanel "$configpanel_infos" '{ $configpanel }')"
            fi

            jq -n  \
                --arg test_serie "$test_serie" \
                --arg test_type "$test_type" \
                --arg test_arg "$test_arg" \
                --arg preinstall_template "$preinstall_template" \
                --arg install_args "${_install_args//\"}" \
                --argjson extra "$extra" \
                '{ $test_serie, $test_type, $test_arg, $preinstall_template, $install_args, $extra }' \
                > "$TEST_CONTEXT/tests/$test_id.json"
        }

        # For not-the-main-test-serie, we only consider testing the install and
        # upgrade from previous commits
        if [[ "$test_serie_id" != "1" ]]
        then
            is_test_enabled setup_root     && add_test "TEST_INSTALL" "root"
            is_test_enabled setup_sub_dir  && add_test "TEST_INSTALL" "subdir"
            is_test_enabled setup_nourl    && add_test "TEST_INSTALL" "nourl"
            while IFS= read -r LINE;
            do
                commit="$(echo $LINE | grep -o "from_commit=.*" | awk -F= '{print $2}')"
                [ -n "$commit" ] || continue
                add_test "TEST_UPGRADE" "$commit"
            done <<<$(grep "^upgrade=1" "$TEST_CONTEXT/check_process.tests_infos")

            continue
        else
            test_serie="default"
        fi

        is_test_enabled pkg_linter     && add_test "PACKAGE_LINTER"
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
        done <<<$(grep "^upgrade=1" "$TEST_CONTEXT/check_process.tests_infos")

        # "Advanced" features

        is_test_enabled change_url       && add_test "TEST_CHANGE_URL"
        is_test_enabled actions          && add_test "ACTIONS_CONFIG_PANEL" "actions"
        is_test_enabled config_panel     && add_test "ACTIONS_CONFIG_PANEL" "config_panel"

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

    log_error "Not check_process file found."
    log_warning "Package check will attempt to automatically guess what tests to run."
    
    local test_id=100

    add_test() {
        local test_type="$1"
        local test_arg="$2"
        test_id="$((test_id+1))"
        local extra="{}"

        jq -n \
            --arg test_serie "default" \
            --arg test_type "$test_type" \
            --arg test_arg "$test_arg" \
            --arg preinstall_template "" \
            --arg install_args "$install_args" \
            --argjson extra "$extra" \
            '{ $test_serie, $test_type, $test_arg, $preinstall_template, $install_args, $extra }' \
            > "$TEST_CONTEXT/tests/$test_id.json"
    }

    local install_args=$(python "./lib/manifest_parsing.py" "$package_path/manifest.json" | cut -d ':' -f1,2 | tr ':' '=' | tr '\n' '&')

    add_test "PACKAGE_LINTER"
    add_test "TEST_INSTALL" "root"
    add_test "TEST_INSTALL" "subdir"
    if echo $install_args | grep -q "is_public="
    then
        add_test "TEST_INSTALL" "private"
    fi
    if grep multi_instance "$package_path/manifest.json" | grep -q true
    then
        add_test "TEST_INSTALL" "multi"
    fi
    add_test "TEST_BACKUP_RESTORE"
    add_test "TEST_UPGRADE"
}

#=================================================
# Misc test helpers & coordination
#=================================================

run_all_tests() {

    mkdir -p $TEST_CONTEXT/tests
    mkdir -p $TEST_CONTEXT/results

    # Parse the check_process only if it's exist
    check_process="$package_path/check_process"

    [ -e "$check_process" ] \
        && parse_check_process \
        || guess_test_configuration

    # Start the timer for this test
    start_timer
    # And keep this value separately
    complete_start_timer=$starttime

    # Break after the first tests serie
    if [ $interactive -eq 1 ]; then
        read -p "Press a key to start the tests..." < /dev/tty
    fi

    # Launch all tests successively
    cat $TEST_CONTEXT/tests/*.json >&3
    
    # Reset and create a fresh container to work with
    check_lxd_setup
    LXC_RESET
    LXC_CREATE
    # Be sure that the container is running
    LXC_START "true"

    # Print the version of YunoHost from the LXC container
    log_small_title "YunoHost versions"
    LXC_START "yunohost --version"

    # Init the value for the current test
    current_test_number=1

    # The list of test contains for example "TEST_UPGRADE some_commit_id
    for testfile in $(ls $TEST_CONTEXT/tests/*.json);
    do
        TEST_LAUNCHER $testfile
    done

    # Print the final results of the tests
    log_title "Tests summary"
    
    python3 lib/analyze_test_results.py $TEST_CONTEXT 2>$TEST_CONTEXT/summary.json

    # Restore the started time for the timer
    starttime=$complete_start_timer
    # End the timer for the test
    stop_timer 3

    echo "You can find the complete log of these tests in $(realpath $complete_log)"

}

TEST_LAUNCHER () {
    local testfile="$1"

    # Start the timer for this test
    start_timer
    # And keep this value separately
    local global_start_timer=$starttime

    current_test_id=$(basename $testfile | cut -d. -f1)
    current_test_infos="$TEST_CONTEXT/tests/$current_test_id.json"
    current_test_results="$TEST_CONTEXT/results/$current_test_id.json"
    echo "{}" > $current_test_results

    local test_type=$(jq -r '.test_type' $testfile)
    local test_arg=$(jq -r '.test_arg' $testfile)

    # Execute the test
    $test_type $test_arg

    [ $? -eq 0 ] && SET_RESULT "success" main_result || SET_RESULT "failure" main_result

    break_before_continue

    # Restore the started time for the timer
    starttime=$global_start_timer
    # End the timer for the test
    stop_timer 2

    LXC_STOP

    # Update the lock file with the date of the last finished test.
    # $$ is the PID of package_check itself.
    echo "$1 $2:$(date +%s):$$" > "$lock_file"
}

SET_RESULT() {
    local result=$1
    local name=$2
    [ "$result" == "success" ] && log_report_test_success || log_report_test_failed
    local current_results="$(cat $current_test_results)"
    echo "$current_results" | jq --arg result $result ".$name=\$result" > $current_test_results
}

#=================================================

at_least_one_install_succeeded () {

    for TEST in $(ls $TEST_CONTEXT/tests/*.json)
    do
        local test_id=$(basename $TEST | cut -d. -f1)
        jq -e '. | select(.test_type == "TEST_INSTALL")' $TEST >/dev/null \
        && jq -e '. | select(.main_result == "success")' $TEST_CONTEXT/results/$test_id.json >/dev/null \
        && return 0
    done

    log_error "All installs failed, therefore the following tests cannot be performed..."
    return 1
}

break_before_continue () {

    if [ $interactive -eq 1 ]
    then
        echo "To enter a shell on the lxc:"
        echo "     lxc exec $LXC_NAME bash"
        read -p "Press a key to delete the application and continue...." < /dev/tty
    fi
}

start_test () {

    local current_test_serie=$(jq -r '.test_serie' $testfile)
    [[ "$current_test_serie" != "default" ]] \
        && current_test_serie="($current_test_serie)" \
        || current_test_serie=""

    total_number_of_test=$(ls $TEST_CONTEXT/tests/*.json | wc -l)

    log_title "$current_test_serie $1 [Test $current_test_number/$total_number_of_test]"

    # Increment the value of the current test
    current_test_number=$((current_test_number+1))
}

this_is_a_web_app () {

    # Usually the fact that we test "nourl"
    # installs should be a good indicator for the fact that it's not a webapp
    for TEST in $(ls $TEST_CONTEXT/tests/*.json)
    do
        jq -e '. | select(.test_type == "TEST_INSTALL") | select(.test_arg == "nourl")' $TEST > /dev/null \
        && return 1
    done

    return 0
}

default_install_path() {
    # All webapps should be installable at the root of a domain ?
    this_is_a_web_app && echo "/" || echo ""
}

path_to_install_type() {
    local check_path="$1"

    [ -z "$check_path" ] && { echo "nourl"; return; }
    [ "$check_path" == "/" ] && { echo "root"; return; }
    echo "subdir"
}

