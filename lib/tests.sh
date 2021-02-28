#!/bin/bash

#=================================================
# "Low-level" logistic helpers
#=================================================

_RUN_YUNOHOST_CMD() {

    log_debug "Running yunohost $1"

    # Copy the package into the container.
    lxc exec $LXC_NAME -- rm -rf /app_folder
    lxc file push -p -r "$package_path" $LXC_NAME/app_folder --quiet

    # --output-as none is to disable the json-like output for some commands like backup create
    LXC_EXEC "yunohost --output-as none --debug $1" \
        | grep --line-buffered -v --extended-regexp '^[0-9]+\s+.{1,15}DEBUG' \
        | grep --line-buffered -v 'processing action'

    returncode=${PIPESTATUS[0]}
    check_witness_files && return $returncode || return 2
}

_PREINSTALL () {
    local preinstall_template="$(jq -r '.preinstall_template' $current_test_infos)"

    # Exec the pre-install instruction, if there one
    if [ -n "$preinstall_template" ]
    then
        log_small_title "Running pre-install steps"
        # Copy all the instructions into a script
        local preinstall_script="$TEST_CONTEXT/preinstall.sh"
        echo "$preinstall_template" > "$preinstall_script"
        # Hydrate the template with variables
        sed -i "s/\$USER/$TEST_USER/" "$preinstall_script"
        sed -i "s/\$DOMAIN/$DOMAIN/" "$preinstall_script"
        sed -i "s/\$SUBDOMAIN/$SUBDOMAIN/" "$preinstall_script"
        sed -i "s/\$PASSWORD/$YUNO_PWD/" "$preinstall_script"
        # Copy the pre-install script into the container.
        lxc file push "$preinstall_script" "$LXC_NAME/preinstall.sh"
        # Then execute the script to execute the pre-install commands.
        LXC_EXEC "bash /preinstall.sh"
    fi
}

_INSTALL_APP () {
    local install_args="$(jq -r '.install_args' $current_test_infos)"

    # Make sure we have a trailing & because that assumption is used in some sed regex later
    [[ ${install_args: -1} == '&' ]] || install_args+="&"

    # We have default values for domain, admin and is_public, but these
    # may still be overwritten by the args ($@)
    for arg_override in "domain=$SUBDOMAIN" "admin=$TEST_USER" "is_public=1" "$@"
    do
        key="$(echo $arg_override | cut -d '=' -f 1)"
        value="$(echo $arg_override | cut -d '=' -f 2-)"

        # (Legacy stuff ... We don't override is_public if its type is not boolean)
        [[ "$key" == "is_public" ]] \
            && [[ "$(jq -r '.arguments.install[] | select(.name=="is_public") | .type' $package_path/manifest.json)" != "boolean" ]] \
            && continue

        install_args=$(echo $install_args | sed "s@$key=[^&]*\&@$key=$value\&@")
    done

    # Note : we do this at this stage and not during the parsing of check_process
    # because this also applies to upgrades ...
    # For all manifest arg
    for ARG in $(jq -r '.arguments.install[].name' $package_path/manifest.json)
    do
        # If the argument is not yet in install args, add its default value
        if ! echo "$install_args" | grep -q -E "\<$ARG="
        then
            local default_value=$(jq -e -r --arg ARG $ARG '.arguments.install[] | select(.name==$ARG) | .default' $package_path/manifest.json)
            [[ $? -eq 0 ]] || { log_error "Missing install arg $ARG ?"; return 1; }
            [[ ${install_args: -1} == '&' ]] || install_args+="&"
            install_args+="$ARG=$default_value"
        fi
    done

    # Install the application in a LXC container
    log_info "Running: yunohost app install --force /app_folder -a $install_args"
    _RUN_YUNOHOST_CMD "app install --force /app_folder -a $install_args"

    local ret=$?
    [ $ret -eq 0 ] && log_debug "Installation successful." || log_error "Installation failed."
    return $ret
}

_LOAD_SNAPSHOT_OR_INSTALL_APP () {

    local check_path="$1"
    local _install_type="$(path_to_install_type $check_path)"
    local snapname="snap_${_install_type}install"

    if ! LXC_SNAPSHOT_EXISTS $snapname
    then
        log_warning "Expected to find an existing snapshot $snapname but it doesn't exist yet .. will attempt to create it"
        LOAD_LXC_SNAPSHOT snap0 \
            && _PREINSTALL \
            && _INSTALL_APP "path=$check_path" \
            && CREATE_LXC_SNAPSHOT $snapname
    else
        # Or uses an existing snapshot
        log_info "(Reusing existing snapshot $snapname)" \
            && LOAD_LXC_SNAPSHOT $snapname
    fi
}


_REMOVE_APP () {
    # Remove an application

    break_before_continue

    log_small_title "Removing the app..."

    # Remove the application from the LXC container
    _RUN_YUNOHOST_CMD "app remove $app_id"

    local ret=$?
    [ "$ret" -eq 0 ] && log_debug "Remove successful." || log_error "Remove failed."
    return $ret
}

_VALIDATE_THAT_APP_CAN_BE_ACCESSED () {

    local check_domain="$1"
    local check_path="$2"
    local install_type="$3"      # Can be anything or 'private', later used to check if it's okay to end up on the portal
    local app_id_to_check="${4:-$app_id}"

    local curl_error=0
    local fell_on_sso_portal=0
    local curl_output=$TEST_CONTEXT/curl_output

    # Not checking this if this ain't relevant for the current app
    this_is_a_web_app || return 0

    log_small_title "Validating that the app can (or cannot) be accessed with its url..."

    # Force the app to public only if we're checking the public-like installs AND there's no is_public arg
    # For example, that's the case for agendav which is always installed as
    # private by default For "regular" apps (with a is_public arg) they are
    # installed as public, and we precisely want to check they are publicly
    # accessible *without* tweaking skipped_uris...
    if [ "$install_type" != 'private' ] && [[ -z "$(jq -r '.arguments.install[] | select(.name=="is_public")' $package_path/manifest.json)" ]]
    then
        log_debug "Forcing public access using a skipped_uris setting"
        # Add a skipped_uris on / for the app
        _RUN_YUNOHOST_CMD "app setting $app_id_to_check skipped_uris -v /"
        # Regen the config of sso
        _RUN_YUNOHOST_CMD "app ssowatconf"
    fi

    # Try to access to the url in 2 times, with a final / and without
    for i in $(seq 1 2)
    do

        # First time we'll try without the trailing slash,
        # Second time *with* the trailing slash
        local curl_check_path="$(echo $check_path | sed 's@/$@@g')"
        [ $i -eq 1 ] || curl_check_path="$curl_check_path/"

        # Remove the previous curl output
        rm -f "$curl_output"

        local http_code="noneyet"

        local retry=0
        function should_retry() {
            [ "${http_code}" = "noneyet" ] || [ "${http_code}" = "502" ] || [ "${http_code}" = "503" ] || [ "${http_code}" = "504" ]
        }

        while [ $retry -lt 3 ] && should_retry;
        do
            sleep 1

            log_debug "Running curl $check_domain$curl_check_path"

            # Call curl to try to access to the url of the app
            curl --location --insecure --silent --show-error \
                --header "Host: $check_domain" \
                --resolve $DOMAIN:80:$LXC_IP \
                --resolve $DOMAIN:443:$LXC_IP \
                --resolve $SUBDOMAIN:80:$LXC_IP \
                --resolve $SUBDOMAIN:443:$LXC_IP \
                --write-out "%{http_code};%{url_effective}\n" \
                --output "$curl_output" \
                $check_domain$curl_check_path \
                > "./curl_print"

            # Analyze the result of curl command
            if [ $? -ne 0 ]
            then
                log_error "Connection error..."
                curl_error=1
            fi

            http_code=$(cat "./curl_print" | cut -d ';' -f1)

            log_debug "HTTP code: $http_code"

            retry=$((retry+1))
        done

        # Analyze the http code (we're looking for 0xx 4xx 5xx 6xx codes)
        if [ -n "$http_code" ] && echo "0 4 5 6" | grep -q "${http_code:0:1}"
        then
            # If the http code is a 0xx 4xx or 5xx, it's an error code.
            curl_error=1

            # 401 is "Unauthorized", so is a answer of the server. So, it works!
            [ "${http_code}" == "401" ] && curl_error=0

            [ $curl_error -eq 1 ] && log_error "The HTTP code shows an error."
        fi

        # Analyze the output of curl
        if [ -e "$curl_output" ]
        then
            # Print the title of the page
            local page_title=$(grep "<title>" "$curl_output" | cut --delimiter='>' --fields=2 | cut --delimiter='<' --fields=1)
            local page_extract=$(lynx -dump -force_html "$curl_output" | head --lines 20 | tee -a "$complete_log")

            # Check if the page title is neither the YunoHost portail or default nginx page
            if [ "$page_title" = "YunoHost Portal" ]
            then
                log_debug "The connection attempt fall on the YunoHost portal."
                fell_on_sso_portal=1
                # Falling on nginx default page is an error.
            elif echo "$page_title" | grep -q "Welcome to nginx"
            then
                log_error "The connection attempt fall on nginx default page."
                curl_error=1
            fi
        fi

        echo -e "Test url: $check_domain$curl_check_path
Real url: $(cat "./curl_print" | cut --delimiter=';' --fields=2)
HTTP code: $http_code
Page title: $page_title
Page extract:\n$page_extract" > $TEST_CONTEXT/curl_result

        [[ $curl_error -eq 0 ]] \
            && log_debug "$(cat $TEST_CONTEXT/curl_result)" \
            || log_warning "$(cat $TEST_CONTEXT/curl_result)"
    done

    # Detect the issue alias_traversal, https://github.com/yandex/gixy/blob/master/docs/en/plugins/aliastraversal.md
    # Create a file to get for alias_traversal
    echo "<!DOCTYPE html><html><head>
    <title>alias_traversal test</title>
    </head><body><h1>alias_traversal test</h1>
    If you see this page, you have failed the test for alias_traversal issue.</body></html>" \
    > $TEST_CONTEXT/alias_traversal.html

    lxc file push $TEST_CONTEXT/alias_traversal.html $LXC_NAME/var/www/html/alias_traversal.html

    curl --location --insecure --silent $check_domain$check_path../html/alias_traversal.html \
        | grep "title" | grep --quiet "alias_traversal test" \
        && log_error "Issue alias_traversal detected ! Please see here https://github.com/YunoHost/example_ynh/pull/45 to fix that." \
        && SET_RESULT "failure" alias_traversal

    [ "$curl_error" -eq 0 ] || return 1
    local expected_to_fell_on_portal=""
    [ "$install_type" == "private" ] && expected_to_fell_on_portal=1 || expected_to_fell_on_portal=0

    if [ "$install_type" == "root" ] || [ "$install_type" == "subdir" ] || [ "$install_type" == "upgrade" ];
    then
        log_info "$(cat $TEST_CONTEXT/curl_result)"
    fi

    [ $fell_on_sso_portal -eq $expected_to_fell_on_portal ] || return 1

    return 0
}


#=================================================
# The
# Actual
# Tests
#=================================================

PACKAGE_LINTER () {

    start_test "Package linter"

    # Execute package linter and linter_result gets the return code of the package linter
    ./package_linter/package_linter.py "$package_path" | tee -a "$complete_log"
    ./package_linter/package_linter.py "$package_path" --json | tee -a "$complete_log" > $current_test_results

    return $?
}

TEST_INSTALL () {

    local install_type=$1

    # This is a separate case ... at least from an hystorical point of view ...
    # but it helpers for semantic that the test is a "TEST_INSTALL" ...
    [ "$install_type" = "multi"   ] && { _TEST_MULTI_INSTANCE; return $?; }

    local check_path="/"
    local is_public="1"
    [ "$install_type" = "subdir"  ] && { start_test "Installation in a sub path";      local check_path=/path; }
    [ "$install_type" = "root"    ] && { start_test "Installation on the root";                                }
    [ "$install_type" = "nourl"   ] && { start_test "Installation without url access"; local check_path="";    }
    [ "$install_type" = "private" ] && { start_test "Installation in private mode";    local is_public="0";    }
    local snapname=snap_${install_type}install

    LOAD_LXC_SNAPSHOT snap0

    _PREINSTALL

    # Install the application in a LXC container
   _INSTALL_APP "path=$check_path" "is_public=$is_public" \
        && _VALIDATE_THAT_APP_CAN_BE_ACCESSED "$SUBDOMAIN" "$check_path" "$install_type" \

    local install=$?

    [ $install -eq 0 ] || return 1

    # Create the snapshot that'll be used by other tests later
    [ "$install_type" != "private" ] \
        && ! LXC_SNAPSHOT_EXISTS $snapname \
        && log_debug "Create a snapshot after app install" \
        && CREATE_LXC_SNAPSHOT $snapname

    # Remove and reinstall the application
    _REMOVE_APP \
        && log_small_title "Reinstalling after removal." \
        &&_INSTALL_APP "path=$check_path" "is_public=$is_public" \
        && _VALIDATE_THAT_APP_CAN_BE_ACCESSED "$SUBDOMAIN" "$check_path" "$install_type"

    return $?
}

_TEST_MULTI_INSTANCE () {

    start_test "Multi-instance installations"

    # Check if an install have previously work
    at_least_one_install_succeeded || return 1

    local check_path="$(default_install_path)"

    LOAD_LXC_SNAPSHOT snap0

    log_small_title "First installation: path=$SUBDOMAIN$check_path" \
        && _LOAD_SNAPSHOT_OR_INSTALL_APP "$check_path" \
        && log_small_title "Second installation: path=$DOMAIN$check_path" \
        && _INSTALL_APP "domain=$DOMAIN" "path=$check_path" \
        && _VALIDATE_THAT_APP_CAN_BE_ACCESSED $SUBDOMAIN "$check_path" \
        && _VALIDATE_THAT_APP_CAN_BE_ACCESSED $DOMAIN "$check_path" "" ${app_id}__2 \
        && _REMOVE_APP \
        && _VALIDATE_THAT_APP_CAN_BE_ACCESSED $DOMAIN "$check_path" "" ${app_id}__2

    return $?
}

TEST_UPGRADE () {

    local commit=$1

    if [ "$commit" == "" ]
    then
        start_test "Upgrade from the same version"
    else
        upgrade_name="$(jq -r '.extra.upgrade_name' $current_test_infos)"
        [ -n "$upgrade_name" ] || upgrade_name="commit $commit"
        start_test "Upgrade from $upgrade_name"
    fi

    at_least_one_install_succeeded || return 1

    local check_path="$(default_install_path)"

    # Install the application in a LXC container
    log_small_title "Preliminary install..."
    if [ "$commit" == "" ]
    then
        # If no commit is specified, use the current version.
        _LOAD_SNAPSHOT_OR_INSTALL_APP "$check_path"
        local ret=$?
    else
        # Make a backup of the directory
        # and Change to the specified commit
        cp -a "$package_path" "${package_path}_back"
        (cd "$package_path"; git checkout --force --quiet "$commit")

        LOAD_LXC_SNAPSHOT snap0

        # Install the application
        _INSTALL_APP "path=$check_path"

        local ret=$?

        # Test if the app can be accessed (though we don't want to report an
        # error if it's not, in that context) ... but the point
        # is to display the curl page
        _VALIDATE_THAT_APP_CAN_BE_ACCESSED "$SUBDOMAIN" "$check_path" "upgrade"

        # Then replace the backup
        rm -rf "$package_path"
        mv "${package_path}_back" "$package_path"
    fi

    # Check if the install worked
    [ $ret -eq 0 ] || { log_error "Initial install failed... upgrade test ignore"; return 1; }

    log_small_title "Upgrade..."

    # Upgrade the application in a LXC container
    _RUN_YUNOHOST_CMD "app upgrade $app_id --file /app_folder --force" \
        && _VALIDATE_THAT_APP_CAN_BE_ACCESSED "$SUBDOMAIN" "$check_path" "upgrade"

    return $?
}

TEST_PORT_ALREADY_USED () {

    start_test "Port already used"

    # Check if an install have previously work
    at_least_one_install_succeeded || return 1

    local check_port="$1"
    local check_path="$(default_install_path)"

    LOAD_LXC_SNAPSHOT snap0

    # Build a service with netcat for use this port before the app.
    echo -e "[Service]\nExecStart=/bin/netcat -l -k -p $check_port\n
    [Install]\nWantedBy=multi-user.target" > $TEST_CONTEXT/netcat.service

    lxc file push $TEST_CONTEXT/netcat.service $LXC_NAME/etc/systemd/system/netcat.service

    # Then start this service to block this port.
    LXC_EXEC "systemctl enable --now netcat"

    _PREINSTALL

    # Install the application in a LXC container
   _INSTALL_APP "path=$check_path" "port=$check_port" \
        && _VALIDATE_THAT_APP_CAN_BE_ACCESSED $SUBDOMAIN "$check_path"

    return $?
}

TEST_BACKUP_RESTORE () {

    # Try to backup then restore the app

    start_test "Backup/Restore"

    # Check if an install have previously work
    at_least_one_install_succeeded || return 1

    local check_paths=()

    if this_is_a_web_app; then
        there_is_a_root_install_test && check_paths+=("$(root_path)")
        there_is_a_subdir_install_test && check_paths+=("$(subdir_path)")
    else
        check_paths+=("")
    fi

    local main_result=0

    for check_path in "${check_paths[@]}"
    do
        # Install the application in a LXC container
        _LOAD_SNAPSHOT_OR_INSTALL_APP "$check_path"

        local ret=$?

        # Remove the previous residual backups
        rm -rf $TEST_CONTEXT/ynh_backups
        RUN_INSIDE_LXC rm -rf /home/yunohost.backup/archives

        # BACKUP
        # Made a backup if the installation succeed
        if [ $ret -ne 0 ]
        then
            log_error "Installation failed..."
            main_result=1
            break_before_continue
            continue
        else
            log_small_title "Backup of the application..."

            # Made a backup of the application
            _RUN_YUNOHOST_CMD "backup create -n Backup_test --apps $app_id"
            ret=$?
        fi
    
        [ $ret -eq 0 ] || { main_result=1; break_before_continue; continue; }

        # Grab the backup archive into the LXC container, and keep a copy
        lxc file pull -r $LXC_NAME/home/yunohost.backup/archives $TEST_CONTEXT/ynh_backups

        # RESTORE
        # Try the restore process in 2 times, first after removing the app, second after a restore of the container.
        local j=0
        for j in 0 1
        do
            # First, simply remove the application
            if [ $j -eq 0 ]
            then
                # Remove the application
                _REMOVE_APP

                log_small_title "Restore after removing the application..."

                # Second, restore the whole container to remove completely the application
            elif [ $j -eq 1 ]
            then

                LOAD_LXC_SNAPSHOT snap0

                # Remove the previous residual backups
                RUN_INSIDE_LXC rm -rf /home/yunohost.backup/archives

                # Place the copy of the backup archive in the container.
                lxc file push -r $TEST_CONTEXT/ynh_backups/archives $LXC_NAME/home/yunohost.backup/
            
                _PREINSTALL

                log_small_title "Restore on a fresh YunoHost system..."
            fi

            # Restore the application from the previous backup
            _RUN_YUNOHOST_CMD "backup restore Backup_test --force --apps $app_id" \
                && _VALIDATE_THAT_APP_CAN_BE_ACCESSED "$SUBDOMAIN" "$check_path"

            ret=$?
            [ $ret -eq 0 ] || main_result=1

            break_before_continue
        done
    done

    return $main_result
}

TEST_CHANGE_URL () {
    # Try the change_url script

    start_test "Change URL"

    # Check if an install have previously work
    at_least_one_install_succeeded || return 1
    this_is_a_web_app || return 0

    local current_domain=$SUBDOMAIN
    local current_path="$(default_install_path)"

    log_small_title "Preliminary install..." \
        && _LOAD_SNAPSHOT_OR_INSTALL_APP "$current_path"

    local ret=$?
    [ $ret -eq 0 ] || { return 1; }

    # Try in 6 times !
    # Without modify the domain, root to path, path to path and path to root.
    # And then, same with a domain change
    local i=0
    for i in $(seq 1 6)
    do
        # Same domain, root to path
        if [ $i -eq 1 ]; then
            local new_path=/path
            local new_domain=$SUBDOMAIN

        # Same domain, path to path
        elif [ $i -eq 2 ]; then
            local new_path=/path_2
            local new_domain=$SUBDOMAIN

        # Same domain, path to root
        elif [ $i -eq 3 ]; then
            local new_path=/
            local new_domain=$SUBDOMAIN

        # Other domain, root to path
        elif [ $i -eq 4 ]; then
            local new_path=/path
            local new_domain=$DOMAIN

        # Other domain, path to path
        elif [ $i -eq 5 ]; then
            local new_path=/path_2
            local new_domain=$DOMAIN

        # Other domain, path to root
        elif [ $i -eq 6 ]; then
            local new_path=/
            local new_domain=$DOMAIN
        fi

        if [ "$new_path" == "$current_path" ] && [ "$new_domain" == "$current_domain" ]; then
            continue
        elif ! there_is_a_root_install_test && [ "$new_path" == "/" ]; then
            continue
        elif ! there_is_a_subdir_install_test  && [ "$new_path" != "/" ]; then
            continue
        fi

        log_small_title "Changing the url from $current_domain$current_path to $new_domain$new_path..." \
            && _RUN_YUNOHOST_CMD "app change-url $app_id -d $new_domain -p $new_path" \
            && _VALIDATE_THAT_APP_CAN_BE_ACCESSED $new_domain $new_path

        local ret=$?
        [ $ret -eq 0 ] || { return 1; }

        current_domain=$new_domain
        current_path=$new_path

        break_before_continue
    done

    return 0
}


ACTIONS_CONFIG_PANEL () {

    test_type=$1

    # Define a function to split a file in multiple parts. Used for actions and config-panel toml
    splitterAA()
    {
        local bound="$1"
        local file="$2"

        # If $2 is a real file
        if [ -e "$file" ]
        then
            # Replace name of the file by its content
            file="$(cat "$file")"
        fi

        local file_lenght=$(echo "$file" | wc --lines | awk '{print $1}')

        bounds=($(echo "$file" | grep --line-number --extended-regexp "$bound" | cut -d':' -f1))

        # Go for each line number (boundary) into the array
        for line_number in $(seq 0 $(( ${#bounds[@]} -1 )))
        do
            # The first bound is the next line number in the array
            # That the low bound on which we cut
            first_bound=$(( ${bounds[$line_number+1]} - 1 ))
            # If there's no next cell in the array, we got -1, in such case, use the lenght of the file.
            # We cut at the end of the file
            test $first_bound -lt 0 && first_bound=$file_lenght
            # The second bound is the current line number in the array minus the next one.
            # The the upper bound in the file.
            second_bound=$(( ${bounds[$line_number]} - $first_bound - 1 ))
            # Cut the file a first time from the beginning to the first bound
            # And a second time from the end, back to the second bound.
            parts[line_number]="$(echo "$file" | head --lines=$first_bound \
                | tail --lines=$second_bound)"
        done
    }

    if [ "$test_type" == "actions" ]
    then
        start_test "Actions"

        toml_file="$package_path/actions.toml"
        if [ ! -e "$toml_file" ]
        then
            log_error "No actions.toml found !"
            return 1
        fi
    elif [ "$test_type" == "config_panel" ]
    then
        start_test "Config-panel"

        toml_file="$package_path/config_panel.toml"
        if [ ! -e "$toml_file" ]
        then
            log_error "No config_panel.toml found !"
            return 1
        fi
    fi

    # Check if an install have previously work
    at_least_one_install_succeeded || return 1

    # Install the application in a LXC container
    log_small_title "Preliminary install..."
    local check_path="$(default_install_path)"
    _LOAD_SNAPSHOT_OR_INSTALL_APP "$check_path"

    local main_result=0

    # List first, then execute
    local ret=0
    local i=0
    for i in $(seq 1 2)
    do
        # Do a test if the installation succeed
        if [ $ret -ne 0 ]
        then
            log_error "The previous test has failed..."
            continue
        fi

        if [ $i -eq 1 ]
        then
            if [ "$test_type" == "actions" ]
            then
                log_info "> List the available actions..."

                # List the actions
                _RUN_YUNOHOST_CMD "app action list $app_id"
                local ret=$?

                [ $ret -eq 0 ] || main_result=1
                break_before_continue

            elif [ "$test_type" == "config_panel" ]
            then
                log_info "> Show the config panel..."

                # Show the config-panel
                _RUN_YUNOHOST_CMD "app config show-panel $app_id"
                local ret=$?
                [ $ret -eq 0 ] || main_result=1
                break_before_continue

            fi
        elif [ $i -eq 2 ]
        then
            local parts
            if [ "$test_type" == "actions" ]
            then
                log_info "> Execute the actions..."

                # Split the actions.toml file to separate each actions
                splitterAA "^[[:blank:]]*\[[^.]*\]" "$toml_file"
            elif [ "$test_type" == "config_panel" ]
            then
                log_info "> Apply configurations..."

                # Split the config_panel.toml file to separate each configurations
                splitterAA "^[[:blank:]]*\[.*\]" "$toml_file"
            fi

            # Read each part, each action, one by one
            for part in $(seq 0 $(( ${#parts[@]} -1 )))
            do
                local action_config_argument_name=""
                local action_config_argument_type=""
                local action_config_argument_default=""
                local actions_config_arguments_specifics=""
                local nb_actions_config_arguments_specifics=1

                # Ignore part of the config_panel which are only titles
                if [ "$test_type" == "config_panel" ]
                then
                    # A real config_panel part should have a `ask = ` line. Ignore the part if not.
                    if ! echo "${parts[$part]}" | grep --quiet --extended-regexp "^[[:blank:]]*ask ="
                    then
                        continue
                    fi
                    # Get the name of the config. ask = "Config ?"
                    local action_config_name="$(echo "${parts[$part]}" | grep "ask *= *" | sed 's/^.* = \"\(.*\)\"/\1/')"

                    # Get the config argument name "YNH_CONFIG_part1_part2.part3.partx"
                    local action_config_argument_name="$(echo "${parts[$part]}" | grep "^[[:blank:]]*\[.*\]$")"
                    # Remove []
                    action_config_argument_name="${action_config_argument_name//[\[\]]/}"
                    # And remove spaces
                    action_config_argument_name="${action_config_argument_name// /}"

                elif [ "$test_type" == "actions" ]
                then
                    # Get the name of the action. name = "Name of the action"
                    local action_config_name="$(echo "${parts[$part]}" | grep "name" | sed 's/^.* = \"\(.*\)\"/\1/')"

                    # Get the action. [action]
                    local action_config_action="$(echo "${parts[$part]}" | grep "^\[.*\]$" | sed 's/\[\(.*\)\]/\1/')"
                fi

                # Check if there's any [action.arguments]
                # config_panel always have arguments.
                if echo "${parts[$part]}" | grep --quiet "$action_config_action\.arguments" || [ "$test_type" == "config_panel" ]
                then local action_config_has_arguments=1
                else local action_config_has_arguments=0
                fi

                # If there's arguments for this action.
                if [ $action_config_has_arguments -eq 1 ]
                then
                    if [ "$test_type" == "actions" ]
                    then
                        # Get the argument [action.arguments.name_of_the_argument]
                        action_config_argument_name="$(echo "${parts[$part]}" | grep "$action_config_action\.arguments\." | sed 's/.*\.\(.*\)]/\1/')"
                    fi

                    # Get the type of the argument. type = "type"
                    action_config_argument_type="$(echo "${parts[$part]}" | grep "type" | sed 's/^.* = \"\(.*\)\"/\1/')"
                    # Get the default value of this argument. default = true
                    action_config_argument_default="$(echo "${parts[$part]}" | grep "default" | sed 's/^.* = \(.*\)/\1/')"
                    # Do not use true or false, use 1/0 instead
                    if [ "$action_config_argument_default" == "true" ] && [ "$action_config_argument_type" == "boolean" ]; then
                        action_config_argument_default=1
                    elif [ "$action_config_argument_default" == "false" ] && [ "$action_config_argument_type" == "boolean" ]; then
                        action_config_argument_default=0
                    fi

                    if [ "$test_type" == "config_panel" ]
                    then
                        check_process_arguments=""
                        while read line
                        do
                            # Remove all double quotes
                            add_arg="${line//\"/}"
                            # Then add this argument and follow it by :
                            check_process_arguments="${check_process_arguments}${add_arg}:"
                        done < <(jq -r '.extra.configpanel' $current_test_infos)
                    elif [ "$test_type" == "actions" ]
                    then
                        local check_process_arguments=""
                        while read line
                        do
                            # Remove all double quotes
                            add_arg="${line//\"/}"
                            # Then add this argument and follow it by :
                            check_process_arguments="${check_process_arguments}${add_arg}:"
                        done < <(jq -r '.extra.actions' $current_test_infos)
                    fi
                    # Look for arguments into the check_process
                    if echo "$check_process_arguments" | grep --quiet "$action_config_argument_name"
                    then
                        # If there's arguments for this actions into the check_process
                        # Isolate the values
                        actions_config_arguments_specifics="$(echo "$check_process_arguments" | sed "s/.*$action_config_argument_name=\(.*\)/\1/")"
                        # And remove values of the following action
                        actions_config_arguments_specifics="${actions_config_arguments_specifics%%\:*}"
                        nb_actions_config_arguments_specifics=$(( $(echo "$actions_config_arguments_specifics" | tr --complement --delete "|" | wc --chars) + 1 ))
                    fi

                    if [ "$test_type" == "config_panel" ]
                    then
                        # Finish to format the name
                        # Remove . by _
                        action_config_argument_name="${action_config_argument_name//./_}"
                        # Move all characters to uppercase
                        action_config_argument_name="${action_config_argument_name^^}"
                        # Add YNH_CONFIG_
                        action_config_argument_name="YNH_CONFIG_$action_config_argument_name"
                    fi
                fi

                # Loop on the number of values into the check_process.
                # Or loop once for the default value
                for j in $(seq 1 $nb_actions_config_arguments_specifics)
                do
                    local action_config_argument_built=""
                    if [ $action_config_has_arguments -eq 1 ]
                    then
                        # If there's values into the check_process
                        if [ -n "$actions_config_arguments_specifics" ]
                        then
                            # Build the argument from a value from the check_process
                            local action_config_actual_argument="$(echo "$actions_config_arguments_specifics" | cut -d'|' -f $j)"
                            action_config_argument_built="--args $action_config_argument_name=$action_config_actual_argument"
                        elif [ -n "$action_config_argument_default" ]
                        then
                            # Build the argument from the default value
                            local action_config_actual_argument="$action_config_argument_default"
                            action_config_argument_built="--args $action_config_argument_name=$action_config_actual_argument"
                        else
                            log_warning "> No argument into the check_process to use or default argument for \"$action_config_name\"..."
                            action_config_actual_argument=""
                        fi

                        if [ "$test_type" == "config_panel" ]
                        then
                            log_info "> Apply the configuration for \"$action_config_name\" with the argument \"$action_config_actual_argument\"..."
                        elif [ "$test_type" == "actions" ]
                        then
                            log_info "> Execute the action \"$action_config_name\" with the argument \"$action_config_actual_argument\"..."
                        fi
                    else
                        log_info "> Execute the action \"$action_config_name\"..."
                    fi

                    if [ "$test_type" == "config_panel" ]
                    then
                        # Aply a configuration
                        _RUN_YUNOHOST_CMD "app config apply $app_id $action_config_action $action_config_argument_built"
                        ret=$?
                    elif [ "$test_type" == "actions" ]
                    then
                        # Execute an action
                        _RUN_YUNOHOST_CMD "app action run $app_id $action_config_action $action_config_argument_built"
                        ret=$?
                    fi
                    [ $ret -eq 0 ] || main_result=1
                    break_before_continue
                done
            done
        fi
    done

    return $main_result
}
