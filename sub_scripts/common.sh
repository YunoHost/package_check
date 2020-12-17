#!/bin/bash

DEFAULT_DIST="buster"

# By default we'll install Yunohost with the default branch
YNH_INSTALL_SCRIPT_BRANCH=""

# Admin password
YUNO_PWD="admin"

# Domaines de test
DOMAIN="domain.tld"
SUBDOMAIN="sub.$DOMAIN"

# User de test
TEST_USER="package_checker"

LXC_NAME="ynh-appci-$DEFAULT_DIST"

[[ -e "./config" ]] && source "./config"

readonly lock_file="./pcheck.lock"

#=================================================
# LXC helpers
#=================================================

RUN_INSIDE_LXC() {
    sudo lxc exec $LXC_NAME -- "$@"
    sudo lxc-attach -n  -- "$@"
}

assert_we_are_the_setup_user() {
    [ -e "./.setup_user" ] || return
    local setup_user=$(cat "./.setup_user")

    [ "$(whoami)" == $setup_user ] \
    || log_critical "Ce script doit être exécuté avec l'utilisateur $setup_user !\nL'utilisateur actuel est $(whoami)."
}

assert_we_are_connected_to_the_internets() {
    ping -q -c 2 yunohost.org > /dev/null 2>&1 \
    || ping -q -c 2 framasoft.org > /dev/null 2>&1 \
    || log_critical "Unable to connect to internet."
}

#=================================================
# Logging helpers
#=================================================

readonly NORMAL=$(printf '\033[0m')
readonly BOLD=$(printf '\033[1m')
readonly faint=$(printf '\033[2m')
readonly UNDERLINE=$(printf '\033[4m')
readonly NEGATIVE=$(printf '\033[7m')
readonly RED=$(printf '\033[31m')
readonly GREEN=$(printf '\033[32m')
readonly ORANGE=$(printf '\033[33m')
readonly BLUE=$(printf '\033[34m')
readonly YELLOW=$(printf '\033[93m')
readonly WHITE=$(printf '\033[39m')

function log_title()
{
    cat << EOF
${BOLD}
 ===================================
 $1
 ===================================
${NORMAL}
EOF
}

function log_small_title()
{
    echo -e "\n${BOLD} > ${1}${NORMAL}\n"
}


function log_debug()
{
    echo "$1" >&3
}

function log_info()
{
    echo "${1}"
}

function log_success()
{
    echo "${BOLD}${GREEN}Success: ${1}${NORMAL}"
}

function log_warning()
{
    echo "${BOLD}${ORANGE}Warning: ${1}${NORMAL}"
}

function log_error()
{
    echo "${BOLD}${RED}Error: ${1}${NORMAL}"
}

function log_critical()
{
    echo "${BOLD}${RED}Critical: ${1}${NORMAL}"
    clean_exit 1
}

function log_report_test_success () {
    echo -e "\n${BOLD}${GREEN}--- SUCCESS ---${NORMAL}\n"
}

function log_report_test_warning () {
    echo -e "\n${BOLD}${ORANGE}--- WARNING ---${NORMAL}\n"
}

function log_report_test_failed () {
    echo -e "\n${BOLD}${RED}--- FAIL ---${NORMAL}\n"
}

#=================================================
# Timing helpers
#=================================================

start_timer () {
    # Set the beginning of the timer
    starttime=$(date +%s)
}

stop_timer () {
    # Ending the timer
    # $1 = Type of querying

    local finishtime=$(date +%s)
    # Calculate the gap between the starting and the ending of the timer
    local elapsedtime=$(echo $(( $finishtime - $starttime )))
    # Extract the number of hour
    local hours=$(echo $(( $elapsedtime / 3600 )))
    local elapsedtime=$(echo $(( $elapsedtime - ( 3600 * $hours) )))
    # Minutes
    local minutes=$(echo $(( $elapsedtime / 60 )))
    # And seconds
    local seconds=$(echo $(( $elapsedtime - ( 60 * $minutes) )))

    local phours=""
    local pminutes=""
    local pseconds=""

    # Avoid null values
    [ $hours -eq 0 ] || phours="$hours hour"
    [ $minutes -eq 0 ] || pminutes="$minutes minute"
    [ $seconds -eq 0 ] || pseconds="$seconds second"

    # Add a 's' for plural values
    [ $hours -eq 1 ] && phours="${phours}, " || test -z "$phours" || phours="${phours}s, "
    [ $minutes -eq 1 ] && pminutes="${pminutes}, " || test -z "$pminutes" || pminutes="${pminutes}s, "
    [ $seconds -gt 1 ] && pseconds="${pseconds}s"

    time="${phours}${pminutes}${pseconds} ($(date '+%T'))"
    if [ $1 -eq 2 ]; then
        log_info "Working time for this test: $time"
    elif [ $1 -eq 3 ]; then
        log_info "Global working time for all tests: $time"
    else
        log_debug "Working time: $time"
    fi
}

#=================================================
# Upgrade Package check
#=================================================


function self_upgrade()
{
    local git_repository=https://github.com/YunoHost/package_check
    local version_file="./.pcheck_version"

    local check_version="$(git ls-remote $git_repository | cut -f 1 | head -n1)"

    # If the version file exist, check for an upgrade
    if [ -e "$version_file" ]
    then
        # Check if the last commit on the repository match with the current version
        if [ "$check_version" != "$(cat "$version_file")" ]
        then
            # If the versions don't matches. Do an upgrade
            log_info "Upgrading Package check"

            # Build the upgrade script
            cat > "./upgrade_script.sh" << EOF

#!/bin/bash
# Clone in another directory
git clone --quiet $git_repository "./upgrade"
cp -a "./upgrade/." "./."
sudo rm -r "./upgrade"
# Update the version file
echo "$check_version" > "$version_file"
rm "./pcheck.lock"
# Execute package check by replacement of this process
exec "./package_check.sh" "${arguments[@]}"
EOF

            # Give the execution right
            chmod +x "./upgrade_script.sh"

            # Start the upgrade script by replacement of this process
            exec "./upgrade_script.sh"
        fi
    fi

    # Update the version file
    echo "$check_version" > "$version_file"
}

#=================================================
# Upgrade Package linter
#=================================================

function fetch_or_upgrade_package_linter()
{
    local git_repository=https://github.com/YunoHost/package_linter
    local version_file="./.plinter_version"

    local check_version="$(git ls-remote $git_repository | cut -f 1 | head -n1)"

    # If the version file exist, check for an upgrade
    if [ -e "$version_file" ]
    then
        # Check if the last commit on the repository match with the current version
        if [ "$check_version" != "$(cat "$version_file")" ]
        then
            # If the versions don't matches. Do an upgrade
            log_info "Upgrading Package linter"

            # Clone in another directory
            git clone --quiet $git_repository "./package_linter_tmp"
            pip3 install pyparsing six

            # And replace
            cp -a "./package_linter_tmp/." "./package_linter/."
            sudo rm -r "./package_linter_tmp"
        fi
    else
        log_info "Installing Package linter"
        git clone --quiet $git_repository "./package_linter"
        pip3 install pyparsing six
    fi

    # Update the version file
    echo "$check_version" > "$version_file"
}

