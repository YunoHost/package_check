#!/bin/bash
# shellcheck disable=SC2155,SC2034,SC2154

source lib/lxc.sh
source lib/tests.sh
source lib/witness.sh

readonly full_log="./full_log_${WORKER_ID}.log"
readonly result_json="./results_${WORKER_ID}.json"
readonly summary_png="./summary_${WORKER_ID}.png"

# Purge some log files
rm -f "$full_log" && touch "$full_log"
rm -f "$result_json"
rm -f "$summary_png"

# Redirect fd 3 (=debug steam) to full log
exec 3>> "$full_log"

#=================================================
# Misc test helpers & coordination
#=================================================

run_all_tests() {

    mkdir -p "$TEST_CONTEXT/tests"
    mkdir -p "$TEST_CONTEXT/results"
    mkdir -p "$TEST_CONTEXT/logs"

    readonly app_id="$(grep '^id = ' "$package_path/manifest.toml" | tr -d '" ' | awk -F= '{print $2}')"

    DIST=$DIST "./lib/parse_tests_toml.py" "$package_path" --dump-to "$TEST_CONTEXT/tests"

    # Start the timer for this test
    start_timer
    # And keep this value separately
    complete_start_timer=$starttime

    # Break after the first tests serie
    if [ "$interactive" -eq 1 ]; then
        read -r -p "Press a key to start the tests..." </dev/tty
    fi

    if [ "$dry_run" -eq 1 ]; then
        for FILE in "$TEST_CONTEXT/tests"/*.json; do
            jq "." "$FILE"
        done
        exit
    fi

    # Launch all tests successively
    cat "$TEST_CONTEXT/tests"/*.json >>/proc/self/fd/3

    # Reset and create a fresh container to work with
    check_lxc_setup
    LXC_RESET
    LXC_CREATE

    LXC_EXEC "yunohost --version --output-as json" | jq -r .yunohost.version >> "$TEST_CONTEXT/ynh_version"
    LXC_EXEC "yunohost --version --output-as json" | jq -r .yunohost.repo >> "$TEST_CONTEXT/ynh_branch"
    echo "$ARCH" > "$TEST_CONTEXT/architecture"
    echo "$app_id" > "$TEST_CONTEXT/app_id"

    # Init the value for the current test
    current_test_number=1

    # The list of test contains for example "TEST_UPGRADE some_commit_id
    for testfile in "$TEST_CONTEXT"/tests/*.json; do
        TEST_LAUNCHER "$testfile"
        current_test_number=$((current_test_number + 1))
    done

    # Print the final results of the tests
    log_title "Tests summary"

    python3 lib/analyze_test_results.py "$TEST_CONTEXT" 2> "$result_json"
    if [[ -e "$TEST_CONTEXT/summary.png" ]]; then
        cp "$TEST_CONTEXT/summary.png" "$summary_png"
    else
        rm -f "$summary_png"
    fi

    # Restore the started time for the timer
    starttime=$complete_start_timer
    # End the timer for the test
    stop_timer all_tests

    if [[ "$IN_YUNORUNNER" != "1" ]]; then
        echo "You can find the complete log of these tests in $(realpath "$full_log")"
    fi

}

TEST_LAUNCHER() {
    local testfile="$1"

    # Start the timer for this test
    start_timer
    # And keep this value separately
    local global_start_timer=$starttime

    current_test_id=$(basename "$testfile" | cut -d. -f1)
    current_test_serie=$(jq -r '.test_serie' "$testfile")
    current_test_infos="$TEST_CONTEXT/tests/$current_test_id.json"
    current_test_results="$TEST_CONTEXT/results/$current_test_id.json"
    current_test_log="$TEST_CONTEXT/logs/$current_test_id.log"
    echo "{}" > "$current_test_results"
    echo "" > "$current_test_log"

    local test_type=$(jq -r '.test_type' "$testfile")
    local test_arg=$(jq -r '.test_arg' "$testfile")

    # Execute the test
    # shellcheck disable=SC2086
    $test_type $test_arg

    local test_result=$?

    if [ $test_result -eq 0 ]; then
        SET_RESULT "success" main_result
    else
        SET_RESULT "failure" main_result
    fi

    # Publish logs with YunoPaste on failure
    if [ ! $test_result -eq 0 ]; then
        RUN_INSIDE_LXC yunohost tools shell -c "from yunohost.log import log_list, log_share; log_share(log_list().get('operation')[-1].get('path'))"
    fi

    # Check that we don't have this message characteristic of a file that got manually modified,
    # which should not happen during tests because no human modified the file ...
    if grep -q --extended-regexp 'has been manually modified since the installation or last upgrade. So it has been duplicated' "$current_test_log"; then
        log_error "Apparently the log is telling that 'some file got manually modified' ... which should not happen, considering that no human modified the file ... ! This is usually symptomatic of something that modified a conf file after installing it with ynh_add_config. Maybe usigin ynh_store_file_checksum can help, or maybe the issue is more subtle!"
        if [[ "$test_type" == "TEST_UPGRADE" ]] && [[ "$test_arg" == "" ]]; then
            SET_RESULT "failure" file_manually_modified
        fi
        if [[ "$test_type" == "TEST_BACKUP_RESTORE" ]]; then
            SET_RESULT "failure" file_manually_modified
        fi
    fi

    # Check that the number of warning ain't higher than a treshold
    local n_warnings=$(grep -c --extended-regexp '^[0-9]+\s+.{1,15}WARNING' "$current_test_log")
    # (we ignore this test for upgrade from older commits to avoid having to patch older commits for this)
    # shellcheck disable=SC2166
    if [ "$n_warnings" -gt 30 ] && [ "$test_type" != "TEST_UPGRADE" -o "$test_arg" == "" ]; then
        if [ "$n_warnings" -gt 100 ]; then
            log_error "There's A SHITLOAD of warnings in the output ! If those warnings are coming from some app build step and ain't actual warnings, please redirect them to the standard output instead of the error output ...!"
            log_report_test_failed
            SET_RESULT "failure" too_many_warnings
        else
            log_error "There's quite a lot of warnings in the output ! If those warnings are coming from some app build step and ain't actual warnings, please redirect them to the standard output instead of the error output ...!"
        fi
    fi

    local test_duration=$(( $(date +%s) - global_start_timer))
    SET_RESULT "$test_duration" test_duration

    break_before_continue

    # Restore the started time for the timer
    starttime=$global_start_timer
    # End the timer for the test
    stop_timer one_test

    LXC_STOP "$LXC_NAME"

    # Update the lock file with the date of the last finished test.
    # $$ is the PID of package_check itself.
    echo "$1 $2:$(date +%s):$$" >"$lock_file"
}

SET_RESULT() {
    local result=$1
    local name=$2
    if [ "$name" != "test_duration" ]; then
        if [ "$result" == "success" ]; then
            log_report_test_success
        else
            log_report_test_failed
        fi
    fi
    local current_results="$(cat "$current_test_results")"
    echo "$current_results" | jq --arg result "$result" ".$name=\$result" > "$current_test_results"
}

#=================================================

at_least_one_install_succeeded() {

    for TEST in "$TEST_CONTEXT"/tests/*.json; do
        local test_id=$(basename "$TEST" | cut -d. -f1)
        jq -e '. | select(.test_type == "TEST_INSTALL")' "$TEST" >/dev/null \
            && jq -e '. | select(.main_result == "success")' "$TEST_CONTEXT/results/$test_id.json" >/dev/null \
            && return 0
    done

    log_error "All installs failed, therefore the following tests cannot be performed..."
    return 1
}

break_before_continue() {

    if [ "$interactive" -eq 1 ] || [ "$interactive_on_errors" -eq 1 ] && [ ! "$test_result" -eq 0 ]; then
        echo "To enter a shell on the lxc:"
        echo "     $lxc exec $LXC_NAME bash"
        read -r -p "Press a key to delete the application and continue...." </dev/tty
    fi
}

start_test() {
    [[ "$current_test_serie" != "default" ]] \
        && current_test_serie="($current_test_serie) " \
        || current_test_serie=""

    total_number_of_test=$(find "$TEST_CONTEXT/tests" -mindepth 1 -maxdepth 1 -name "*.json" | wc -l)

    log_title " [Test $current_test_number/$total_number_of_test] $current_test_serie$1"
}

there_is_an_install_type() {
    local install_type=$1

    for TEST in "$TEST_CONTEXT/tests"/*.json; do
        if jq --arg install_type "$install_type" \
            -e '. | select(.test_type == "TEST_INSTALL") | select(.test_arg == $install_type)' "$TEST" >/dev/null
        then
            return 0
        fi
    done

    return 1
}

there_is_a_root_install_test() {
    there_is_an_install_type "root"
}

there_is_a_subdir_install_test() {
    there_is_an_install_type "subdir"
}

this_is_a_web_app() {
    # An app is considered to be a webapp if there is a root or a subdir test
    there_is_a_root_install_test || there_is_a_subdir_install_test
}

root_path() {
    echo "/"
}

subdir_path() {
    echo "/path"
}

default_install_path() {
    # All webapps should be installable at the root or in a subpath of a domain
    there_is_a_root_install_test && {
        root_path
        return
    }
    there_is_a_subdir_install_test && {
        subdir_path
        return
    }
    echo ""
}

path_to_install_type() {
    local check_path="$1"

    [ -z "$check_path" ] && {
        echo "nourl"
        return
    }
    [ "$check_path" == "/" ] && {
        echo "root"
        return
    }
    echo "subdir"
}
