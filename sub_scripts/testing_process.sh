#!/bin/bash

echo -e "Loads functions from testing_process.sh"

#=================================================
# Globals variables
#=================================================

# A complete list of backup hooks is available at /usr/share/yunohost/hooks/backup/
backup_hooks="conf_ssowat data_home conf_ynh_firewall conf_cron"

#=================================================

break_before_continue () {
    # Make a break if auto_remove is set

    if [ $auto_remove -eq 0 ] && [ $bash_mode -ne 1 ]
    then
        LXC_CONNECT_INFO	# Print access information
        read -p "Press a key to delete the application and continue...." < /dev/tty
    fi
}


#=================================================

PRINT_YUNOHOST_VERSION () {
    small_title "YunoHost versions"

    # Print the version of YunoHost from the LXC container
    LXC_START "sudo yunohost --version"

    # Get the version of YunoHost from the LXC container
    ynh_version=$(ssh -q $lxc_name "sudo yunohost --version --output-as json | jq '.yunohost.version' | tr -d '\"'")
}

#=================================================
# Install and remove an app
#=================================================

run_yunohost() {

    # --output-as none is to disable the json-like output for some commands like backup create
    LXC_START "sudo PACKAGE_CHECK_EXEC=1 yunohost --output-as none --debug $1" \
        | grep -v --extended-regexp '^[0-9]+\s+.{1,15}DEBUG' \
        | grep -v 'processing action'

    returncode=${PIPESTATUS[0]}
    check_witness_files
    return $returncode
}


SETUP_APP () {
    # Install an application in a LXC container

    # Uses the default snapshot
    current_snapshot=snap0

    # Exec the pre-install instruction, if there one
    if [ -n "$pre_install" ]
    then
        small_title "Pre installation request"
        # Start the lxc container
        LXC_START "true"
        # Copy all the instructions into a script
        echo "$pre_install" > "$script_dir/preinstall.sh"
        chmod +x "$script_dir/preinstall.sh"
        # Replace variables
        sed -i "s/\$USER/$test_user/" "$script_dir/preinstall.sh"
        sed -i "s/\$DOMAIN/$main_domain/" "$script_dir/preinstall.sh"
        sed -i "s/\$SUBDOMAIN/$sub_domain/" "$script_dir/preinstall.sh"
        sed -i "s/\$PASSWORD/$yuno_pwd/" "$script_dir/preinstall.sh"
        # Copy the pre-install script into the container.
        scp -rq "$script_dir/preinstall.sh" "$lxc_name":
        # Then execute the script to execute the pre-install commands.
        LXC_START "./preinstall.sh >&2" | tee -a "$complete_log"
    fi

    # Install the application in a LXC container
    run_yunohost "app install --force '$package_dir' -a '$manifest_args_mod'"

    # yunohost_result gets the return code of the installation
    yunohost_result=$?

    # Print the result of the install command
    if [ $yunohost_result -eq 0 ]; then
        debug "Installation successful."
    else
        error "Installation failed. ($yunohost_result)"
    fi

    # Retrieve the app id in the log. To manage the app after
    ynh_app_id=$(sudo tac "$yunohost_log" | grep --only-matching --max-count=1 "YNH_APP_INSTANCE_NAME=[^ ]*" | cut --delimiter='=' --fields=2)
}

STANDARD_SETUP_APP () {
    # Try to find an existing snapshot for this install, or make an install

    # If it's a root install
    if [ "$check_path" = "/" ]
    then
        # Check if a snapshot already exist for this install
        if [ -z "$root_snapshot" ]
        then
            # Make an installation
            SETUP_APP

            # Create a snapshot for this installation, to be able to reuse it instead of a new installation.
            # But only if this installation has worked fine
            if [ $yunohost_result -eq 0 ]; then
                # Check if a snapshot already exist for a root install
                if [ -z "$root_snapshot" ]
                then
                    debug "Creating a snapshot for root installation."
                    create_temp_backup 2
                    root_snapshot=snap2
                fi
            fi
        else
            # Or uses an existing snapshot
            debug "Reusing an existing snapshot for root installation."
            use_temp_snapshot $root_snapshot
        fi

        # In case of sub path install, use another snapshot
    else
        # Check if a snapshot already exist for this install
        if [ -z "$subpath_snapshot" ]
        then
            # Make an installation
            SETUP_APP

            # Create a snapshot for this installation, to be able to reuse it instead of a new installation.
            # But only if this installation has worked fine
            if [ $yunohost_result -eq 0 ]; then
                # Check if a snapshot already exist for a subpath (or no_url) install
                if [ -z "$subpath_snapshot" ]
                then
                    debug "Creating a snapshot for sub path installation."
                    create_temp_backup 1
                    root_snapshot=snap1
                fi
            fi
        else
            # Or uses an existing snapshot
            debug "Reusing an existing snapshot for sub path installation."
            use_temp_snapshot $subpath_snapshot
        fi
    fi
}

REMOVE_APP () {
    # Remove an application

    # Make a break if auto_remove is set
    break_before_continue

    small_title "Removing the app..."

    # Remove the application from the LXC container
    run_yunohost "app remove '$ynh_app_id'"

    # yunohost_remove gets the return code of the deletion
    yunohost_remove=$?

    # Print the result of the remove command
    if [ "$yunohost_remove" -eq 0 ]; then
        debug "Remove successful."
    else
        error "Remove failed. ($yunohost_remove)"
    fi
}

#=================================================
# Try to access the app by its url
#=================================================

VALIDATE_THAT_APP_CAN_BE_ACCESSED () {

    # Not checking this if this ain't relevant for the current test / app
    if [ $enable_validate_that_app_can_be_accessed == "true" ]
    then
        curl_error=0
        yuno_portal=0
        return
    fi

    small_title "Validating that the app can (or cannot) be accessed with its url..."

    # Force a skipped_uris if public mode is not set
    if [ "$install_type" != "private" ] && [ "$install_type" != "public" ] && [ -z "$public_arg" ]
    then
        warning "Forcing public access using a skipped_uris setting"
        # Add a skipped_uris on / for the app
        run_yunohost "app setting '$ynh_app_id' skipped_uris -v \"/\""
        # Regen the config of sso
        run_yunohost "app ssowatconf"
    fi

    # Inform /etc/hosts with the IP of LXC to resolve the domain.
    # This is set only here and not before to prevent to help the app's scripts
    echo -e "$ip_range.2 $main_domain #package_check\n$ip_range.2 $sub_domain #package_check" | sudo tee --append /etc/hosts > /dev/null

    # Try to resolv the domain during 10 seconds maximum.
    local i=0
    for i in `seq 1 10`; do
        curl --location --insecure $check_domain > /dev/null 2>&1
        # If curl return 6, it's an error "Could not resolve host"
        if [ $? -ne 6 ]; then
            # If not, curl is ready to work.
            break
        fi
        echo -n .
        sleep 1
    done

    # curl_error indicate the result of curl test
    curl_error=0
    # 503 Service Unavailable can would have some time to work.
    local http503=0
    # yuno_portal equal 1 if the test fall on the portal
    yuno_portal=0

    # Try to access to the url in 2 times, with a final / and without
    i=1;
    while [ $i -ne 3 ]
    do

        # First time, try without final /
        if [ $i -eq 1 ]
        then
            # If the last character is /
            if [ "${check_path: -1}" = "/" ]
            then
                # Remove it
                local curl_check_path="${check_path:0:${#check_path}-1}"
            else
                curl_check_path=$check_path
            fi

            # The next loop will try the second test
            i=2
        elif [ $i -eq 2 ]
        then
            # Second time, try with the final /

            # If the last character isn't /
            if [ "${check_path: -1}" != "/" ]
            then
                # Add it
                curl_check_path="$check_path/"
            else
                curl_check_path=$check_path
            fi

            # The next loop will break the while loop
            i=3
        fi

        # Remove the previous curl output
        rm -f "$script_dir/url_output"

        # Call curl to try to access to the url of the app
        curl --location --insecure --silent --show-error --write-out "%{http_code};%{url_effective}\n" $check_domain$curl_check_path --output "$script_dir/url_output" > "$script_dir/curl_print"

        # Analyze the result of curl command
        if [ $? -ne 0 ]
        then
            error "Connection error..."
            curl_error=1
        fi

        # Print informations about the connection
        local http_code=$(cat "$script_dir/curl_print" | cut -d ';' -f1)
        test_url_details="
 Test url: $check_domain$curl_check_path
 Real url: $(cat "$script_dir/curl_print" | cut --delimiter=';' --fields=2)
 HTTP code: $http_code"
        debug "$test_url_details"

        # Analyze the http code
        if [ "${http_code:0:1}" = "0" ] || [ "${http_code:0:1}" = "4" ] || [ "${http_code:0:1}" = "5" ] || [ "${http_code:0:1}" = "6" ]
        then
            # If the http code is a 0xx 4xx or 5xx, it's an error code.
            curl_error=1

            # 401 is "Unauthorized", so is a answer of the server. So, it works!
            test "${http_code}" = "401" && curl_error=0

            # 503 is Service Unavailable, it's a temporary error.
            if [ "${http_code}" = "503" ]
            then
                curl_error=0
                warning "Service temporarily unavailable"
                # 3 successive error are allowed
                http503=$(( http503 + 1 ))
                if [ $http503 -ge 3 ]; then
                    # Over 3, it's definitively an error
                    curl_error=1
                else
                    # Below 3 times, retry.
                    # Decrease the value of 'i' to retry the same test
                    i=$(( i - 1 ))
                    # Wait 1 second to let's some time to the 503 error
                    sleep 1
                    # And retry immediately
                    continue
                fi
            fi

            if [ $curl_error -eq 1 ]; then
                error "The HTTP code shows an error."
            fi
        fi

        # Analyze the output of curl
        if [ -e "$script_dir/url_output" ]
        then
            # Print the title of the page
            local page_title=$(grep "<title>" "$script_dir/url_output" | cut --delimiter='>' --fields=2 | cut --delimiter='<' --fields=1)
            debug "Title of the page: $page_title"

            # Check if the page title is neither the YunoHost portail or default nginx page
            if [ "$page_title" = "YunoHost Portal" ]
            then
                debug "The connection attempt fall on the YunoHost portal."
                yuno_portal=1
            else
                yuno_portal=0
                if [ "$page_title" = "Welcome to nginx on Debian!" ]
                then
                    # Falling on nginx default page is an error.
                    curl_error=1
                    error "The connection attempt fall on nginx default page."
                fi

                # Print the first 20 lines of the page
                debug "Extract of the page:"
                page_extract=$(lynx -dump -force_html "$script_dir/url_output" | head --lines 20 | tee -a "$complete_log")

                if [ $show_resources -eq 1 ]
                then
                    # Get all the resources for the main page of the app.
                    local HTTP_return
                    local moved=0
                    local ignored=0
                    while read HTTP_return
                    do
                        # Ignore robots.txt and ynhpanel.js. They always redirect to the portal.
                        if echo "$HTTP_return" | grep --quiet "$check_domain/robots.txt\|$check_domain/ynhpanel.js"; then
                            debug "Ressource ignored: ${HTTP_return##*http*://}"
                            ignored=1
                        fi

                        # If it's the line with the resource to get
                        if echo "$HTTP_return" | grep --quiet "^--.*--  http"
                        then
                            # Get only the resource itself.
                            local resource=${HTTP_return##*http*://}
                            # Else, if would be the HTTP return code.
                        else
                            # If the return code is different than 200.
                            if ! echo "$HTTP_return" | grep --quiet "200 OK$"
                            then
                                # Skipped the check of ignored ressources.
                                if [ $ignored -eq 1 ]
                                then
                                    ignored=0
                                    continue
                                fi
                                # Isolate the http return code.
                                http_code="${HTTP_return##*awaiting response... }"
                                http_code="${http_code:0:3}"
                                # If the return code is 301 or 302, let's check the redirection.
                                if echo "$HTTP_return" | grep --quiet "30[12] Moved"
                                then
                                    debug "Ressource moved: $resource"
                                    moved=1
                                else
                                    error "Resource unreachable (Code $http_code) $resource"
                                    #curl_error=1
                                    moved=0
                                fi
                            else
                                if [ $moved -eq 1 ]
                                then
                                    if echo "$resource" | grep --quiet "/yunohost/sso/"
                                    then
                                        error "The previous resource is redirected to the YunoHost portal"
                                        #curl_error=1
                                    fi
                                fi
                                moved=0
                            fi
                        fi
                    done <<< "$(cd "$package_path"; LC_ALL=C wget --adjust-extension --page-requisites --no-check-certificate $check_domain$curl_check_path 2>&1 | grep "^--.*--  http\|^HTTP request sent")"
                fi
            fi
        fi
    done

    if [[ $curl_error -ne 0 ]]
    then
        warning "$test_url_details"
        warning "Page title: $page_title"
        warning "Page extract: $page_extract"
    fi

    # Detect the issue alias_traversal, https://github.com/yandex/gixy/blob/master/docs/en/plugins/aliastraversal.md

    # Create a file to get for alias_traversal
    echo "<!DOCTYPE html><html><head>
    <title>alias_traversal test</title>
    </head><body><h1>alias_traversal test</h1>
    If you see this page, you have failed the test for alias_traversal issue.</body></html>" \
        | sudo tee /var/lib/lxc/$lxc_name/rootfs/var/www/html/alias_traversal.html > /dev/null

    curl --location --insecure --silent $check_domain$check_path../html/alias_traversal.html \
        | grep "title" | grep --quiet "alias_traversal test" \
        && error "Issue alias_traversal detected ! Please see here https://github.com/YunoHost/example_ynh/pull/45 to fix that." && RESULT_alias_traversal=1

    # Remove the entries in /etc/hosts for the test domain
    sudo sed --in-place '/#package_check/d' /etc/hosts
}

#=================================================
# Generic functions for unit tests
#=================================================

start_test () {

    title "$1 [Test $current_test_number/$total_number_of_test]"

    # Increment the value of the current test
    current_test_number=$((current_test_number+1))
}

replace_manifest_key () {
    # Replace a generic manifest key by another
    # $1 = Manifest key
    # $2 = Replacement value

    # Build the variable name by concatenate $1 and _arg
    local manifest_key=$(eval echo \$${1}_arg)

    if [ -n "$manifest_key" ]
    then
        manifest_args_mod=$(echo $manifest_args_mod | sed "s@$manifest_key=[^&]*\&@${manifest_key}=${2}\&@")
    fi
}

check_test_result () {

    # Check the result and print SUCCESS or FAIL

    if [ $yunohost_result -eq 0 ] && [ $curl_error -eq 0 ] && [ $yuno_portal -eq 0 ]
    then
        report_test_success
        return 0
    else
        report_test_failed
        return 1
    fi
}

check_test_result_remove () {

    # Check the result of a remove and print SUCCESS or FAIL

    if [ $yunohost_remove -eq 0 ]
    then
        report_test_success
        return 0
    else
        report_test_failed
        return 1
    fi
}

is_install_failed () {
    # Check if an install have previously work

    # If the test for install in sub dir isn't desactivated
    sub_dir_install=0
    if [ $setup_sub_dir -ne 0 ]
    then
        # If a test succeed or if force_install_ok is set
        # Or if $setup_sub_dir isn't set in the check_process
        if [ $RESULT_check_sub_dir -eq 1 ] || [ $force_install_ok -eq 1 ] || [ $setup_sub_dir -eq -1 ]
        then
            # Validate installation in sub dir.
            sub_dir_install=1
        fi
    else
        sub_dir_install=0
    fi

    # If the test for install on root isn't desactivated

    root_install=0
    if [ $setup_root -ne 0 ] || [ $setup_nourl -eq 1 ]
    then
        # If a test succeed or if force_install_ok is set
        # Or if $setup_root isn't set in the check_process
        if [ $RESULT_check_root -eq 1 ] || [ $force_install_ok -eq 1 ] || [ $setup_root -eq -1 ]
        then
            # Validate installation on root.
            root_install=1
        fi
    else
        root_install=0
    fi

    if [ $sub_dir_install -eq 0 ] && [ $root_install -eq 0 ]
    then
        error "All installs failed, therefore this test cannot be performed..."
        return 1
    fi
}

#=================================================
# Unit tests
#=================================================

CHECK_SETUP () {
    # Try to install in a sub path, on root or without url access
    # $1 = install type

    local install_type=$1
    if [ "$install_type" = "subdir" ]; then
        start_test "Installation in a sub path"
    elif [ "$install_type" = "root" ]; then
        start_test "Installation on the root"
    else
        start_test "Installation without url access"
    fi

    # Copy original arguments
    local manifest_args_mod="$manifest_arguments"

    # Replace manifest key for the test
    check_domain=$sub_domain
    replace_manifest_key "domain" "$check_domain"
    if [ "$install_type" = "subdir" ]; then
        local check_path=$test_path
    elif [ "$install_type" = "root" ]; then
        local check_path=/
    fi
    replace_manifest_key "path" "$check_path"
    replace_manifest_key "user" "$test_user"
    replace_manifest_key "public" "$public_public_arg"

    # Install the application in a LXC container
    SETUP_APP

    # Try to access the app by its url
    VALIDATE_THAT_APP_CAN_BE_ACCESSED

    # Check the result and print SUCCESS or FAIL
    if check_test_result
    then	# Success
        RESULT_global_setup=1	# Installation succeed
        local check_result_setup=1	# Installation succeed
    else	# Fail
        # The global success for a installation can't be failed if another installation succeed
        if [ $RESULT_global_setup -ne 1 ]; then
            RESULT_global_setup=-1	# Installation failed
        fi
        local check_result_setup=-1	# Installation failed
    fi

    # Create a snapshot for this installation, to be able to reuse it instead of a new installation.
    # But only if this installation has worked fine
    if [ $check_result_setup -eq 1 ]; then
        if [ "$check_path" = "/" ]
        then
            # Check if a snapshot already exist for a root install
            if [ -z "$root_snapshot" ]
            then
                debug "Create a snapshot for root installation."
                create_temp_backup 2
                root_snapshot=snap2
            fi
        else
            # Check if a snapshot already exist for a subpath (or no_url) install
            if [ -z "$subpath_snapshot" ]
            then
                # Then create a snapshot
                debug "Create a snapshot for sub path installation."
                create_temp_backup 1
                subpath_snapshot=snap1
            fi
        fi
    fi

    # Remove the application
    REMOVE_APP

    # Check the result and print SUCCESS or FAIL
    if check_test_result_remove
    then	# Success
        local check_result_remove=1	# Remove in sub path succeed
        RESULT_global_remove=1	# Remove succeed
    else	# Fail
        # The global success for a deletion can't be failed if another remove succeed
        if [ $RESULT_global_remove -ne 1 ];
        then
            RESULT_global_remove=-1	# Remove failed
        fi
        local check_result_remove=-1	# Remove in sub path failed
    fi

    # Reinstall the application after the removing
    # Try to resintall only if the first install is a success.
    if [ $check_result_setup -eq 1 ]
    then
        small_title "Reinstall the application after a removing."

        SETUP_APP

        # Try to access the app by its url
        VALIDATE_THAT_APP_CAN_BE_ACCESSED

        # Check the result and print SUCCESS or FAIL
        if check_test_result
        then	# Success
            local check_result_setup=1	# Installation succeed
        else	# Fail
            local check_result_setup=-1	# Installation failed
        fi
    fi

    # Fill the correct variable depend on the type of test
    if [ "$install_type" = "subdir" ]
    then
        RESULT_check_sub_dir=$check_result_setup
        RESULT_check_remove_sub_dir=$check_result_remove
    else	# root and no_url
        RESULT_check_root=$check_result_setup
        RESULT_check_remove_root=$check_result_remove
    fi

    # Make a break if auto_remove is set
    break_before_continue
}

CHECK_UPGRADE () {
    # Try the upgrade script

    # Do an upgrade test for each commit in the upgrade list
    while read <&4 commit
    do
        if [ "$commit" == "current" ]
        then
            start_test "Upgrade from the same version"
        else
            # Get the specific section for this upgrade from the check_process
            extract_section "^; commit=$commit" "^;" "$check_process"
            # Get the name for this upgrade.
            upgrade_name=$(grep "^name=" "$partial_check_process" | cut -d'=' -f2)
            # Or use the commit if there's no name.
            if [ -z "$upgrade_name" ]; then
                start_test "Upgrade from the commit $commit"
            else
                start_test "Upgrade from $upgrade_name"
            fi
        fi

        # Check if an install have previously work
        # Abort if none install worked
        is_install_failed || return

        # Copy original arguments
        local manifest_args_mod="$manifest_arguments"

        # Replace manifest key for the test
        check_domain=$sub_domain
        replace_manifest_key "domain" "$check_domain"
        # Use a path according to previous succeeded installs
        if [ $sub_dir_install -eq 1 ]; then
            local check_path=$test_path
        else
            local check_path=/
        fi
        replace_manifest_key "path" "$check_path"
        replace_manifest_key "user" "$test_user"
        replace_manifest_key "public" "$public_public_arg"

        # Install the application in a LXC container
        small_title "Preliminary install..."
        if [ "$commit" == "current" ]
        then
            # If no commit is specified, use the current version.
            STANDARD_SETUP_APP
        else
            # Otherwise, use a specific commit
            # Backup the modified arguments
            update_manifest_args="$manifest_args_mod"
            # Get the arguments of the manifest for this upgrade.
            manifest_args_mod="$(grep "^manifest_arg=" "$partial_check_process" | cut -d'=' -f2-)"
            if [ -z "$manifest_args_mod" ]; then
                # If there's no specific arguments, use the previous one.
                manifest_args_mod="$update_manifest_args"
            else
                # Otherwise, keep the new arguments, and replace the variables.
                manifest_args_mod="${manifest_args_mod//DOMAIN/$check_domain}"
                manifest_args_mod="${manifest_args_mod//PATH/$check_path}"
                manifest_args_mod="${manifest_args_mod//USER/$test_user}"
            fi
            # Make a backup of the directory
            sudo cp -a "$package_path" "${package_path}_back"
            # Change to the specified commit
            (cd "$package_path"; git checkout --force --quiet "$commit")
            # Install the application
            SETUP_APP
            # Then replace the backup
            sudo rm -r "$package_path"
            sudo mv "${package_path}_back" "$package_path"
            # And restore the arguments for the manifest
            manifest_args_mod="$update_manifest_args"
        fi

        # Check if the install had work
        if [ $yunohost_result -ne 0 ]
        then
            error "Installation failed..."
            error "Upgrade test ignored..."
        else
            small_title "Upgrade..."

            # Upgrade the application in a LXC container
            run_yunohost "app upgrade $ynh_app_id -f '$package_dir'"

            # yunohost_result gets the return code of the upgrade
            yunohost_result=$?

            # Print the result of the upgrade command
            if [ $yunohost_result -eq 0 ]; then
                debug "Upgrade successful."
            else
                error "Upgrade failed. ($yunohost_result)"
            fi

            # Try to access the app by its url
            VALIDATE_THAT_APP_CAN_BE_ACCESSED

            # Check the result and print SUCCESS or FAIL
            if check_test_result
            then	# Success
                # The global success for an upgrade can't be a success if another upgrade failed
                if [ $RESULT_check_upgrade -ne -1 ]; then
                    RESULT_check_upgrade=1	# Upgrade succeed
                fi
            else	# Fail
                RESULT_check_upgrade=-1	# Upgrade failed
            fi

            # Remove the application
            REMOVE_APP
        fi

        # Uses the default snapshot
        current_snapshot=snap0
        # Stop and restore the LXC container
        LXC_STOP >> $complete_log
    done 4< "$script_dir/upgrade_list"
}

CHECK_PUBLIC_PRIVATE () {
    # Try to install in public or private mode
    # $1 = install type

    local install_type=$1
    if [ "$install_type" = "private" ]; then
        start_test "Installation in private mode"
    else [ "$install_type" = "public" ]
        start_test "Installation in public mode"
    fi


    # Check if an install have previously work
    is_install_failed || return

    # Copy original arguments
    local manifest_args_mod="$manifest_arguments"

    # Replace manifest key for the test
    check_domain=$sub_domain
    replace_manifest_key "domain" "$check_domain"
    replace_manifest_key "user" "$test_user"
    # Set public or private according to type of test requested
    if [ "$install_type" = "private" ]; then
        replace_manifest_key "public" "$public_private_arg"
    elif [ "$install_type" = "public" ]; then
        replace_manifest_key "public" "$public_public_arg"
    fi

    # Initialize the value
    local check_result_public_private=0

    # Try in 2 times, first in root and second in sub path.
    local i=0
    for i in 0 1
    do
        # First, try with a root install
        if [ $i -eq 0 ]
        then
            # Check if root installation worked
            if [ $root_install -eq 1 ]
            then
                # Replace manifest key for path
                local check_path=/
                replace_manifest_key "path" "$check_path"
            else
                # Jump to the second path if this check cannot be do
                warning "Root install failed, therefore this test cannot be performed..."
                continue
            fi

            # Second, try with a sub path install
        elif [ $i -eq 1 ]
        then
            # Check if sub path installation worked, or if force_install_ok is setted.
            if [ $sub_dir_install -eq 1 ]
            then
                # Replace manifest key for path
                local check_path=$test_path
                replace_manifest_key "path" "$check_path"
            else
                # Jump to the second path if this check cannot be do
                warning "Sub path install failed, therefore this test cannot be performed..."
                return
            fi
        fi

        # Install the application in a LXC container
        SETUP_APP

        # Try to access the app by its url
        VALIDATE_THAT_APP_CAN_BE_ACCESSED

        # Change the result according to the results of the curl test
        if [ "$install_type" = "private" ]
        then
            # In private mode, if curl doesn't fell on the ynh portal, it's a fail.
            if [ $yuno_portal -eq 0 ]; then
                error "App is not private: it should redirect to the Yunohost portal, but is publicly accessible instead"
                yunohost_result=1
            fi
        elif [ "$install_type" = "public" ]
        then
            # In public mode, if curl fell on the ynh portal, it's a fail.
            if [ $yuno_portal -eq 1 ]; then
                error "App page is not public: it should be publicly accessible, but redirects to the Yunohost portal instead"
                yunohost_result=1
            fi
        fi

        # Check the result and print SUCCESS or FAIL
        if [ $yunohost_result -eq 0 ] && [ $curl_error -eq 0 ]
        then	
            report_test_success
            # The global success for public/private mode can't be a success if another installation failed
            if [ $check_result_public_private -ne -1 ]; then
                check_result_public_private=1	# Installation succeed
            fi
        else
            report_test_failed
            check_result_public_private=-1	# Installation failed
        fi

        # Fill the correct variable depend on the type of test
        if [ "$install_type" = "private" ]
        then
            RESULT_check_private=$check_result_public_private
        else	# public
            RESULT_check_public=$check_result_public_private
        fi

        # Make a break if auto_remove is set
        break_before_continue

        # Stop and restore the LXC container
        LXC_STOP >> $complete_log
    done
}

CHECK_MULTI_INSTANCE () {
    # Try multi-instance installations

    start_test "Multi-instance installations"

    # Check if an install have previously work
    is_install_failed || return

    # Copy original arguments
    local manifest_args_mod="$manifest_arguments"

    # Replace manifest key for the test
    if [ $sub_dir_install -eq 1 ]; then
        local check_path=$test_path
    else
        local check_path=/
    fi
    replace_manifest_key "path" "$check_path"

    replace_manifest_key "user" "$test_user"
    replace_manifest_key "public" "$public_public_arg"

    # Install 2 times the same app
    local i=0
    for i in 1 2
    do
        # First installation
        if [ $i -eq 1 ]
        then
            check_domain=$main_domain
            small_title "First installation: path=$check_domain$check_path"
            # Second installation
        elif [ $i -eq 2 ]
        then
            check_domain=$sub_domain
            small_title "Second installation: path=$check_domain$check_path"
        fi

        # Replace path and domain manifest keys for the test
        replace_manifest_key "domain" "$check_domain"

        # Install the application in a LXC container
        SETUP_APP

        # Store the result in the correct variable
        # First installation
        if [ $i -eq 1 ]
        then
            local multi_yunohost_result_1=$yunohost_result
            local ynh_app_id_1=$ynh_app_id
            # Second installation
        elif [ $i -eq 2 ]
        then
            local multi_yunohost_result_2=$yunohost_result
            local ynh_app_id_2=$ynh_app_id
        fi
    done

    # Try to access to the 2 apps by theirs url
    for i in 1 2
    do
        # First app
        if [ $i -eq 1 ]
        then
            check_domain=$main_domain
            ynh_app_id=$ynh_app_id_1
            # Second app
        elif [ $i -eq 2 ]
        then
            check_domain=$sub_domain
            ynh_app_id=$ynh_app_id_2
        fi

        # Try to access the app by its url
        VALIDATE_THAT_APP_CAN_BE_ACCESSED

        # Check the result of curl test
        if [ $curl_error -ne 0 ] || [ $yuno_portal -ne 0 ]
        then
            # The test failed if curl fell on ynh portal or had an error.
            # First app
            if [ $i -eq 1 ]
            then
                multi_yunohost_result_1=1
                # Second app
            elif [ $i -eq 2 ]
            then
                multi_yunohost_result_2=1
            fi
        fi
    done

    # Check the result and print SUCCESS or FAIL
    # Succeed if the 2 installations work;
    if [ $multi_yunohost_result_1 -eq 0 ] && [ $multi_yunohost_result_2 -eq 0 ]
    then	# Success
        report_test_success
        RESULT_check_multi_instance=1
    else	# Fail
        report_test_failed
        RESULT_check_multi_instance=-1
    fi

    # Make a break if auto_remove is set
    break_before_continue
}

CHECK_COMMON_ERROR () {
    # Try to install with specific complications
    # $1 = install type

    local install_type=$1
    if [ "$install_type" = "port_already_use" ]
        start_test "Port already used"
    fi

    # Check if an install have previously work
    is_install_failed || return

    # Copy original arguments
    local manifest_args_mod="$manifest_arguments"

    # Replace manifest key for the test
    check_domain=$sub_domain
    replace_manifest_key "domain" "$check_domain"
    replace_manifest_key "user" "$test_user"
    replace_manifest_key "public" "$public_public_arg"

    # Replace path manifest key for the test
    if [ "$install_type" = "port_already_use" ]
        # Use a path according to previous succeeded installs
        if [ $sub_dir_install -eq 1 ]; then
            local check_path=$test_path
        else
            local check_path=/
        fi
        replace_manifest_key "path" "$check_path"
    fi

    # Open the specified port to force the script to find another
    if [ "$install_type" = "port_already_use" ]
    then

        # If the first character is a #, that means it this port number is not in the manifest
        if [ "${port_arg:0:1}" = "#" ]
        then
            # Retrieve the port number
            local check_port="${port_arg:1}"

            # Else, the port number is in the manifest. So the port number is set at a fixed value.
        else
            local check_port=6660
            # Replace port manifest key for the test
            replace_manifest_key "port" "$check_port"
        fi

        # Build a service with netcat for use this port before the app.
        echo -e "[Service]\nExecStart=/bin/netcat -l -k -p $check_port\n
        [Install]\nWantedBy=multi-user.target" | \
            sudo tee "/var/lib/lxc/$lxc_name/rootfs/etc/systemd/system/netcat.service" \
            > /dev/null

        # Then start this service to block this port.
        LXC_START "sudo systemctl enable netcat & sudo systemctl start netcat"
    fi

    # Install the application in a LXC container
    SETUP_APP

    # Try to access the app by its url
    VALIDATE_THAT_APP_CAN_BE_ACCESSED

    # Check the result and print SUCCESS or FAIL
    if check_test_result
    then	# Success
        local check_result_setup=1
    else	# Fail
        local check_result_setup=-1
    fi

    # Fill the correct variable depend on the type of test
    if [ "$install_type" = "port_already_use" ]; then
        RESULT_check_port=$check_result_setup
    fi

    # Make a break if auto_remove is set
    break_before_continue
}

CHECK_BACKUP_RESTORE () {
    # Try to backup then restore the app

    start_test "Backup/Restore"

    # Check if an install have previously work
    is_install_failed || return

    # Copy original arguments
    local manifest_args_mod="$manifest_arguments"

    # Replace manifest key for the test
    check_domain=$sub_domain
    replace_manifest_key "domain" "$check_domain"
    replace_manifest_key "user" "$test_user"
    replace_manifest_key "public" "$public_public_arg"

    # Try in 2 times, first in root and second in sub path.
    local i=0
    for i in 0 1
    do
        # First, try with a root install
        if [ $i -eq 0 ]
        then
            # Check if root installation worked, or if force_install_ok is setted.
            if [ $root_install -eq 1 ]
            then
                # Replace manifest key for path
                local check_path=/
                replace_manifest_key "path" "$check_path"
                small_title "Preliminary installation on the root..."
            else
                # Jump to the second path if this check cannot be do
                warning "Root install failed, therefore this test cannot be performed..."
                continue
            fi

            # Second, try with a sub path install
        elif [ $i -eq 1 ]
        then
            # Check if sub path installation worked, or if force_install_ok is setted.
            if [ $sub_dir_install -eq 1 ]
            then
                # Replace manifest key for path
                local check_path=$test_path
                replace_manifest_key "path" "$check_path"
                small_title "Preliminary installation in a sub path..." "white" "bold" clog
            else
                # Jump to the second path if this check cannot be do
                warning "Sub path install failed, therefore this test cannot be performed..."
                return
            fi
        fi

        # Install the application in a LXC container
        STANDARD_SETUP_APP

        # Remove the previous residual backups
        sudo rm -rf /var/lib/lxc/$lxc_name/rootfs/home/yunohost.backup/archives
        sudo rm -rf /var/lib/lxcsnaps/$lxc_name/$current_snapshot/rootfs/home/yunohost.backup/archives

        # BACKUP
        # Made a backup if the installation succeed
        if [ $yunohost_result -ne 0 ]
        then
            error "Installation failed..."
        else
            small_title "Backup of the application..."

            # Made a backup of the application
            run_yunohost "backup create -n Backup_test --apps $ynh_app_id --system $backup_hooks"

            # yunohost_result gets the return code of the backup
            yunohost_result=$?

            # Print the result of the backup command
            if [ $yunohost_result -eq 0 ]; then
                debug "Backup successful"
            else
                error "Backup failed. ($yunohost_result)"
            fi
        fi

        # Check the result and print SUCCESS or FAIL
        if [ $yunohost_result -eq 0 ]
        then	# Success
            report_test_success
            # The global success for a backup can't be a success if another backup failed
            if [ $RESULT_check_backup -ne -1 ]; then
                RESULT_check_backup=1	# Backup succeed
            fi
        else	# Fail
            report_test_failed
            RESULT_check_backup=-1	# Backup failed
        fi

        # Grab the backup archive into the LXC container, and keep a copy
        sudo cp -a /var/lib/lxc/$lxc_name/rootfs/home/yunohost.backup/archives ./

        # RESTORE
        # Try the restore process in 2 times, first after removing the app, second after a restore of the container.
        local j=0
        for j in 0 1
        do
            # First, simply remove the application
            if [ $j -eq 0 ]
            then
                # Remove the application
                REMOVE_APP

                small_title "Restore after removing the application..."

                # Second, restore the whole container to remove completely the application
            elif [ $j -eq 1 ]
            then
                # Uses the default snapshot
                current_snapshot=snap0

                # Remove the previous residual backups
                sudo rm -rf /var/lib/lxcsnaps/$lxc_name/$current_snapshot/rootfs/home/yunohost.backup/archives

                # Place the copy of the backup archive in the container.
                sudo mv -f ./archives /var/lib/lxcsnaps/$lxc_name/$current_snapshot/rootfs/home/yunohost.backup/

                # Stop and restore the LXC container
                LXC_STOP >> $complete_log

                small_title "Restore on a clean YunoHost system..."
            fi

            # Restore the application from the previous backup
            run_yunohost "backup restore Backup_test --force --apps $ynh_app_id"

            # yunohost_result gets the return code of the restore
            yunohost_result=$?

            # Print the result of the backup command
            if [ $yunohost_result -eq 0 ]; then
                debug "Restore successful."
            else
                error "Restore failed. ($yunohost_result)"
            fi

            # Try to access the app by its url
            VALIDATE_THAT_APP_CAN_BE_ACCESSED

            # Check the result and print SUCCESS or FAIL
            if check_test_result
            then	# Success
                # The global success for a restore can't be a success if another restore failed
                if [ $RESULT_check_restore -ne -1 ]; then
                    RESULT_check_restore=1	# Restore succeed
                fi
            else	# Fail
                RESULT_check_restore=-1	# Restore failed
            fi

            # Make a break if auto_remove is set
            break_before_continue

            # Stop and restore the LXC container
            LXC_STOP >> $complete_log
        done
    done
}

CHECK_CHANGE_URL () {
    # Try the change_url script

    start_test "Change URL"

    # Check if an install have previously work
    is_install_failed || return

    # Copy original arguments
    local manifest_args_mod="$manifest_arguments"

    # Replace manifest key for the test
    check_domain=$sub_domain
    replace_manifest_key "domain" "$check_domain"
    replace_manifest_key "user" "$test_user"
    replace_manifest_key "public" "$public_public_arg"

    # Try in 6 times !
    # Without modify the domain, root to path, path to path and path to root.
    # And then, same with a domain change
    local i=0
    for i in `seq 1 7`
    do
        if [ $i -eq 1 ]; then
            # Same domain, root to path
            check_path=/
            local new_path=$test_path
            local new_domain=$sub_domain
        elif [ $i -eq 2 ]; then
            # Same domain, path to path
            check_path=$test_path
            local new_path=${test_path}_2
            local new_domain=$sub_domain
        elif [ $i -eq 3 ]; then
            # Same domain, path to root
            check_path=$test_path
            local new_path=/
            local new_domain=$sub_domain

        elif [ $i -eq 4 ]; then
            # Other domain, root to path
            check_path=/
            local new_path=$test_path
            local new_domain=$main_domain
        elif [ $i -eq 5 ]; then
            # Other domain, path to path
            check_path=$test_path
            local new_path=${test_path}_2
            local new_domain=$main_domain
        elif [ $i -eq 6 ]; then
            # Other domain, path to root
            check_path=$test_path
            local new_path=/
            local new_domain=$main_domain
        elif [ $i -eq 7 ]; then
            # Other domain, root to root
            check_path=/
            local new_path=/
            local new_domain=$main_domain
        fi
        replace_manifest_key "path" "$check_path"

        # Ignore the test if it tries to move to the same address
        if [ "$check_path" == "$new_path" ] && [ "$new_domain" == "$sub_domain" ]; then
            continue
        fi

        # Check if root or subpath installation worked, or if force_install_ok is setted.
        # Try with a sub path install
        if [ "$check_path" = "/" ]
        then
            if [ $root_install -eq 0 ]
            then
                # Skip this test
                warning "Root install failed, therefore this test cannot be performed..."
                continue
            elif [ "$new_path" != "/" ] && [ $sub_dir_install -eq 0 ]
            then
                # Skip this test
                warning "Sub path install failed, therefore this test cannot be performed..."
                continue
            fi
            # And with a sub path install
        else
            if [ $sub_dir_install -eq 0 ]
            then
                # Skip this test
                warning "Sub path install failed, therefore this test cannot be performed..."
                continue
            elif [ "$new_path" = "/" ] && [ $root_install -eq 0 ]
            then
                # Skip this test
                warning "Root install failed, therefore this test cannot be performed..."
                continue
            fi
        fi

        # Install the application in a LXC container
        small_title "Preliminary install..."
        STANDARD_SETUP_APP

        # Check if the install had work
        if [ $yunohost_result -ne 0 ]
        then
            error "Installation failed..."
        else
            small_title "Change the url from $sub_domain$check_path to $new_domain$new_path..."

            # Change the url
            run_yunohost "app change-url $ynh_app_id -d '$new_domain' -p '$new_path'"

            # yunohost_result gets the return code of the change-url script
            yunohost_result=$?

            # Print the result of the change_url command
            if [ $yunohost_result -eq 0 ]; then
                debug "Change_url script successful"
            else
                error "Change_url script failed. ($yunohost_result)"
            fi

            # Try to access the app by its url
            check_path=$new_path
            check_domain=$new_domain
            VALIDATE_THAT_APP_CAN_BE_ACCESSED
        fi

        # Check the result and print SUCCESS or FAIL
        if check_test_result
        then	# Success
            # The global success for a change_url can't be a success if another change_url failed
            if [ $RESULT_change_url -ne -1 ]; then
                RESULT_change_url=1	# Change_url succeed
            fi
        else	# Fail
            RESULT_change_url=-1	# Change_url failed
        fi

        # Make a break if auto_remove is set
        break_before_continue

        # Uses the default snapshot
        current_snapshot=snap0
        # Stop and restore the LXC container
        LXC_STOP >> $complete_log
    done
}

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

ACTIONS_CONFIG_PANEL () {
    # Try the actions and config-panel features

    test_type=$1
    if [ "$test_type" == "actions" ]
    then
        start_test "Actions"

        toml_file="$package_path/actions.toml"
        if [ ! -e "$toml_file" ]
        then
            error "No actions.toml found !"
            return 1
        fi

    elif [ "$test_type" == "config_panel" ]
    then
        start_test "Config-panel"

        toml_file="$package_path/config_panel.toml"
        if [ ! -e "$toml_file" ]
        then
            error "No config_panel.toml found !"
            return 1
        fi
    fi

    # Check if an install have previously work
    is_install_failed || return

    # Copy original arguments
    local manifest_args_mod="$manifest_arguments"

    # Replace manifest key for the test
    check_domain=$sub_domain
    replace_manifest_key "domain" "$check_domain"
    replace_manifest_key "user" "$test_user"
    replace_manifest_key "public" "$public_public_arg"
    # Use a path according to previous succeeded installs
    if [ $sub_dir_install -eq 1 ]; then
        local check_path=$test_path
    else
        local check_path=/
    fi
    replace_manifest_key "path" "$check_path"

    # Install the application in a LXC container
    small_title "Preliminary install..."
    STANDARD_SETUP_APP

    validate_action_config_panel()
    {
        # yunohost_result gets the return code of the command
        yunohost_result=$?

        local message="$1"

        # Print the result of the command
        if [ $yunohost_result -eq 0 ]; then
            debug "$message succeed."
        else
            error "$message failed. ($yunohost_result)"
        fi

        # Check the result and print SUCCESS or FAIL
        if check_test_result
        then	# Success
            # The global success for a actions can't be a success if another iteration failed
            if [ $RESULT_action_config_panel -ne -1 ]; then
                RESULT_action_config_panel=1	# Actions succeed
            fi
        else	# Fail
            RESULT_action_config_panel=-1	# Actions failed
        fi

        # Make a break if auto_remove is set
        break_before_continue
    }

    # List first, then execute
    local i=0
    for i in `seq 1 2`
    do
        # Do a test if the installation succeed
        if [ $yunohost_result -ne 0 ]
        then
            error "The previous test has failed..."
            continue
        fi

        if [ $i -eq 1 ]
        then
            if [ "$test_type" == "actions" ]
            then
                info "> List the available actions..."

                # List the actions
                run_yunohost "app action list $ynh_app_id"

                validate_action_config_panel "yunohost app action list"
            elif [ "$test_type" == "config_panel" ]
            then
                info "> Show the config panel..."

                # Show the config-panel
                run_yunohost "app config show-panel $ynh_app_id"
                validate_action_config_panel "yunohost app config show-panel"
            fi
        elif [ $i -eq 2 ]
        then
            local parts
            if [ "$test_type" == "actions" ]
            then
                info "> Execute the actions..."

                # Split the actions.toml file to separate each actions
                splitterAA "^[[:blank:]]*\[[^.]*\]" "$toml_file"
            elif [ "$test_type" == "config_panel" ]
            then
                info "> Apply configurations..."

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
                        local check_process_arguments="$config_panel_arguments"
                    elif [ "$test_type" == "actions" ]
                    then
                        local check_process_arguments="$actions_arguments"
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
                for j in `seq 1 $nb_actions_config_arguments_specifics`
                do
                    local action_config_argument_built=""
                    if [ $action_config_has_arguments -eq 1 ]
                    then
                        # If there's values into the check_process
                        if [ -n "$actions_config_arguments_specifics" ]
                        then
                            # Build the argument from a value from the check_process
                            local action_config_actual_argument="$(echo "$actions_config_arguments_specifics" | cut -d'|' -f $j)"
                            action_config_argument_built="--args $action_config_argument_name=\"$action_config_actual_argument\""
                        elif [ -n "$action_config_argument_default" ]
                        then
                            # Build the argument from the default value
                            local action_config_actual_argument="$action_config_argument_default"
                            action_config_argument_built="--args $action_config_argument_name=\"$action_config_actual_argument\""
                        else
                            warning "> No argument into the check_process to use or default argument for \"$action_config_name\"..."
                            action_config_actual_argument=""
                        fi

                        if [ "$test_type" == "config_panel" ]
                        then
                            info "> Apply the configuration for \"$action_config_name\" with the argument \"$action_config_actual_argument\"..."
                        elif [ "$test_type" == "actions" ]
                        then
                            info "> Execute the action \"$action_config_name\" with the argument \"$action_config_actual_argument\"..."
                        fi
                    else
                        info "> Execute the action \"$action_config_name\"..."
                    fi

                    if [ "$test_type" == "config_panel" ]
                    then
                        # Aply a configuration
                        run_yunohost "app config apply $ynh_app_id $action_config_action $action_config_argument_built"
                    elif [ "$test_type" == "actions" ]
                    then
                        # Execute an action
                        run_yunohost "app action run $ynh_app_id $action_config_action $action_config_argument_built"
                    fi
                    validate_action_config_panel "yunohost action $action_config_action"
                done
            done
        fi
    done

    # Uses the default snapshot
    current_snapshot=snap0
    # Stop and restore the LXC container
    LXC_STOP >> $complete_log
}

PACKAGE_LINTER () {
    # Package linter

    start_test "Package linter"

    # Execute package linter and linter_result gets the return code of the package linter
    "$script_dir/package_linter/package_linter.py" "$package_path" > "$script_dir/temp_linter_result.log"
    "$script_dir/package_linter/package_linter.py" "$package_path" --json > "$script_dir/temp_linter_result.json"

    # Print the results of package linter and copy these result in the complete log
    cat "$script_dir/temp_linter_result.log" | tee --append "$complete_log"
    cat "$script_dir/temp_linter_result.json" >> "$complete_log"

    RESULT_linter_broken=0
    RESULT_linter_level_6=0
    RESULT_linter_level_7=0
    RESULT_linter_level_8=0

    # Check we qualify for level 6, 7, 8
    # Linter will have a warning called "app_in_github_org" if app ain't in the
    # yunohost-apps org...
    if ! cat "$script_dir/temp_linter_result.json" | jq ".warning" | grep -q "app_in_github_org"
    then
        RESULT_linter_level_6=1
    fi
    if cat "$script_dir/temp_linter_result.json" | jq ".success" | grep -q "qualify_for_level_7"
    then
        RESULT_linter_level_7=1
    fi
    if cat "$script_dir/temp_linter_result.json" | jq ".success" | grep -q "qualify_for_level_8"
    then
        RESULT_linter_level_8=1
    fi

    # If there are any critical errors, we'll force level 0
    if [[ -n "$(cat "$script_dir/temp_linter_result.json" | jq ".critical" | grep -v '\[\]')" ]]
    then
        report_test_failed
        RESULT_linter_broken=1
        RESULT_linter=-1
        # If there are any regular errors, we'll cap to 4
    elif [[ -n "$(cat "$script_dir/temp_linter_result.json" | jq ".error" | grep -v '\[\]')" ]]
    then
        report_test_failed
        RESULT_linter=-1
        # Otherwise, test pass (we'll display a warning depending on if there are
        # any remaning warnings or not)
    else
        if [[ -n "$(cat "$script_dir/temp_linter_result.json" | jq ".warning" | grep -v '\[\]')" ]]
        then
            report_test_warning
        else
            report_test_success
        fi
        RESULT_linter=1
    fi
}

TEST_LAUNCHER () {
    # Abstract for test execution.
    # $1 = Name of the function to execute
    # $2 = Argument for the function

    # Intialize values
    yunohost_result=-1
    yunohost_remove=-1
    false_positive_error=0
    max_false_positive_error_loop=3

    for false_positive_error_loop in $( seq 1 $max_false_positive_error_loop )
    do
        # Start the timer for this test
        start_timer
        # And keep this value separately
        local global_start_timer=$starttime

        # Execute the test
        $1 $2

        if [ $false_positive_error -eq 1 ]
        then
            error "This test was aborted because of a $false_positive_error_cond error."
            if [ $false_positive_error_loop -lt $max_false_positive_error_loop ]
            then
                warning "The test will restart."
                current_test_number=$((current_test_number-1))
            fi
        fi

        # Uses the default snapshot
        current_snapshot=snap0

        # Stop and restore the LXC container
        LXC_STOP >> $complete_log

        # Restore the started time for the timer
        starttime=$global_start_timer
        # End the timer for the test
        stop_timer 2

        # Update the lock file with the date of the last finished test.
        # $$ is the PID of package_check itself.
        echo "$1 $2:$(date +%s):$$" > "$lock_file"

        # Exit the loop if there's no temporary errors detected.
        if [ $false_positive_error -eq 0 ]
        then
            break
        fi
    done
}

set_witness_files () {
    # Create files to check if the remove script does not remove them accidentally
    echo "Create witness files..." >> "$complete_log"

    lxc_dir="/var/lib/lxc/$lxc_name/rootfs"

    create_witness_file () {
        [ "$2" = "file" ] && local action="touch" || local action="mkdir -p"
        sudo $action "${lxc_dir}${1}"
    }

    # Nginx conf
    create_witness_file "/etc/nginx/conf.d/$main_domain.d/witnessfile.conf" file
    create_witness_file "/etc/nginx/conf.d/$sub_domain.d/witnessfile.conf" file

    # /etc
    create_witness_file "/etc/witnessfile" file

    # /opt directory
    create_witness_file "/opt/witnessdir" directory

    # /var/www directory
    create_witness_file "/var/www/witnessdir" directory

    # /home/yunohost.app/
    create_witness_file "/home/yunohost.app/witnessdir" directory

    # /var/log
    create_witness_file "/var/log/witnessfile" file

    # Config fpm
    if [ -d "${lxc_dir}/etc/php5/fpm" ]; then
        create_witness_file "/etc/php5/fpm/pool.d/witnessfile.conf" file
    fi
    if [ -d "${lxc_dir}/etc/php/7.0/fpm" ]; then
        create_witness_file "/etc/php/7.0/fpm/pool.d/witnessfile.conf" file
    fi
    if [ -d "${lxc_dir}/etc/php/7.3/fpm" ]; then
        create_witness_file "/etc/php/7.3/fpm/pool.d/witnessfile.conf" file
    fi

    # Config logrotate
    create_witness_file "/etc/logrotate.d/witnessfile" file

    # Config systemd
    create_witness_file "/etc/systemd/system/witnessfile.service" file

    # Database
    sudo lxc-attach --name=$lxc_name -- mysqladmin --user=root --password=$(sudo cat "$lxc_dir/etc/yunohost/mysql") --wait status > /dev/null 2>&1
    sudo lxc-attach --name=$lxc_name -- mysql --user=root --password=$(sudo cat "$lxc_dir/etc/yunohost/mysql") --wait --execute="CREATE DATABASE witnessdb" > /dev/null 2>&1
}

check_witness_files () {
    # Check all the witness files, to verify if them still here

    lxc_dir="/var/lib/lxc/$lxc_name/rootfs"

    check_file_exist () {
        if sudo test ! -e "${lxc_dir}${1}"
        then
            error "The file $1 is missing ! Something gone wrong !"
            RESULT_witness=1
        fi
    }

    # Nginx conf
    check_file_exist "/etc/nginx/conf.d/$main_domain.d/witnessfile.conf"
    check_file_exist "/etc/nginx/conf.d/$sub_domain.d/witnessfile.conf"

    # /etc
    check_file_exist "/etc/witnessfile"

    # /opt directory
    check_file_exist "/opt/witnessdir"

    # /var/www directory
    check_file_exist "/var/www/witnessdir"

    # /home/yunohost.app/
    check_file_exist "/home/yunohost.app/witnessdir"

    # /var/log
    check_file_exist "/var/log/witnessfile"

    # Config fpm
    if [ -d "${lxc_dir}/etc/php5/fpm" ]; then
        check_file_exist "/etc/php5/fpm/pool.d/witnessfile.conf" file
    fi
    if [ -d "${lxc_dir}/etc/php/7.0/fpm" ]; then
        check_file_exist "/etc/php/7.0/fpm/pool.d/witnessfile.conf" file
    fi
    if [ -d "${lxc_dir}/etc/php/7.3/fpm" ]; then
        check_file_exist "/etc/php/7.3/fpm/pool.d/witnessfile.conf" file
    fi

    # Config logrotate
    check_file_exist "/etc/logrotate.d/witnessfile"

    # Config systemd
    check_file_exist "/etc/systemd/system/witnessfile.service"

    # Database
    if ! sudo lxc-attach --name=$lxc_name -- mysqlshow --user=root --password=$(sudo cat "$lxc_dir/etc/yunohost/mysql") | grep --quiet '^| witnessdb' > /dev/null 2>&1
    then
        error "The database witnessdb is missing ! Something gone wrong !"
        RESULT_witness=1
    fi
    if [ $RESULT_witness -eq 1 ]
    then
        yunohost_result=1
        yunohost_remove=1
    fi
}

TESTING_PROCESS () {
    # Launch all tests successively

    title "Tests serie: ${tests_serie#;; }"

    # Be sure that the container is running
    LXC_START "true"

    PRINT_YUNOHOST_VERSION

    # Init the value for the current test
    current_test_number=1

    # We will chech that the app can be accessed
    # (except if it's a no-url app)
    [ $setup_nourl      -eq 0 ] \
        && enable_validate_that_app_can_be_accessed="true" \
        ||enable_validate_that_app_can_be_accessed="false"

    # Check the package with package linter
    [ $pkg_linter       -eq 1 ] && PACKAGE_LINTER

    # Try to install in a sub path
    [ $setup_sub_dir    -eq 1 ] && TEST_LAUNCHER CHECK_SETUP subdir

    # Try to install on root
    [ $setup_root       -eq 1 ] && TEST_LAUNCHER CHECK_SETUP root

    # Try to install without url access
    [ $setup_nourl      -eq 1 ] && TEST_LAUNCHER CHECK_SETUP no_url

    # Try the upgrade script
    [ $upgrade          -eq 1 ] && TEST_LAUNCHER CHECK_UPGRADE

    # Try to install in private mode
    [ $setup_private    -eq 1 ] && TEST_LAUNCHER CHECK_PUBLIC_PRIVATE private

    # Try to install in public mode
    [ $setup_public     -eq 1 ] && TEST_LAUNCHER CHECK_PUBLIC_PRIVATE public

    # Try multi-instance installations
    [ $multi_instance   -eq 1 ] && TEST_LAUNCHER CHECK_MULTI_INSTANCE

    # Try to install with a port already used
    [ $port_already_use -eq 1 ] && TEST_LAUNCHER CHECK_COMMON_ERROR port_already_use

    # Try to backup then restore the app
    [ $backup_restore   -eq 1 ] && TEST_LAUNCHER CHECK_BACKUP_RESTORE

    # Try the change_url script
    [ $change_url       -eq 1 ] && TEST_LAUNCHER CHECK_CHANGE_URL

    # Try the actions
    [ $actions          -eq 1 ] && TEST_LAUNCHER ACTIONS_CONFIG_PANEL actions

    # Try the config-panel
    [ $config_panel     -eq 1 ] && TEST_LAUNCHER ACTIONS_CONFIG_PANEL config_panel
}
