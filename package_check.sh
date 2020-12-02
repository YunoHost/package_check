#!/bin/bash

#=================================================
# Grab the script directory
#=================================================

if [ "${0:0:1}" == "/" ]; then script_dir="$(dirname "$0")"; else script_dir="$(echo $PWD/$(dirname "$0" | cut -d '.' -f2) | sed 's@/$@@')"; fi

#=================================================
# Starting and checking
#=================================================
# Generic functions
#=================================================

clean_exit () {
    # Exit and remove all temp files
    # $1 = exit code

    # Deactivate LXC network
    LXC_TURNOFF

    # Remove temporary files
    rm -f "$script_dir/url_output"
    rm -f "$script_dir/curl_print"
    rm -f "$script_dir/manifest_extract"

    # Remove the application which been tested
    if [ -n "$package_path" ]; then
        rm -rf "$package_path"
    fi

    # Remove the lock file
    rm -f "$lock_file"

    exit $1
}

#=================================================
# Check and read CLI arguments
#=================================================

echo ""

# Init arguments value
gitbranch=""
force_install_ok=0
interrupt=0
notice=0
build_lxc=0
bash_mode=0
show_resources=0

# If no arguments provided
if [ "$#" -eq 0 ]
then
    # Print the help and exit
    notice=1
else
    # Store arguments in a array to keep each argument separated
    arguments=("$@")
    getopts_built_arg=()

    # Read the array value per value
    for i in `seq 0 $(( ${#arguments[@]} -1 ))`
    do
        if [[ "${arguments[$i]}" =~ "--branch=" ]]
        then
            getopts_built_arg+=(-b)
            arguments[$i]=${arguments[$i]//--branch=/}
        fi
        # For each argument in the array, reduce to short argument for getopts
        arguments[$i]=${arguments[$i]//--force-install-ok/-f}
        arguments[$i]=${arguments[$i]//--interrupt/-i}
        arguments[$i]=${arguments[$i]//--help/-h}
        arguments[$i]=${arguments[$i]//--build-lxc/-l}
        arguments[$i]=${arguments[$i]//--bash-mode/-y}
        arguments[$i]=${arguments[$i]//--show-resources/-r}
        getopts_built_arg+=("${arguments[$i]}")
    done

    # Read and parse all the arguments
    # Use a function here, to use standart arguments $@ and be able to use shift.
    parse_arg () {
        while [ $# -ne 0 ]
        do
            # If the paramater begins by -, treat it with getopts
            if [ "${1:0:1}" == "-" ]
            then
                # Initialize the index of getopts
                OPTIND=1
                # Parse with getopts only if the argument begin by -
                getopts ":b:fihlyr" parameter || true
                case $parameter in
                    b)
                        # --branch=branch-name
                        gitbranch="-b $OPTARG"
                        shift_value=2
                        ;;
                    f)
                        # --force-install-ok
                        force_install_ok=1
                        shift_value=1
                        ;;
                    i)
                        # --interrupt
                        interrupt=1
                        shift_value=1
                        ;;
                    h)
                        # --help
                        notice=1
                        shift_value=1
                        ;;
                    l)
                        # --build-lxc
                        build_lxc=1
                        shift_value=1
                        ;;
                    y)
                        # --bash-mode
                        bash_mode=1
                        shift_value=1
                        ;;
                    r)
                        # --show-resources
                        show_resources=1
                        shift_value=1
                        ;;
                    \?)
                        echo "Invalid argument: -${OPTARG:-}"
                        notice=1
                        shift_value=1
                        ;;
                    :)
                        echo "-$OPTARG parameter requires an argument."
                        notice=1
                        shift_value=1
                        ;;
                esac
                # Otherwise, it's not an option, it's an operand
            else
                app_arg="$1"
                shift_value=1
            fi
            # Shift the parameter and its argument
            shift $shift_value
        done
    }

    # Call parse_arg and pass the modified list of args as a array of arguments.
    parse_arg "${getopts_built_arg[@]}"
fi

# Prevent a conflict between --interrupt and --bash-mode
if [ $interrupt -eq 1 ] && [ $bash_mode -eq 1 ]
then
    echo "You can't use --interrupt and --bash-mode together !"
    notice=1
fi

# Print help
if [ $notice -eq 1 ]
then
    cat << EOF

Usage:
package_check.sh [OPTION]... PACKAGE_TO_CHECK
    -b, --branch=BRANCH
        Specify a branch to check.
    -f, --force-install-ok
        Force remaining tests even if installation tests failed or were not selected for execution.
    -i, --interrupt
        Force auto_remove value, break before each remove.
    -h, --help
        Display this notice.
    -l, --build-lxc
        Install LXC and build the container if necessary.
    -y, --bash-mode
Do not ask for continue check. Ignore auto_remove.
    -r, --show-resources
        Show the unavailable resources when accessing the url.
EOF
exit 0
fi

#=================================================
# Check if the lock file exist
#=================================================

lock_file="$script_dir/pcheck.lock"

if test -e "$lock_file"
then
    # If the lock file exist
    echo "The lock file $lock_file is present. Package check would not continue."
    if [ $bash_mode -ne 1 ]; then
        echo -n "Do you want to continue anyway? (y/n) :"
        read answer
    fi
    # Set the answer at lowercase only
    answer=${answer,,}
    if [ "${answer:0:1}" != "y" ]
    then
        echo "Cancel Package check execution"
        exit 0
    fi
fi
# Create the lock file
# $$ is the PID of package_check itself.
echo "start:$(date +%s):$$" > "$lock_file"

#=================================================
# Check the internet connectivity
#=================================================

# Try to ping yunohost.org
ping -q -c 2 yunohost.org > /dev/null 2>&1
if [ "$?" -ne 0 ]; then
    # If fail, try to ping another domain
    ping -q -c 2 framasoft.org > /dev/null 2>&1
    if [ "$?" -ne 0 ]; then
        # If ping failed twice, it's seems the internet connection is down.
        echo "\e[91mUnable to connect to internet.\e[0m"

        # Remove the lock file
        rm -f "$lock_file"
        # And exit
        exit 1
    fi
fi

#=================================================
# Upgrade Package check
#=================================================

git_repository=https://github.com/YunoHost/package_check
version_file="$script_dir/pcheck_version"

check_version="$(git ls-remote $git_repository | cut -f 1 | head -n1)"

# If the version file exist, check for an upgrade
if [ -e "$version_file" ]
then
    # Check if the last commit on the repository match with the current version
    if [ "$check_version" != "$(cat "$version_file")" ]
    then
        # If the versions don't matches. Do an upgrade
        echo -e "\e[97m\e[1mUpgrade Package check...\n\e[0m"

        # Build the upgrade script
        cat > "$script_dir/upgrade_script.sh" << EOF

#!/bin/bash
# Clone in another directory
git clone --quiet $git_repository "$script_dir/upgrade"
cp -a "$script_dir/upgrade/." "$script_dir/."
sudo rm -r "$script_dir/upgrade"
# Update the version file
echo "$check_version" > "$version_file"
rm "$script_dir/pcheck.lock"
# Execute package check by replacement of this process
exec "$script_dir/package_check.sh" "${arguments[@]}"
EOF

# Give the execution right
chmod +x "$script_dir/upgrade_script.sh"

# Temporary upgrade fix
# Check if lynx is already installed.
if [ ! -e "$(which lynx)" ]
then
    sudo apt-get install -y lynx
fi

# Start the upgrade script by replacement of this process
exec "$script_dir/upgrade_script.sh"
    fi
fi

# Update the version file
echo "$check_version" > "$version_file"

#=================================================
# Upgrade Package linter
#=================================================

git_repository=https://github.com/YunoHost/package_linter
version_file="$script_dir/plinter_version"

check_version="$(git ls-remote $git_repository | cut -f 1 | head -n1)"

# If the version file exist, check for an upgrade
if [ -e "$version_file" ]
then
    # Check if the last commit on the repository match with the current version
    if [ "$check_version" != "$(cat "$version_file")" ]
    then
        # If the versions don't matches. Do an upgrade
        echo -e "\e[97m\e[1mUpgrade Package linter...\n\e[0m"

        # Clone in another directory
        git clone --quiet https://github.com/YunoHost/package_linter "$script_dir/package_linter_tmp"
        pip3 install pyparsing six

        # And replace
        cp -a "$script_dir/package_linter_tmp/." "$script_dir/package_linter/."
        sudo rm -r "$script_dir/package_linter_tmp"
    fi
else
    echo -e "\e[97mInstall Package linter.\n\e[0m"
    git clone --quiet $git_repository "$script_dir/package_linter"
    pip3 install pyparsing six
fi

# Update the version file
echo "$check_version" > "$version_file"

#=================================================
# Get variables from the config file
#=================================================

pcheck_config="$script_dir/config"
build_script="$script_dir/sub_scripts/lxc_build.sh"

if [ -e "$pcheck_config" ]
then
    # Read the config file if it exists
    ip_range=$(grep PLAGE_IP= "$pcheck_config" | cut -d '=' -f2)
    main_domain=$(grep DOMAIN= "$pcheck_config" | cut -d '=' -f2)
    yuno_pwd=$(grep YUNO_PWD= "$pcheck_config" | cut -d '=' -f2)
    lxc_name=$(grep LXC_NAME= "$pcheck_config" | cut -d '=' -f2)
    lxc_bridge=$(grep LXC_BRIDGE= "$pcheck_config" | cut -d '=' -f2)
    main_iface=$(grep iface= "$pcheck_config" | cut -d '=' -f2)
fi

# Use the default value and set it in the config file
replace_default_value () {
    CONFIG_KEY=$1
    local value=$(grep "|| $CONFIG_KEY=" "$build_script" | cut -d '=' -f2)
    if grep -q $CONFIG_KEY= "$pcheck_config"
    then
        sed -i "s/$CONFIG_KEY=.*/$CONFIG_KEY=$value/" "$pcheck_config"
    else
        echo -e "$CONFIG_KEY=$value\n" >> "$pcheck_config"
    fi
    echo $value
}
# Use default value from the build script if needed
if [ -z "$ip_range" ]; then
    ip_range=$(replace_default_value PLAGE_IP)
fi
if [ -z "$main_domain" ]; then
    main_domain=$(replace_default_value DOMAIN)
fi
if [ -z "$yuno_pwd" ]; then
    yuno_pwd=$(replace_default_value YUNO_PWD)
fi
if [ -z "$lxc_name" ]; then
    lxc_name=$(replace_default_value LXC_NAME)
fi
if [ -z "$lxc_bridge" ]; then
    lxc_bridge=$(replace_default_value LXC_BRIDGE)
fi

if [ -z "$main_iface" ]; then
    # Try to determine the main iface
    main_iface=$(sudo ip route | grep default | awk '{print $5;}')
    if [ -z $main_iface ]
    then
        echo -e "\e[91mUnable to find the name of the main iface.\e[0m"

        # Remove the lock file
        rm -f "$lock_file"
        # And exit
        exit 1
    fi
    # Store the main iface in the config file
    if grep -q iface= "$pcheck_config"
    then
        sed -i "s/iface=.*/iface=$main_iface/"
    else
        echo -e "# Main host iface\niface=$main_iface\n" >> "$pcheck_config"
    fi
fi

#=================================================
# Check the user who try to execute this script
#=================================================

setup_user_file="$script_dir/sub_scripts/setup_user"
if [ -e "$setup_user_file" ]
then
    # Compare the current user and the user stored in $setup_user_file
    authorised_user="$(cat "$setup_user_file")"
    if [ "$(whoami)" != "$authorised_user" ]
    then
        echo -e "\e[91mThis script need to be executed by the user $setup_user_file !\nThe current user is $(whoami).\e[0m"
        clean_exit 1
    fi
else
    echo -e "\e[93mUnable to define the user who authorised to use package check. Please fill the file $setup_user_file\e[0m"
fi

#=================================================
# Define globals variables
#=================================================

# Complete result log. Complete log of YunoHost
complete_log="$script_dir/Complete.log"
# Real YunoHost log
yunohost_log="/var/lib/lxc/$lxc_name/rootfs/var/log/yunohost/yunohost-cli.log"

sub_domain="sous.$main_domain"
test_user=package_checker

#=================================================
# Load all functions
#=================================================

source "$script_dir/sub_scripts/common.sh"
source "$script_dir/sub_scripts/launcher.sh"
source "$script_dir/sub_scripts/testing_process.sh"

#=================================================
# Check LXC
#=================================================

# Check if lxc is already installed
if dpkg-query -W -f '${Status}' "lxc" 2>/dev/null | grep -q "ok installed"
then
    # If lxc is installed, check if the container is already built.
    if ! sudo lxc-ls | grep -q "$lxc_name"
    then
        if [ $build_lxc -eq 1 ]
        then
            # If lxc's not installed and build_lxc set. Asks to build the container.
            build_lxc=2
        else
            critical "LXC is not installed or the container $lxc_name doesn't exist."
            critical "Use the script 'lxc_build.sh' to fix them."
            clean_exit 1
        fi
    fi
elif [ $build_lxc -eq 1 ]
then
    # If lxc's not installed and build_lxc set. Asks to build the container.
    build_lxc=2
fi

if [ $build_lxc -eq 2 ]
then
    # Install LXC and build the container before continue.
    "$script_dir/sub_scripts/lxc_build.sh"
fi

# Stop and restore the LXC container. In case of previous incomplete execution.
LXC_STOP
# Deactivate LXC network
LXC_TURNOFF

#=================================================
# Determine if it's a CI environment
#=================================================

# By default, it's a standalone execution.
type_exec_env=0
if [ -e "$script_dir/../config" ]
then
    # CI environment
    type_exec_env=1
fi
if [ -e "$script_dir/../auto_build/auto.conf" ]
then
    # Official CI environment
    type_exec_env=2
fi

#=================================================
# Pick up the package
#=================================================

echo "Pick up the package which will be tested."

# If the url is on a specific branch, extract the branch
if echo "$app_arg" | grep --quiet --extended-regexp "https?:\/\/.*\/tree\/"
then
    gitbranch="-b ${app_arg##*/tree/}"
    app_arg="${app_arg%%/tree/*}"
fi

if [ -n "$gitbranch" ]
then
    branch_msg=" on the branch ${gitbranch##-b }"
fi
info "Test the package $app_arg $branch_msg"

# Remove the previous package if it's still here.
rm -rf "$script_dir"/*_check

package_dir="$(basename "$app_arg")_check"
package_path="$script_dir/$package_dir"

# If the package is in a git repository
if echo "$app_arg" | grep -Eq "https?:\/\/"
then
    # Force the branch master if no branch is specified.
    if [ -z "$gitbranch" ]
    then
        if git ls-remote --quiet --exit-code $app_arg master
        then
            gitbranch="-b master"
        else
            if git ls-remote --quiet --exit-code $app_arg stable
            then
                gitbranch="-b stable"
            else
                critical "Unable to find a default branch to test (master or stable)"
                clean_exit 1
            fi
        fi
    fi
    # Clone the repository
    git clone $app_arg $gitbranch "$package_path"

    # If it's a local directory
else
    # Do a copy in the directory of Package check
    cp -a "$app_arg" "$package_path"
fi

# Check if the package directory is really here.
if [ ! -d "$package_path" ]; then
    critical "Unable to find the directory $package_path for the package..."
    clean_exit 1
fi




#=================================================
# Determine and print the results
#=================================================

TEST_RESULTS () {

    # Print the test result
    print_result () {

        # Print the result of this test
        # we use printf to force the length to 30 (filled with space)
        testname=$(printf %-30.30s "$1:")
        if [ $2 -eq 1 ]
        then
            echo "$testname ${BOLD}${GREEN}SUCCESS${NORMAL}"
        elif [ $2 -eq -1 ]
        then
            echo "$testname ${BOLD}${RED}FAIL${NORMAL}"
        else
            echo "$testname Not evaluated."
        fi
    }

    # Print the result for each test
    echo -e "\n\n"
    print_result "Package linter" $RESULT_linter
    print_result "Install" $RESULT_global_setup
    print_result "Remove" $RESULT_global_remove
    print_result "Install (subpath)" $RESULT_check_sub_dir
    print_result "Remove  (subpath)" $RESULT_check_remove_sub_dir
    print_result "Install (root)" $RESULT_check_root
    print_result "Remove  (root)" $RESULT_check_remove_root
    print_result "Upgrade" $RESULT_check_upgrade
    print_result "Install (private mode)" $RESULT_check_private
    print_result "Install (public mode)" $RESULT_check_public
    print_result "Install (multi-instance)" $RESULT_check_multi_instance
    print_result "Port already used" $RESULT_check_port
    print_result "Backup" $RESULT_check_backup
    print_result "Restore" $RESULT_check_restore
    print_result "Change URL" $RESULT_change_url
    print_result "Actions and config-panel" $RESULT_action_config_panel



    # Determine the level for this app

    # Each level can has 5 different values
    # 0    -> If this level can't be validated
    # 1    -> If this level is forced. Even if the tests fails
    # 2    -> Indicates the tests had previously validated this level
    # auto -> This level has not a value yet.
    # na   -> This level will not be checked, but it'll be ignored in the final sum

    # Set default values for level, if they're empty.
    test -n "${level[1]}" || level[1]=auto
    test -n "${level[2]}" || level[2]=auto
    test -n "${level[3]}" || level[3]=auto
    test -n "${level[4]}" || level[4]=auto
    test -n "${level[5]}" || level[5]=auto
    test -n "${level[5]}" || level[5]=auto
    test -n "${level[6]}" || level[6]=auto
    test -n "${level[7]}" || level[7]=auto
    test -n "${level[8]}" || level[8]=auto
    test -n "${level[9]}" || level[9]=0
    test -n "${level[10]}" || level[10]=0

    pass_level_1() {
        # -> The package can be install and remove.
        [ $RESULT_global_setup -eq 1 ] && \
        [ $RESULT_global_remove -eq 1 ]
    }

    pass_level_2() {
        # -> The package can be install and remove in all tested configurations.
        # Validated if none install failed
        [ $RESULT_check_sub_dir -ne -1 ] && \
        [ $RESULT_check_remove_sub_dir -ne -1 ] && \
        [ $RESULT_check_root -ne -1 ] && \
        [ $RESULT_check_remove_root -ne -1 ] && \
        [ $RESULT_check_private -ne -1 ] && \
        [ $RESULT_check_public -ne -1 ] && \
        [ $RESULT_check_multi_instance -ne -1 ]
    }

    pass_level_3() {
        # -> The package can be upgraded from the same version.
        # Validated if the upgrade is ok. Or if the upgrade has been not tested but already validated before.
        [ $RESULT_check_upgrade -eq 1 ] || \
        ( [ $RESULT_check_upgrade -ne -1 ] && \
        [ "${level[3]}" == "2" ] )
    }

    pass_level_4() {
        # -> The package can be backup and restore without error
        # Validated if backup and restore are ok. Or if backup and restore have been not tested but already validated before.
        ( [ $RESULT_check_backup -eq 1 ] && \
        [ $RESULT_check_restore -eq 1 ] ) || \
        ( [ $RESULT_check_backup -ne -1 ] && \
        [ $RESULT_check_restore -ne -1 ] && \
        [ "${level[4]}" == "2" ] )
    }

    pass_level_5() {
        # -> The package have no error with package linter
        # -> The package does not have any alias_traversal error
        # Validated if Linter is ok. Or if Linter has been not tested but already validated before.
        [ $RESULT_alias_traversal -ne 1 ] && \
        ([ $RESULT_linter -ge 1 ] || \
        ( [ $RESULT_linter -eq 0 ] && \
        [ "${level[5]}" == "2" ] ) )
    }

    pass_level_6() {
        # -> The package can be backup and restore without error
        # This is from the linter, tests if app is the Yunohost-apps organization
        [ $RESULT_linter_level_6 -eq 1 ] || \
        ([ $RESULT_linter_level_6 -eq 0 ] && \
        [ "${level[6]}" == "2" ] )
    }

    pass_level_7() {
        # -> None errors in all tests performed
        # Validated if none errors is happened.
        [ $RESULT_global_setup -ne -1 ] && \
        [ $RESULT_global_remove -ne -1 ] && \
        [ $RESULT_check_sub_dir -ne -1 ] && \
        [ $RESULT_check_remove_sub_dir -ne -1 ] && \
        [ $RESULT_check_remove_root -ne -1 ] && \
        [ $RESULT_check_upgrade -ne -1 ] && \
        [ $RESULT_check_private -ne -1 ] && \
        [ $RESULT_check_public -ne -1 ] && \
        [ $RESULT_check_multi_instance -ne -1 ] && \
        [ $RESULT_check_port -ne -1 ] && \
        [ $RESULT_check_backup -ne -1 ] && \
        [ $RESULT_check_restore -ne -1 ] && \
        [ $RESULT_change_url -ne -1 ] && \
        [ $RESULT_action_config_panel -ne -1 ] && \
        ([ $RESULT_linter_level_7 -ge 1 ] ||
        ([ $RESULT_linter_level_7 -eq 0 ] && \
        [ "${level[8]}" == "2" ] ))
    }

    pass_level_8() {
        # This happens in the linter
        # When writing this, defined as app being maintained + long term quality (=
        # certain amount of time level 5+ in the last year)
        [ $RESULT_linter_level_8 -ge 1 ] || \
        ([ $RESULT_linter_level_8 -eq 0 ] && \
        [ "${level[8]}" == "2" ] )
    }

    # Check if the level can be changed
    level_can_change () {
        # If the level is set at auto, it's waiting for a change
        # And if it's set at 2, its value can be modified by a new result
        [ "${level[$1]}" == "auto" ] || [ "${level[$1]}" -eq 2 ]
    }

    if level_can_change 1; then pass_level_1 && level[1]=2 || level[1]=0; fi
    if level_can_change 2; then pass_level_2 && level[2]=2 || level[2]=0; fi
    if level_can_change 3; then pass_level_3 && level[3]=2 || level[3]=0; fi
    if level_can_change 4; then pass_level_4 && level[4]=2 || level[4]=0; fi
    if level_can_change 5; then pass_level_5 && level[5]=2 || level[5]=0; fi
    if level_can_change 6; then pass_level_6 && level[6]=2 || level[6]=0; fi
    if level_can_change 7; then pass_level_7 && level[7]=2 || level[7]=0; fi
    if level_can_change 8; then pass_level_8 && level[8]=2 || level[8]=0; fi

    # Evaluate the ninth level
    # -> High quality package.
    # The level 9 can be validated only by the official list of app.
    level[9]=0
    # Define the level 9 only if we're working on a repository. Otherwise, we can't assert that this is the correct app.
    if echo "$app_arg" | grep --extended-regexp --quiet "https?:\/\/"
    then
        # Get the name of the app from the repository name.
        app_name="$(basename --multiple --suffix=_ynh "$app_arg")"

        # Get the last version of the app list
        list_url="https://raw.githubusercontent.com/YunoHost/apps/master/apps.json"
        if curl --silent $list_url | jq ".[\"$app_name\"].high_quality" | grep -q "true"
        then
            level[9]=2
        fi
    fi

    # Evaluate the tenth level
    # -> Not available yet...
    level[10]=0

    # Initialize the global level
    global_level=0

    # Calculate the final level
    for i in `seq 1 10`
    do

        # If there is a level still at 'auto', it's a mistake.
        if [ "${level[i]}" == "auto" ]
        then
            # So this level will set at 0.
            level[i]=0

            # If the level is at 'na', it will be ignored
        elif [ "${level[i]}" == "na" ]
        then
            continue

            # If the level is at 1 or 2. The global level will be set at this level
        elif [ "${level[i]}" -ge 1 ]
        then
            global_level=$i

            # But, if the level is at 0, the loop stop here
            # Like that, the global level rise while none level have failed
        else
            break
        fi
    done

    # If some witness files was missing, it's a big error ! So, the level fall immediately at 0.
    if [ $RESULT_witness -eq 1 ]
    then
        error "Some witness files has been deleted during those tests ! It's a very bad thing !"
        global_level=0
    fi

    # If the package linter returned a critical error, the app is flagged as broken / level 0
    if [ $RESULT_linter_broken -eq 1 ]
    then
        error "The package linter reported a critical failure ! App is considered broken !"
        global_level=0
    fi

    if [ $RESULT_alias_traversal -eq 1 ]
    then
        error "Issue alias_traversal was detected ! Please see here https://github.com/YunoHost/example_ynh/pull/45 to fix that."
    fi

    # Then, print the levels
    # Print the global level
    verbose_level=$(grep "^$global_level " "$script_dir/levels.list" | cut -c4-)

    info "Level of this application: $global_level ($verbose_level)"

    # And print the value for each level
    for i in `seq 1 10`
    do
        display="0"
        if [ "${level[$i]}" == "na" ]; then
            display="N/A"
        elif [ "${level[$i]}" -ge 1 ]; then
            display="1"
        fi
        echo -e "\t   Level $i: $display"
    done
}

#=================================================
# Parsing and performing tests
#=================================================
# Check if a check_process file exist
#=================================================

check_file=1
check_process="$package_path/check_process"

if [ ! -e "$check_process" ]
then
    error "Unable to find a check_process file."
    warning "Package check will attempt to automatically guess what tests to run."
    check_file=0
fi

#=================================================
# Set the timer for all tests
#=================================================

# Start the timer for this test
start_timer
# And keep this value separately
complete_start_timer=$starttime

#=================================================
# Initialize tests
#=================================================

# Purge some log files
> "$complete_log"
> "$script_dir/lxc_boot.log"

# Initialize LXC network
LXC_INIT

# Default values for check_process and TESTING_PROCESS
initialize_values() {
    # Test results
    RESULT_witness=0
    RESULT_alias_traversal=0
    RESULT_linter=0
    RESULT_linter_level_6=0
    RESULT_linter_level_7=0
    RESULT_linter_level_8=0
    RESULT_linter_broken=0
    RESULT_global_setup=0
    RESULT_global_remove=0
    RESULT_check_sub_dir=0
    RESULT_check_root=0
    RESULT_check_remove_sub_dir=0
    RESULT_check_remove_root=0
    RESULT_check_upgrade=0
    RESULT_check_backup=0
    RESULT_check_restore=0
    RESULT_check_private=0
    RESULT_check_public=0
    RESULT_check_multi_instance=0
    RESULT_check_port=0
    RESULT_change_url=0
    RESULT_action_config_panel=0

    # auto_remove parameter
    if [ $interrupt -eq 1 ]; then
        auto_remove=0
    else
        auto_remove=1
    fi

    # Number of tests to proceed
    total_number_of_test=0

    # Default path
    test_path=/

    # CHECK_URL default values
    curl_error=0
    yuno_portal=0
}

#=================================================
# Parse the check_process
#=================================================

# Parse the check_process only if it's exist
if [ $check_file -eq 1 ]
then
    info "Parsing check_process file"

    # Remove all commented lines in the check_process
    sed --in-place '/^#/d' "$check_process"
    # Remove all spaces at the beginning of the lines
    sed --in-place 's/^[ \t]*//g' "$check_process"

    # Check if a string can be find in the current line
    check_line () {
        return $(echo "$line" | grep -q "$1")
    }

    # Search a string in the partial check_process
    find_string () {
        echo $(grep -m1 "$1" "$partial_check_process")
    }

    # Extract a section found between $1 and $2 from the file $3
    extract_section () {
        # Erase the partial check_process
        > "$partial_check_process"
        local source_file="$3"
        local extract=0
        local line=""
        while read line
        do
            # Extract the line
            if [ $extract -eq 1 ]
            then
                # Check if the line is the second line to found
                if check_line "$2"; then
                    # Break the loop to finish the extract process
                    break;
                fi
                # Copy the line in the partial check_process
                echo "$line" >> "$partial_check_process"
            fi

            # Search for the first line
            if check_line "$1"; then
                # Activate the extract process
                extract=1
            fi
        done < "$source_file"
    }

    # Use 2 partial files, to keep one for a whole tests serie
    partial1="${check_process}_part1"
    partial2="${check_process}_part2"


    # Extract the level section
    partial_check_process=$partial1
    extract_section "^;;; Levels" ";; " "$check_process"

    # Get the value associated to each level
    # Get only the value for the level 5 from the check_process
    # 	for i in `seq 1 10`
    # 	do
    # Find the line for this level
    # 		line=$(find_string "^Level $i=")
    line=$(find_string "^Level 5=")
    # And get the value
    #		level[$i]=$(echo "$line" | cut -d'=' -f2)
    level[5]=$(echo "$line" | cut -d'=' -f2)
    # 	done


    # Extract the Options section
    partial_check_process=$partial1
    extract_section "^;;; Options" ";; " "$check_process"

    # Try to find a optionnal email address to notify the maintainer
    # In this case, this email will be used instead of the email from the manifest.
    dest="$(echo $(find_string "^Email=") | cut -d '=' -f2)"

    # Try to find a optionnal option for the grade of notification
    notification_grade="$(echo $(find_string "^Notification=") | cut -d '=' -f2)"


    # Parse each tests serie
    while read <&3 tests_serie
    do

        # Initialize the values for this serie of tests
        initialize_values

        # Break after the first tests serie
        if [ $total_number_of_test -ne 0 ] && [ $bash_mode -ne 1 ]; then
            read -p "Press a key to start the next tests serie..." < /dev/tty
        fi

        # Use the second file to extract the whole section of a tests serie
        partial_check_process=$partial2

        # Extract the section of the current tests serie
        extract_section "^$tests_serie" "^;;" "$check_process"
        partial_check_process=$partial1

        # Check if there a pre-install instruction for this serie
        extract_section "^; pre-install" "^;" "$partial2"
        pre_install="$(cat "$partial_check_process")"

        # Parse all infos about arguments of manifest
        # Extract the manifest arguments section from the second partial file
        extract_section "^; Manifest" "^; " "$partial2"

        # Initialize the arguments list
        manifest_arguments=""

        # Read each arguments and store them
        while read line
        do
            # Extract each argument by removing spaces or tabulations before a parenthesis
            add_arg="$(echo $line | sed 's/[ *|\t*](.*//')"
            # Remove all double quotes
            add_arg="${add_arg//\"/}"
            # Then add this argument and follow it by &
            manifest_arguments="${manifest_arguments}${add_arg}&"
        done < "$partial_check_process"

        # Try to find all specific arguments needed for the tests
        keep_name_arg_only () {
            # Find the line for the given argument
            local argument=$(find_string "($1")
            # If a line exist for this argument
            if [ -n "$argument" ]; then
                # Keep only the name of the argument
                echo "$(echo "$argument" | cut -d '=' -f1)"
            fi
        }
        domain_arg=$(keep_name_arg_only "DOMAIN")
        user_arg=$(keep_name_arg_only "USER")
        port_arg=$(keep_name_arg_only "PORT")
        path_arg=$(keep_name_arg_only "PATH")
        # Get the path value
        if [ -n "$path_arg" ]
        then
            line="$(find_string "(PATH")"
            # Keep only the part after the =
            line="$(echo "$line" | grep -o "path=.* " | cut -d "=" -f2)"
            # And remove " et spaces to keep only the path.
            line="${line//[\" ]/}"
            # If this path is not empty or equal to /. It become the new default path value.
            if [ ${#line} -gt 1 ]; then
                test_path="$line"
            fi
        fi
        public_arg=$(keep_name_arg_only "PUBLIC")
        # Find the values for public and private
        if [ -n "$public_arg" ]
        then
            line=$(find_string "(PUBLIC")
            public_public_arg=$(echo "$line" | grep -o "|public=[[:alnum:]]*" | cut -d "=" -f2)
            public_private_arg=$(echo "$line" | grep -o "|private=[[:alnum:]]*" | cut -d "=" -f2)
        fi

        if echo "$LIGNE" | grep -q "(PATH)"; then	# Path dans le manifest
            MANIFEST_PATH=$(echo "$LIGNE" | cut -d '=' -f1)	# Récupère la clé du manifest correspondant au path
            parse_path=$(echo "$LIGNE" | cut -d '"' -f2)	# Lit le path du check_process
            if [ -n "$parse_path" ]; then	# Si le path nest pas null, utilise ce path au lieu de la valeur par défaut.
                PATH_TEST=$(echo "$LIGNE" | cut -d '"' -f2)
            fi
            LIGNE=$(echo "$LIGNE" | cut -d '(' -f1)	# Retire lindicateur de clé de manifest à la fin de la ligne
        fi

        # Parse all infos about arguments of actions.toml
        # Extract the actions arguments section from the second partial file
        extract_section "^; Actions" "^; " "$partial2"

        # Initialize the arguments list
        actions_arguments=""

        # Read each arguments and store them
        while read line
        do
            # Remove all double quotes
            add_arg="${line//\"/}"
            # Then add this argument and follow it by :
            actions_arguments="${actions_arguments}${add_arg}:"
        done < "$partial_check_process"

        # Parse all infos about arguments of config-panel.toml
        # Extract the config_panel arguments section from the second partial file
        extract_section "^; Config_panel" "^; " "$partial2"

        # Initialize the arguments list
        config_panel_arguments=""

        # Read each arguments and store them
        while read line
        do
            # Remove all double quotes
            add_arg="${line//\"/}"
            # Then add this argument and follow it by :
            config_panel_arguments="${config_panel_arguments}${add_arg}:"
        done < "$partial_check_process"

        # Parse all tests to perform
        # Extract the checks options section from the second partial file
        extract_section "^; Checks" "^; " "$partial2"

        read_check_option () {
            # Find the line for the given check option
            local line=$(find_string "^$1=")
            # Get only the value
            local value=$(echo "$line" | cut -d '=' -f2)
            # And return this value
            if [ "${value:0:1}" = "1" ]
            then
                echo 1
            elif [ "${value:0:1}" = "0" ]
            then
                echo 0
            else
                echo -1
            fi
        }

        count_test () {
            # Increase the number of test, if this test is set at 1.
            test "$1" -eq 1 && total_number_of_test=$((total_number_of_test+1))
        }

        # Get standard options
        pkg_linter=$(read_check_option pkg_linter)
        count_test $pkg_linter
        setup_sub_dir=$(read_check_option setup_sub_dir)
        count_test $setup_sub_dir
        setup_root=$(read_check_option setup_root)
        count_test $setup_root
        setup_nourl=$(read_check_option setup_nourl)
        count_test $setup_nourl
        setup_private=$(read_check_option setup_private)
        count_test $setup_private
        setup_public=$(read_check_option setup_public)
        count_test $setup_public
        backup_restore=$(read_check_option backup_restore)
        count_test $backup_restore
        multi_instance=$(read_check_option multi_instance)
        count_test $multi_instance
        port_already_use=$(read_check_option port_already_use)
        count_test $port_already_use
        change_url=$(read_check_option change_url)
        count_test $change_url
        actions=$(read_check_option actions)
        count_test $actions
        config_panel=$(read_check_option config_panel)
        count_test $config_panel

        # For port_already_use, check if there is also a port number
        if [ $port_already_use -eq 1 ]
        then
            line=$(find_string "^port_already_use=")
            # If there is port number
            if echo "$line" | grep -q "([0-9]*)"
            then
                # Store the port number in port_arg and prefix it by # to means that not really a manifest arg
                port_arg="#$(echo "$line" | cut -d '(' -f2 | cut -d ')' -f1)"
            fi
        fi

        # Clean the upgrade list
        > "$script_dir/upgrade_list"
        # Get multiples lines for upgrade option.
        while $(grep --quiet "^upgrade=" "$partial_check_process")
        do
            # Get the value for the first upgrade test.
            temp_upgrade=$(read_check_option upgrade)
            count_test $temp_upgrade
            # Set upgrade to 1, but never to 0.
            if [ "$upgrade" != "1" ]; then
                upgrade=$temp_upgrade
            fi
            # Get this line to find if there an option.
            line=$(find_string "^upgrade=")
            if echo "$line" | grep --quiet "from_commit="
            then
                # Add the commit to the upgrade list
                line="${line##*from_commit=}"
                # Add the upgrade to the list only if the test is set to 1
                if [ $temp_upgrade -eq 1 ]; then
                    echo "$line" >> "$script_dir/upgrade_list"
                fi
            elif [ $temp_upgrade -eq 1 ]; then
                # Or simply 'current' for a standard upgrade.
                echo "current" >> "$script_dir/upgrade_list"
            fi
            # Remove this line from the check_process
            sed --in-place "\|${line}$|d" "$partial_check_process"
        done

        # Launch all tests successively
        TESTING_PROCESS
        # Print the final results of the tests
        TEST_RESULTS

        # Set snap0 as the current snapshot
        current_snapshot=snap0
        # And clean temporary snapshots
        unset root_snapshot
        unset subpath_snapshot

    done 3<<< "$(grep "^;; " "$check_process")"

    # No check_process file. Try to parse the manifest.
else
    # Initialize the values for this serie of tests
    initialize_values

    manifest_extract="$script_dir/manifest_extract"

    # Extract the informations from the manifest with the Bram's sly snake script.
    python "$script_dir/sub_scripts/manifest_parsing.py" "$package_path/manifest.json" > "$manifest_extract"

    # Default tests
    pkg_linter=1
    setup_sub_dir=1
    setup_root=1
    setup_nourl=0
    upgrade=1
    setup_private=1
    setup_public=1
    backup_restore=1
    multi_instance=1
    port_already_use=0
    change_url=0
    total_number_of_test=$((total_number_of_test+9))


    # Read each arguments and store them
    while read line
    do
        # Read each argument and pick up the first value. Then replace : by =
        add_arg="$(echo $line | cut -d ':' -f1,2 | sed s/:/=/)"
        # Then add this argument and follow it by &
        manifest_arguments="${manifest_arguments}${add_arg}&"
    done < "$manifest_extract"

    # Search a string in the partial check_process
    find_string () {
        echo $(grep "$1" "$manifest_extract")
    }

    # Try to find all specific arguments needed for the tests
    keep_name_arg_only () {
        # Find the line for the given argument
        local argument=$(find_string "$1")
        # If a line exist for this argument
        if [ -n "$argument" ]; then
            # Keep only the name of the argument
            echo "$(echo "$argument" | cut -d ':' -f1)"
        fi
    }
    domain_arg=$(keep_name_arg_only ":ynh.local")
    path_arg=$(keep_name_arg_only "path:")
    user_arg=$(keep_name_arg_only "user:\|admin:")
    public_arg=$(keep_name_arg_only "is_public:")
    # Find the values for public and private
    if [ -n "$public_arg" ]
    then
        line=$(find_string "is_public:")
        # Assume the first value is public and the second is private.
        public_public_arg=$(echo "$line" | cut -d ":" -f2)
        public_private_arg=$(echo "$line" | cut -d ":" -f3)
    fi

    count_test () {
        # Decrease the number of test, if this test is not already removed.
        if [ $1 -eq 1 ]; then
            total_number_of_test=$((total_number_of_test-1))
            return 1
        fi
    }

    # Disable some tests if the manifest key doesn't be found
    if [ -z "$domain_arg" ]
    then
        error "The manifest key for domain was not found."
        setup_sub_dir=0
        count_test "$setup_root" || setup_root=0
        count_test "$multi_instance" || multi_instance=0
        setup_nourl=1
    fi
    if [ -z "$path_arg" ]
    then
        error "The manifest key for path was not found."
        count_test "$setup_root" || setup_root=0
        count_test "$multi_instance" || multi_instance=0
    fi
    if [ -z "$public_arg" ]
    then
        error "The manifest key for public was not found."
        setup_private=0
        setup_public=0
        total_number_of_test=$((total_number_of_test-2))
    fi
    # Remove the multi-instance test if this parameter is set at false in the manifest.
    if grep multi_instance "$package_path/manifest.json" | grep -q false
    then
        count_test "$multi_instance" || multi_instance=0
    fi

    # Launch all tests successively
    TESTING_PROCESS
    # Print the final results of the tests
    TEST_RESULTS
fi

echo "You can find the complete log of these tests in $complete_log"

#=================================================
# Ending the timer
#=================================================

# Restore the started time for the timer
starttime=$complete_start_timer
# End the timer for the test
stop_timer 3

#=================================================
# Notification grade
#=================================================

notif_grade () {
    # Check the level of notification from the check_process.
    # Echo 1 if the grade is reached

    compare_grade ()
    {
        if echo "$notification_grade" | grep -q "$1"; then
            echo 1
        else
            echo 0
        fi
    }

    case "$1" in
        all)
            # If 'all' is needed, only a grade of notification at 'all' can match
            compare_grade "^all$"
            ;;
        change)
            # If 'change' is needed, notification at 'all' or 'change' can match
            compare_grade "^all$\|^change$"
            ;;
        down)
            # If 'down' is needed, notification at 'all', 'change' or 'down' match
            compare_grade "^all$\|^change$\|^down$"
            ;;
        *)
            echo 0
            ;;
    esac
}

#=================================================
# Inform of the results by XMPP and/or by mail
#=================================================

send_mail=0

# Keep only the name of the app
app_name=${package_dir%_ynh_check}

# If package check it's in the official CI environment
# Check the level variation
if [ $type_exec_env -eq 2 ]
then

    # Get the job name, stored in the work_list
    job=$(head -n1 "$script_dir/../work_list" | cut -d ';' -f 3)

    # Identify the type of test, stable (0), testing (1) or unstable (2)
    # Default stable
    test_type=0
    message=""
    if echo "$job" | grep -q "(testing)"
    then
        message="(TESTING) "
        test_type=1
    elif echo "$job" | grep -q "(unstable)"
    then
        message="(UNSTABLE) "
        test_type=2
    fi

    # Build the log path (and replace all space by %20 in the job name)
    if [ -n "$job" ]; then
        if systemctl list-units | grep --quiet jenkins
        then
            job_log="/job/${job// /%20}/lastBuild/console"
        elif systemctl list-units | grep --quiet yunorunner
        then
            # Get the directory of YunoRunner
            ci_dir="$(grep WorkingDirectory= /etc/systemd/system/yunorunner.service | cut -d= -f2)"
            # List the jobs from YunoRunner and grep the job (without Community or Official).
            job_id="$(cd "$ci_dir"; ve3/bin/python ciclic list | grep ${job%% *} | head -n1)"
            # Keep only the id of the job, by removing everything after -
            job_id="${job_id%% -*}"
            # And remove any space before the id.
            job_id="${job_id##* }"
            job_log="/job/$job_id"
        fi
    fi

    # If it's a test on testing or unstable
    if [ $test_type -gt 0 ]
    then
        # Remove unstable or testing of the job name to find its stable version in the level list
        job="${job% (*)}"
    fi

    # Get the previous level, found in the file list_level_stable
    previous_level=$(grep "^$job:" "$script_dir/../auto_build/list_level_stable" | cut -d: -f2)

    # Print the variation of the level. If this level is different than 0
    if [ $global_level -gt 0 ]
    then
        message="${message}Application $app_name"
        # If non previous level was found
        if [ -z "$previous_level" ]; then
            message="$message just reach the level $global_level"
            send_mail=$(notif_grade all)
            # If the level stays the same
        elif [ $global_level -eq $previous_level ]; then
            message="$message stays at level $global_level"
            # Need notification at 'all' to notify by email
            send_mail=$(notif_grade all)
            # If the level go up
        elif [ $global_level -gt $previous_level ]; then
            message="$message rise from level $previous_level to level $global_level"
            # Need notification at 'change' to notify by email
            send_mail=$(notif_grade change)
            # If the level go down
        elif [ $global_level -lt $previous_level ]; then
            message="$message go down from level $previous_level to level $global_level"
            # Need notification at 'down' to notify by email
            send_mail=$(notif_grade down)
        fi
    fi
fi

# If the app completely failed and obtained 0
if [ $global_level -eq 0 ]
then
    message="${message}Application $app_name has completely failed the continuous integration tests"

    # Always send an email if the app failed
    send_mail=1
fi

# The mail subject is the message to send, before any logs informations
subject="[YunoHost] $message"

# If the test was perform in the official CI environment
# Add the log address
# And inform with xmpp
if [ $type_exec_env -eq 2 ]
then

    # Build the address of the server from auto.conf
    ci_path=$(grep "DOMAIN=" "$script_dir/../auto_build/auto.conf" | cut -d= -f2)/$(grep "CI_PATH=" "$script_dir/../auto_build/auto.conf" | cut -d= -f2)

    # Add the log adress to the message
    message="$message on https://$ci_path$job_log"

    # Send a xmpp notification on the chat room "apps"
    # Only for a test with the stable version of YunoHost
    if [ $test_type -eq 0 ]
    then
        "$script_dir/../auto_build/xmpp_bot/xmpp_post.sh" "$message" > /dev/null 2>&1
    fi
fi

# Send a mail to main maintainer according to notification option in the check_process.
# Only if package check is in a CI environment (Official or not)
if [ $type_exec_env -ge 1 ] && [ $send_mail -eq 1 ]
then

    # Add a 'from' header for the official CI only.
    # Apparently, this trick is not needed anymore !?
    #	if [ $type_exec_env -eq 2 ]; then
    #		from_yuno="-a \"From: yunohost@yunohost.org\""
    #	fi

    # Get the maintainer email from the manifest. If it doesn't found if the check_process
    if [ -z "$dest" ]; then
        dest=$(grep '\"email\": ' "$package_path/manifest.json" | cut -d '"' -f 4)
    fi

    # Send the message by mail, if a address has been find
    if [ -n "$dest" ]; then
        mail $from_yuno -s "$subject" "$dest" <<< "$message"
    fi
fi

#=================================================
# Clean and exit
#=================================================

clean_exit 0
