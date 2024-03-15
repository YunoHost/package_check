#!/bin/bash

#=================================================
# "Low-level" logistic helpers
#=================================================

_STUFF_TO_RUN_BEFORE_INITIAL_SNAPSHOT()
{
    # Print the version of YunoHost from the LXC container
    log_small_title "YunoHost versions"
    $lxc exec $LXC_NAME -t -- /bin/bash -c "yunohost --version" | tee -a "$full_log"

    log_title "Package linter"
    ./package_linter/package_linter.py "$package_path" | tee -a "$full_log"

    # Set witness files
    set_witness_files

    [[ -e $package_path/manifest.toml ]] || return

    # We filter apt deps starting with $app_id to prevent stupid issues with for example cockpit and transmission where the apt package is not properly reinstalled on reinstall-after-remove test ...
    local apt_deps=$(python3 -c "import toml, sys; t = toml.loads(sys.stdin.read()); P = t['resources'].get('apt', {}).get('packages', ''); P = P.replace(',', ' ').split() if isinstance(P, str) else P; P = [p for p in P if p != '$app_id' and not p.startswith('$app_id-')]; print(' '.join(P));" < $package_path/manifest.toml)

    if [[ -n "$apt_deps" ]]
    then
        log_title "Preinstalling apt dependencies before creating the initial snapshot..."

        apt="LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get --assume-yes --quiet -o=Acquire::Retries=3 -o=Dpkg::Use-Pty=0"
        $lxc exec $LXC_NAME -t -- /bin/bash -c "$apt update; $apt install $apt_deps" | tee -a "$full_log" >/dev/null
    fi

    # Gotta generate the psql password even though apparently it's not even useful anymore these days but it otherwise trigger warnings ~_~
    if echo "$apt_deps" | grep -q postgresql
    then
        $lxc exec $LXC_NAME -t -- /bin/bash -c "yunohost tools regen-conf postgresql" | tee -a "$full_log" >/dev/null
    fi
}


_RUN_YUNOHOST_CMD() {

    log_debug "Running yunohost $1"

    # Copy the package into the container.
    $lxc exec $LXC_NAME -- rm -rf /app_folder
    $lxc file push -p -r "$package_path" $LXC_NAME/app_folder --quiet

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
        sed -i "s/\$USER/$TEST_USER/g" "$preinstall_script"
        sed -i "s/\$DOMAIN/$DOMAIN/g" "$preinstall_script"
        sed -i "s/\$SUBDOMAIN/$SUBDOMAIN/g" "$preinstall_script"
        sed -i "s/\$PASSWORD/$YUNO_PWD/g" "$preinstall_script"
        # Copy the pre-install script into the container.
        $lxc file push "$preinstall_script" "$LXC_NAME/preinstall.sh"
        # Then execute the script to execute the pre-install commands.
        LXC_EXEC "bash /preinstall.sh"
    fi
}

_PREUPGRADE () {
    local preupgrade_template="$(jq -r '.preupgrade_template' $current_test_infos)"
    local commit=${1:-HEAD}

    # Exec the pre-upgrade instruction, if there one
    if [ -n "$preupgrade_template" ]
    then
        log_small_title "Running pre-upgrade steps"
        # Copy all the instructions into a script
        local preupgrade_script="$TEST_CONTEXT/preupgrade.sh"
        echo "$preupgrade_template" >> "$preupgrade_script"
        # Hydrate the template with variables
        sed -i "s/\$USER/$TEST_USER/g" "$preupgrade_script"
        sed -i "s/\$DOMAIN/$DOMAIN/g" "$preupgrade_script"
        sed -i "s/\$SUBDOMAIN/$SUBDOMAIN/g" "$preupgrade_script"
        sed -i "s/\$PASSWORD/$YUNO_PWD/g" "$preupgrade_script"
        sed -i "s/\$FROM_COMMIT/$commit/g" "$preupgrade_script"
        # Copy the pre-upgrade script into the container.
        $lxc file push "$preupgrade_script" "$LXC_NAME/preupgrade.sh"
        # Then execute the script to execute the pre-upgrade commands.
        LXC_EXEC "bash /preupgrade.sh"
        return $?
    fi
}

_TEST_CONFIG_PANEL() {
    if [[ -e "$package_path/config_panel.toml" ]]
    then
        # Call app config get, but with no output, we just want to check that no error is raised
        _RUN_YUNOHOST_CMD "app config get $app_id"
    fi
}

_INSTALL_APP () {
    local install_args="$(jq -r '.install_args' $current_test_infos)"

    # Make sure we have a trailing & because that assumption is used in some sed regex later
    [[ ${install_args: -1} == '&' ]] || install_args+="&"
    [[ ${install_args:0:1} == '&' ]] || install_args="&$install_args"

    # We have default values for domain, admin and is_public, but these
    # may still be overwritten by the args ($@)
    for arg_override in "domain=$SUBDOMAIN" "admin=$TEST_USER" "is_public=1" "init_main_permission=visitors" "$@"
    do
        key="$(echo $arg_override | cut -d '=' -f 1)"
        value="$(echo $arg_override | cut -d '=' -f 2-)"

        # (Legacy stuff ... We don't override is_public if its type is not boolean)
        [[ -e $package_path/manifest.json ]] \
            && [[ "$key" == "is_public" ]] \
            && [[ "$(jq -r '.arguments.install[] | select(.name=="is_public") | .type' $package_path/manifest.json)" != "boolean" ]] \
            && continue

        install_args=$(echo $install_args | sed "s@\&$key=[^&]*\&@\&$key=$value\&@")
    done

    # Note : we do this at this stage and not during the parsing of check_process
    # because this also applies to upgrades ... ie older version may have different args and default values

    # Fetch and loop over all manifest arg
    if [[ -e $package_path/manifest.json ]]
    then
        local manifest_args="$(jq -r '.arguments.install[].name' $package_path/manifest.json)"
    else
        local manifest_args="$(grep '^\s*\[install\.' $package_path/manifest.toml | tr -d '[]' | awk -F. '{print $2}')"
    fi

    for ARG in $manifest_args
    do
        # If the argument is not yet in install args, add its default value
        if ! echo "$install_args" | grep -q -E "\<$ARG="
        then
            if [[ -e $package_path/manifest.json ]]
            then
                local default_value=$(jq -e -r --arg ARG $ARG '.arguments.install[] | select(.name==$ARG) | .default' $package_path/manifest.json)
            else
                local default_value=$(python3 -c "import toml, sys; t = toml.loads(sys.stdin.read()); d = t['install']['$ARG'].get('default'); assert d is not None, 'Missing default value'; print(d)" < $package_path/manifest.toml)
            fi
            [[ $? -eq 0 ]] || { log_error "Missing install arg $ARG ?"; return 1; }
            [[ ${install_args: -1} == '&' ]] || install_args+="&"
            install_args+="$ARG=$default_value"
        fi
    done

    # Install the application in a LXC container
    log_info "Running: yunohost app install --no-remove-on-failure --force /app_folder -a \"$install_args\""
    _RUN_YUNOHOST_CMD "app install --no-remove-on-failure --force /app_folder -a \"$install_args\""

    local ret=$?
    [ $ret -eq 0 ] && log_debug "Installation successful." || log_error "Installation failed."

    if LXC_EXEC "su nobody -s /bin/bash -c \"test -r /var/www/$app_id || test -w /var/www/$app_id || test -x /var/www/$app_id\""
    then
        log_error "It looks like anybody can read/enter /var/www/$app_id, which ain't super great from a security point of view ... Config files or other files may contain secrets or information that should in most case not be world-readable. You should remove all 'others' permissions with 'chmod o-rwx', and setup appropriate, exclusive permissions to the appropriate owner/group with chmod/chown."
        SET_RESULT "failure" install_dir_permissions
    fi

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

    log_small_title "Validating that the app $app_id_to_check can/can't be accessed with its URL..."

    # Force the app to public only if we're checking the public-like installs AND visitors are allowed to access the app
    # For example, that's the case for agendav which is always installed as
    # private by default For "regular" apps (with a is_public arg) they are
    # installed as public, and we precisely want to check they are publicly
    # accessible *without* tweaking main permission...
    local has_public_arg=$(LXC_EXEC "cat /etc/ssowat/conf.json" | jq .permissions.\""$app_id_to_check.main"\".public)

    if [ "$install_type" != 'private' ] && [[ $has_public_arg == "false" ]]
    then
        log_debug "Forcing public access using tools shell"
        # Force the public access by setting force=True, which is not possible with "yunohost user permission update"
        _RUN_YUNOHOST_CMD "tools shell -c 'from yunohost.permission import user_permission_update; user_permission_update(\"$app_id_to_check.main\", add=\"visitors\", force=True)'"
    fi

    # Try to access to the URL in 2 times, with a final / and without
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
            sleep $(($retry*$retry*$retry + 3))

            log_debug "Running curl $check_domain$curl_check_path"

            # Call cURL to try to access to the URL of the app
            LXC_EXEC "curl --location --insecure --silent --show-error --cookie /dev/null \
                --header 'Host: $check_domain' \
                --resolve $DOMAIN:80:$LXC_IP \
                --resolve $DOMAIN:443:$LXC_IP \
                --resolve $SUBDOMAIN:80:$LXC_IP \
                --resolve $SUBDOMAIN:443:$LXC_IP \
                --write-out '%{http_code};%{url_effective}\n' \
                --output './curl_output' \
                $check_domain$curl_check_path" \
                > "$TEST_CONTEXT/curl_print"

            LXC_EXEC "cat ./curl_output" > $curl_output

            # Analyze the result of curl command
            if [ $? -ne 0 ]
            then
                log_error "Connection error..."
                curl_error=1
            fi

            http_code=$(cat "$TEST_CONTEXT/curl_print" | cut -d ';' -f1)

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

        # Analyze the output of cURL
        if [ -e "$curl_output" ]
        then
            # Print the title of the page
            local page_title=$(grep "<title>" "$curl_output" | cut --delimiter='>' --fields=2 | cut --delimiter='<' --fields=1)
            local page_extract=$(lynx -dump -force_html "$curl_output" | head --lines 20 | tee -a "$full_log")

            # Check if the page title is neither the YunoHost portail or default NGINX page
            if [ "$page_title" = "YunoHost Portal" ]
            then
                log_debug "The connection attempt fall on the YunoHost portal."
                fell_on_sso_portal=1
                # Falling on NGINX default page is an error.
            elif echo "$page_title" | grep -q "Welcome to nginx"
            then
                log_error "The connection attempt fall on NGINX default page."
                curl_error=1
            fi
        fi

        echo -e "Test URL: $check_domain$curl_check_path
Real URL: $(cat "$TEST_CONTEXT/curl_print" | cut --delimiter=';' --fields=2)
HTTP code: $http_code
Page title: $page_title
Page extract:\n$page_extract" > $TEST_CONTEXT/curl_result

        [[ $curl_error -eq 0 ]] \
            && log_debug "$(cat $TEST_CONTEXT/curl_result)" \
            || log_warning "$(cat $TEST_CONTEXT/curl_result)"

        # If we had a 50x error, try to display service info and logs to help debugging
        if [[ $curl_error -ne 0 ]] && echo "5" | grep -q "${http_code:0:1}"
        then
            LXC_EXEC "systemctl --no-pager --all" | grep "$app_id_to_check.*service"
            for SERVICE in $(LXC_EXEC "systemctl --no-pager -all" | grep -o "$app_id_to_check.*service")
            do
                LXC_EXEC "journalctl --no-pager --no-hostname -n 30 -u $SERVICE";
            done
            LXC_EXEC "tail -v -n 15 \$(find /var/log/{nginx/,php*,$app_id_to_check} -mmin -3)"
        fi
    done

    # Detect the issue alias_traversal, https://github.com/yandex/gixy/blob/master/docs/en/plugins/aliastraversal.md
    # Create a file to get for alias_traversal
    echo "<!DOCTYPE html><html><head>
    <title>alias_traversal test</title>
    </head><body><h1>alias_traversal test</h1>
    If you see this page, you have failed the test for alias_traversal issue.</body></html>" \
    > $TEST_CONTEXT/alias_traversal.html

    $lxc file push $TEST_CONTEXT/alias_traversal.html $LXC_NAME/var/www/html/alias_traversal.html

    curl --location --insecure --silent $check_domain$check_path../html/alias_traversal.html \
        | grep "title" | grep --quiet "alias_traversal test" \
        && log_error "Issue alias_traversal detected! Please see here https://github.com/YunoHost/example_ynh/pull/45 to fix that." \
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

TEST_PACKAGE_LINTER () {

    start_test "Package linter"

    # Execute package linter and linter_result gets the return code of the package linter
    ./package_linter/package_linter.py "$package_path" --json | tee -a "$full_log" > $current_test_results

    return ${PIPESTATUS[0]}
}

TEST_INSTALL () {

    local install_type=$1

    # This is a separate case ... at least from an hystorical point of view ...
    # but it helpers for semantic that the test is a "TEST_INSTALL" ...
    [ "$install_type" = "multi"   ] && { _TEST_MULTI_INSTANCE; return $?; }

    local check_path="/"
    local is_public="1"
    local init_main_permission="visitors"
    [ "$install_type" = "subdir"  ] && { start_test "Installation in a sub path";      local check_path=/path; }
    [ "$install_type" = "root"    ] && { start_test "Installation on the root";                                }
    [ "$install_type" = "nourl"   ] && { start_test "Installation without URL access"; local check_path="";    }
    [ "$install_type" = "private" ] && { start_test "Installation in private mode";    local is_public="0"; local init_main_permission="all_users";    }
    local snapname=snap_${install_type}install

    LOAD_LXC_SNAPSHOT snap0

    _PREINSTALL

    metrics_start

    # Install the application in a LXC container
    _INSTALL_APP "path=$check_path" "is_public=$is_public" "init_main_permission=$init_main_permission" \
        && _VALIDATE_THAT_APP_CAN_BE_ACCESSED "$SUBDOMAIN" "$check_path" "$install_type" \
        && _TEST_CONFIG_PANEL

    local install=$?

    metrics_stop

    [ $install -eq 0 ] || return 1

    # Create the snapshot that'll be used by other tests later
    [ "$install_type" != "private" ] \
        && ! LXC_SNAPSHOT_EXISTS $snapname \
        && log_debug "Create a snapshot after app install" \
        && CREATE_LXC_SNAPSHOT $snapname

    # Remove and reinstall the application
    _REMOVE_APP \
        && log_small_title "Reinstalling after removal." \
        && _INSTALL_APP "path=$check_path" "is_public=$is_public"  "init_main_permission=$init_main_permission" \
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
        pushd "$package_path"
        git checkout --force --quiet "$commit" || { log_error "Failed to checkout commit $commit ?"; return 1; }
        popd

        LOAD_LXC_SNAPSHOT snap0

        _PREINSTALL

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

    _PREUPGRADE "${commit}"
    ret=$?
    [ $ret -eq 0 ] || { log_error "Pre-upgrade instruction failed"; return 1; }

    metrics_start

    # Upgrade the application in a LXC container
    _RUN_YUNOHOST_CMD "app upgrade $app_id --file /app_folder --no-safety-backup --force" \
        && _VALIDATE_THAT_APP_CAN_BE_ACCESSED "$SUBDOMAIN" "$check_path" "upgrade" \
        && _TEST_CONFIG_PANEL

    ret=$?

    metrics_stop

    return $ret
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

    $lxc file push $TEST_CONTEXT/netcat.service $LXC_NAME/etc/systemd/system/netcat.service

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
        $lxc file pull -r $LXC_NAME/home/yunohost.backup/archives $TEST_CONTEXT/ynh_backups

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
                $lxc file push -r $TEST_CONTEXT/ynh_backups/archives $LXC_NAME/home/yunohost.backup/

                _PREINSTALL

                log_small_title "Restore on a fresh YunoHost system..."
            fi

            # Restore the application from the previous backup
            metrics_start
            _RUN_YUNOHOST_CMD "backup restore Backup_test --force --apps $app_id" \
                && _VALIDATE_THAT_APP_CAN_BE_ACCESSED "$SUBDOMAIN" "$check_path" \
                && _TEST_CONFIG_PANEL

            ret=$?
            metrics_stop
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
    for i in $(seq 1 8)
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

        # Other domain, same path
        elif [ $i -eq 5 ]; then
            local new_path=/path
            local new_domain=$SUBDOMAIN

        # Other domain, path to path
        elif [ $i -eq 6 ]; then
            local new_path=/path_2
            local new_domain=$DOMAIN

        # Other domain, path to root
        elif [ $i -eq 7 ]; then
            local new_path=/
            local new_domain=$SUBDOMAIN

        # Other domain, same path
        elif [ $i -eq 8 ]; then
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

        log_small_title "Changing the URL from $current_domain$current_path to $new_domain$new_path..." \
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
