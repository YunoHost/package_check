
# Levels

#0  Broken
#1  Installable
#2  Installable in all situations
#3  Can be updated
#4  Backup and restore support
#5  Clean
#6  Open to contributions from the community
#7  Successfully pass all functional tests and linter tests
#8  Maintained and long-term good quality
#9  High quality app
#10 Package assessed as perfect

# Linter stuff:


#    # Check we qualify for level 6, 7, 8
#    # Linter will have a warning called "app_in_github_org" if app ain't in the
#    # yunohost-apps org...
#    if ! cat "./temp_linter_result.json" | jq ".warning" | grep -q "app_in_github_org"
#    then
#        local pass_level_6="true"
#    fi
#    if cat "./temp_linter_result.json" | jq ".success" | grep -q "qualify_for_level_7"
#    then
#        local pass_level_7="true"
#    fi
#    if cat "./temp_linter_result.json" | jq ".success" | grep -q "qualify_for_level_8"
#    then
#        local pass_level_8="true"
#    fi
#
#    # If there are any critical errors, we'll force level 0
#    if [[ -n "$(cat "./temp_linter_result.json" | jq ".critical" | grep -v '\[\]')" ]]
#    then
#        local pass_level_0="false"
#        # If there are any regular errors, we'll cap to 4
#    elif [[ -n "$(cat "./temp_linter_result.json" | jq ".error" | grep -v '\[\]')" ]]
#    then
#        local pass_level_4="false"
#        # Otherwise, test pass (we'll display a warning depending on if there are
#        # any remaning warnings or not)
#    else
#        if [[ -n "$(cat "./temp_linter_result.json" | jq ".warning" | grep -v '\[\]')" ]]
#        then
#            log_report_test_warning
#        else
#            log_report_test_success
#        fi
#        local pass_level_4="true"
#    fi













#
#    local test_serie_id=$1
#    source $TEST_CONTEXT/$test_serie_id/results
#
#    # Print the test result
#    print_result () {
#
#        # Print the result of this test
#        # we use printf to force the length to 30 (filled with space)
#        testname=$(printf %-30.30s "$1:")
#        if [ $2 -eq 1 ]
#        then
#            echo "$testname ${BOLD}${GREEN}SUCCESS${NORMAL}"
#        elif [ $2 -eq -1 ]
#        then
#            echo "$testname ${BOLD}${RED}FAIL${NORMAL}"
#        else
#            echo "$testname Not evaluated."
#        fi
#    }
#
#    # Print the result for each test
#    echo -e "\n\n"
#    print_result "Package linter" $RESULT_linter
#    print_result "Install (root)" $RESULT_check_root
#    print_result "Install (subpath)" $RESULT_check_subdir
#    print_result "Install (no url)" $RESULT_check_nourl
#    print_result "Install (private)" $RESULT_check_private
#    print_result "Install (multi-instance)" $RESULT_check_multi_instance
#    print_result "Upgrade" $RESULT_check_upgrade
#    print_result "Backup" $RESULT_check_backup
#    print_result "Restore" $RESULT_check_restore
#    print_result "Change URL" $RESULT_change_url
#    print_result "Port already used" $RESULT_check_port
#    print_result "Actions and config-panel" $RESULT_action_config_panel
#
#    # Determine the level for this app
#
#    # Each level can has 5 different values
#    # 0    -> If this level can't be validated
#    # 1    -> If this level is forced. Even if the tests fails
#    # 2    -> Indicates the tests had previously validated this level
#    # auto -> This level has not a value yet.
#    # na   -> This level will not be checked, but it'll be ignored in the final sum
#
#    # Set default values for level, if they're empty.
#    test -n "${level[1]}" || level[1]=auto
#    test -n "${level[2]}" || level[2]=auto
#    test -n "${level[3]}" || level[3]=auto
#    test -n "${level[4]}" || level[4]=auto
#    test -n "${level[5]}" || level[5]=auto
#    test -n "${level[5]}" || level[5]=auto
#    test -n "${level[6]}" || level[6]=auto
#    test -n "${level[7]}" || level[7]=auto
#    test -n "${level[8]}" || level[8]=auto
#    test -n "${level[9]}" || level[9]=0
#    test -n "${level[10]}" || level[10]=0
#
#    pass_level_1() {
#	 # FIXME FIXME #FIXME
#	 return 0
#    }
#
#    pass_level_2() {
#        # -> The package can be install and remove in all tested configurations.
#        # Validated if none install failed
#        [ $RESULT_check_subdir -ne -1 ] && \
#        [ $RESULT_check_root -ne -1 ] && \
#        [ $RESULT_check_private -ne -1 ] && \
#        [ $RESULT_check_multi_instance -ne -1 ]
#    }
#
#    pass_level_3() {
#        # -> The package can be upgraded from the same version.
#        # Validated if the upgrade is ok. Or if the upgrade has been not tested but already validated before.
#        [ $RESULT_check_upgrade -eq 1 ] || \
#        ( [ $RESULT_check_upgrade -ne -1 ] && \
#        [ "${level[3]}" == "2" ] )
#    }
#
#    pass_level_4() {
#        # -> The package can be backup and restore without error
#        # Validated if backup and restore are ok. Or if backup and restore have been not tested but already validated before.
#        ( [ $RESULT_check_backup -eq 1 ] && \
#        [ $RESULT_check_restore -eq 1 ] ) || \
#        ( [ $RESULT_check_backup -ne -1 ] && \
#        [ $RESULT_check_restore -ne -1 ] && \
#        [ "${level[4]}" == "2" ] )
#    }
#
#    pass_level_5() {
#        # -> The package have no error with package linter
#        # -> The package does not have any alias_traversal error
#        # Validated if Linter is ok. Or if Linter has been not tested but already validated before.
#        [ $RESULT_alias_traversal -ne 1 ] && \
#        ([ $RESULT_linter -ge 1 ] || \
#        ( [ $RESULT_linter -eq 0 ] && \
#        [ "${level[5]}" == "2" ] ) )
#    }
#
#    pass_level_6() {
#        # -> The package can be backup and restore without error
#        # This is from the linter, tests if app is the Yunohost-apps organization
#        [ $RESULT_linter_level_6 -eq 1 ] || \
#        ([ $RESULT_linter_level_6 -eq 0 ] && \
#        [ "${level[6]}" == "2" ] )
#    }
#
#    pass_level_7() {
#        # -> None errors in all tests performed
#        # Validated if none errors is happened.
#        [ $RESULT_check_subdir -ne -1 ] && \
#        [ $RESULT_check_upgrade -ne -1 ] && \
#        [ $RESULT_check_private -ne -1 ] && \
#        [ $RESULT_check_multi_instance -ne -1 ] && \
#        [ $RESULT_check_port -ne -1 ] && \
#        [ $RESULT_check_backup -ne -1 ] && \
#        [ $RESULT_check_restore -ne -1 ] && \
#        [ $RESULT_change_url -ne -1 ] && \
#        [ $RESULT_action_config_panel -ne -1 ] && \
#        ([ $RESULT_linter_level_7 -ge 1 ] ||
#        ([ $RESULT_linter_level_7 -eq 0 ] && \
#        [ "${level[8]}" == "2" ] ))
#    }
#
#    pass_level_8() {
#        # This happens in the linter
#        # When writing this, defined as app being maintained + long term quality (=
#        # certain amount of time level 5+ in the last year)
#        [ $RESULT_linter_level_8 -ge 1 ] || \
#        ([ $RESULT_linter_level_8 -eq 0 ] && \
#        [ "${level[8]}" == "2" ] )
#    }
#
#    pass_level_9() {
#        list_url="https://raw.githubusercontent.com/YunoHost/apps/master/apps.json"
#        curl --silent $list_url | jq ".[\"$app_id\"].high_quality" | grep -q "true"
#    }
#
#    # Check if the level can be changed
#    level_can_change () {
#        # If the level is set at auto, it's waiting for a change
#        # And if it's set at 2, its value can be modified by a new result
#        [ "${level[$1]}" == "auto" ] || [ "${level[$1]}" -eq 2 ]
#    }
#
#    if level_can_change 1; then pass_level_1 && level[1]=2 || level[1]=0; fi
#    if level_can_change 2; then pass_level_2 && level[2]=2 || level[2]=0; fi
#    if level_can_change 3; then pass_level_3 && level[3]=2 || level[3]=0; fi
#    if level_can_change 4; then pass_level_4 && level[4]=2 || level[4]=0; fi
#    if level_can_change 5; then pass_level_5 && level[5]=2 || level[5]=0; fi
#    if level_can_change 6; then pass_level_6 && level[6]=2 || level[6]=0; fi
#    if level_can_change 7; then pass_level_7 && level[7]=2 || level[7]=0; fi
#    if level_can_change 8; then pass_level_8 && level[8]=2 || level[8]=0; fi
#    if level_can_change 9; then pass_level_9 && level[9]=2 || level[9]=0; fi
#
#    # Level 10 has no definition yet
#    level[10]=0
#
#    # Initialize the global level
#    global_level=0
#
#    # Calculate the final level
#    for i in `seq 1 10`
#    do
#
#        # If there is a level still at 'auto', it's a mistake.
#        if [ "${level[i]}" == "auto" ]
#        then
#            # So this level will set at 0.
#            level[i]=0
#
#        # If the level is at 1 or 2. The global level will be set at this level
#        elif [ "${level[i]}" -ge 1 ]
#        then
#            global_level=$i
#
#            # But, if the level is at 0, the loop stop here
#            # Like that, the global level rise while none level have failed
#        else
#            break
#        fi
#    done
#
#    # If some witness files was missing, it's a big error ! So, the level fall immediately at 0.
#    if [ $RESULT_witness -eq 1 ]
#    then
#        log_error "Some witness files has been deleted during those tests ! It's a very bad thing !"
#        global_level=0
#    fi
#
#    # If the package linter returned a critical error, the app is flagged as broken / level 0
#    if [ $RESULT_linter_broken -eq 1 ]
#    then
#        log_error "The package linter reported a critical failure ! App is considered broken !"
#        global_level=0
#    fi
#
#    if [ $RESULT_alias_traversal -eq 1 ]
#    then
#        log_error "Issue alias_traversal was detected ! Please see here https://github.com/YunoHost/example_ynh/pull/45 to fix that."
#    fi
#
#    # Then, print the levels
#    # Print the global level
#    verbose_level=$(grep "^$global_level " "./levels.list" | cut -c4-)
#
#    log_info "Level of this application: $global_level ($verbose_level)"
#
#    # And print the value for each level
#    for i in `seq 1 10`
#    do
#        display="0"
#        if [ "${level[$i]}" -ge 1 ]; then
#            display="1"
#        fi
#        echo -e "\t   Level $i: $display"
#    done
