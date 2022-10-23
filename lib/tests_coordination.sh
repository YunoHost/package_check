#!/bin/bash

source lib/ynh_lxd
source lib/ynh_lxd_package_check
source lib/tests.sh

readonly complete_log="./Complete-${WORKER_ID}.log"

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
        local install_args=$(       extract_check_process_section "^; Manifest"     "^; " $test_serie_rawconf | sed 's/\s*(.*)$//g' | tr -d '"' | tr '\n' '&')
        local preinstall_template=$(extract_check_process_section "^; pre-install"  "^; " $test_serie_rawconf)
        local preupgrade_template=$(extract_check_process_section "^; pre-upgrade"  "^; " $test_serie_rawconf)
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
                if [ -f "$TEST_CONTEXT/upgrades/$test_arg" ]; then
                    local specific_upgrade_install_args="$(grep "^manifest_arg=" "$TEST_CONTEXT/upgrades/$test_arg" | cut -d'=' -f2-)"
                    [[ -n "$specific_upgrade_install_args" ]] && _install_args="$specific_upgrade_install_args"

                    local upgrade_name="$(grep "^name=" "$TEST_CONTEXT/upgrades/$test_arg" | cut -d'=' -f2)"
                else
                    local upgrade_name="$test_arg"
                fi
                extra="$(jq -n --arg upgrade_name "$upgrade_name" '{ $upgrade_name }')"
            elif [[ "$test_type" == "ACTIONS_CONFIG_PANEL" ]] && [[ "$test_arg" == "actions" ]]
            then
                extra="$(jq -n --arg actions "$action_infos" '{ $actions }')"
            elif [[ "$test_type" == "ACTIONS_CONFIG_PANEL" ]] && [[ "$test_arg" == "config_panel" ]]
            then
                extra="$(jq -n --arg configpanel "$configpanel_infos" '{ $configpanel }')"
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
        done < <(grep "^upgrade=1" "$TEST_CONTEXT/check_process.tests_infos")

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

    local install_args=$(python3 "./lib/manifest_parsing.py" "$package_path/manifest.json" | cut -d ':' -f1,2 | tr ':' '=' | tr '\n' '&')

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
    mkdir -p $TEST_CONTEXT/logs

    readonly app_id="$(jq -r .id $package_path/manifest.json)"

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
    cat $TEST_CONTEXT/tests/*.json >> /proc/self/fd/3

    # Reset and create a fresh container to work with
    check_lxd_setup
    ynh_lxc_reset --name=$LXC_NAME
    ynh_lxc_pc_create --image=$LXC_BASE --name=$LXC_NAME
    # Be sure that the container is running
    ynh_lxc_pc_exec --name=$LXC_NAME --command="true"

    # Print the version of YunoHost from the LXC container
    log_small_title "YunoHost versions"
    ynh_lxc_pc_exec --name=$LXC_NAME --command="yunohost --version"
    ynh_lxc_pc_exec --name=$LXC_NAME --command="yunohost --version --output-as json" | jq -r .yunohost.version >> $TEST_CONTEXT/ynh_version
    ynh_lxc_pc_exec --name=$LXC_NAME --command="yunohost --version --output-as json" | jq -r .yunohost.repo >> $TEST_CONTEXT/ynh_branch
    echo $ARCH > $TEST_CONTEXT/architecture
    echo $app_id > $TEST_CONTEXT/app_id

    # Init the value for the current test
    current_test_number=1

    # The list of test contains for example "TEST_UPGRADE some_commit_id
    for testfile in "$TEST_CONTEXT"/tests/*.json;
    do
        TEST_LAUNCHER $testfile
        current_test_number=$((current_test_number+1))
    done

    # Print the final results of the tests
    log_title "Tests summary"

    python3 lib/analyze_test_results.py $TEST_CONTEXT 2> ./results-${WORKER_ID}.json
    [[ -e "$TEST_CONTEXT/summary.png" ]] && cp "$TEST_CONTEXT/summary.png" ./summary.png || rm -f summary.png

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
    current_test_log="$TEST_CONTEXT/logs/$current_test_id.log"
    echo "{}" > $current_test_results
    echo "" > $current_test_log

    local test_type=$(jq -r '.test_type' $testfile)
    local test_arg=$(jq -r '.test_arg' $testfile)

    # Execute the test
    $test_type $test_arg

    [ $? -eq 0 ] && SET_RESULT "success" main_result || SET_RESULT "failure" main_result

    # Check that we don't have this message characteristic of a file that got manually modified,
    # which should not happen during tests because no human modified the file ...
    if grep -q --extended-regexp 'has been manually modified since the installation or last upgrade. So it has been duplicated' $current_test_log
    then
        log_error "Apparently the log is telling that 'some file got manually modified' ... which should not happen, considering that no human modified the file ... ! Maybe you need to check what's happening with ynh_store_file_checksum and ynh_backup_if_checksum_is_different between install and upgrade."
    fi

    # Check that the number of warning ain't higher than a treshold
    local n_warnings=$(grep --extended-regexp '^[0-9]+\s+.{1,15}WARNING' $current_test_log | wc -l)
    # (we ignore this test for upgrade from older commits to avoid having to patch older commits for this)
    if [ "$n_warnings" -gt 50 ] && [ "$test_type" != "TEST_UPGRADE" -o "$test_arg" == "" ]
    then
        if [ "$n_warnings" -gt 200 ]
        then
            log_error "There's A SHITLOAD of warnings in the output ! If those warnings are coming from some app build step and ain't actual warnings, please redirect them to the standard output instead of the error output ...!"
            log_report_test_failed
            SET_RESULT "failure" too_many_warnings
        else
            log_error "There's quite a lot of warnings in the output ! If those warnings are coming from some app build step and ain't actual warnings, please redirect them to the standard output instead of the error output ...!"
        fi
    fi

    local test_duration=$(echo $(( $(date +%s) - $global_start_timer )))
    SET_RESULT "$test_duration" test_duration

    break_before_continue

    # Restore the started time for the timer
    starttime=$global_start_timer
    # End the timer for the test
    stop_timer 2

    ynh_lxc_stop --name=$LXC_NAME

    # Update the lock file with the date of the last finished test.
    # $$ is the PID of package_check itself.
    echo "$1 $2:$(date +%s):$$" > "$lock_file"
}

SET_RESULT() {
    local result=$1
    local name=$2
    if [ "$name" != "test_duration" ]
    then
        [ "$result" == "success" ] && log_report_test_success || log_report_test_failed
    fi
    local current_results="$(cat $current_test_results)"
    echo "$current_results" | jq --arg result $result ".$name=\$result" > $current_test_results
}

#=================================================

at_least_one_install_succeeded () {

    for TEST in "$TEST_CONTEXT"/tests/*.json
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
        && current_test_serie="($current_test_serie) " \
        || current_test_serie=""

    total_number_of_test=$(ls $TEST_CONTEXT/tests/*.json | wc -l)

    log_title " [Test $current_test_number/$total_number_of_test] $current_test_serie$1"
}

there_is_an_install_type() {
    local install_type=$1

    for TEST in $TEST_CONTEXT/tests/*.json
    do
        jq --arg install_type "$install_type" -e '. | select(.test_type == "TEST_INSTALL") | select(.test_arg == $install_type)' $TEST > /dev/null \
        && return 0
    done

    return 1
}

there_is_a_root_install_test() {
    return $(there_is_an_install_type "root")
}

there_is_a_subdir_install_test() {
    return $(there_is_an_install_type "subdir")
}

this_is_a_web_app () {
    # An app is considered to be a webapp if there is a root or a subdir test
    return $(there_is_a_root_install_test) || $(there_is_a_subdir_install_test)
}

root_path () {
    echo "/"
}

subdir_path () {
    echo "/path"
}

default_install_path() {
    # All webapps should be installable at the root or in a subpath of a domain
    there_is_a_root_install_test && { root_path; return; }
    there_is_a_subdir_install_test && { subdir_path; return; }
    echo ""
}

path_to_install_type() {
    local check_path="$1"

    [ -z "$check_path" ] && { echo "nourl"; return; }
    [ "$check_path" == "/" ] && { echo "root"; return; }
    echo "subdir"
}

