#!/bin/bash

ARCH="amd64"
DIST="buster"

# By default we'll install Yunohost with the default branch
YNH_INSTALL_SCRIPT_BRANCH=""

# Admin password
YUNO_PWD="admin"

# Domaines de test
DOMAIN="domain.tld"
SUBDOMAIN="sub.$DOMAIN"

# User de test
TEST_USER="package_checker"

LXC_BASE="ynh-appci-$DIST-$ARCH-base"
LXC_NAME="ynh-appci-test"

[[ -e "./config" ]] && source "./config"

readonly lock_file="./pcheck.lock"

clean_exit () {

    LXC_RESET

    [ -n "$TEST_CONTEXT" ] && rm -rf "$TEST_CONTEXT"
    rm -f "$lock_file"

    exit $1
}

#=================================================
# LXC helpers
#=================================================

assert_we_are_connected_to_the_internets() {
    ping -q -c 2 yunohost.org > /dev/null 2>&1 \
    || ping -q -c 2 framasoft.org > /dev/null 2>&1 \
    || log_critical "Unable to connect to internet."
}

assert_we_have_all_dependencies() {
    for dep in "lxc" "lynx"
    do
        which $dep 2>&1 > /dev/null || log_critical "Please install $dep"
    done
}

function check_lxd_setup()
{
    # Check lxd is installed somehow
    [[ -e /snap/bin/lxd ]] || which lxd &>/dev/null \
        || log_critical "You need to have LXD installed. Refer to the README to know how to install it."

    # Check that we'll be able to use lxc/lxd using sudo (for which the PATH is defined in /etc/sudoers and probably doesn't include /snap/bin)
    if [[ ! -e /usr/bin/lxc ]] && [[ ! -e /usr/bin/lxd ]]
    then
        [[ -e /usr/local/bin/lxc ]] && [[ -e /usr/local/bin/lxd ]] \
            || log_critical "You might want to add lxc and lxd inside /usr/local/bin so that there's no tricky PATH issue with sudo. If you installed lxd/lxc with snapd, this should do the trick: sudo ln -s /snap/bin/lxc /usr/local/bin/lxc && sudo ln -s /snap/bin/lxd /usr/local/bin/lxd"
    fi

    ip a | grep -q lxdbr0 \
        || log_critical "There is no 'lxdbr0' interface... Did you ran 'lxd init' ?"
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
    cat << EOF | tee -a /proc/self/fd/3
${BOLD}
 ===================================
 $1
 ===================================
${NORMAL}
EOF
}

function log_small_title()
{
    echo -e "\n${BOLD} > ${1}${NORMAL}\n" | tee -a /proc/self/fd/3
}


function log_debug()
{
    echo "$1" >> /proc/self/fd/3
}

function log_info()
{
    echo "${1}" | tee -a /proc/self/fd/3
}

function log_success()
{
    echo "${BOLD}${GREEN}Success: ${1}${NORMAL}" | tee -a /proc/self/fd/3
}

function log_warning()
{
    echo "${BOLD}${ORANGE}Warning: ${1}${NORMAL}" | tee -a /proc/self/fd/3
}

function log_error()
{
    echo "${BOLD}${RED}Error: ${1}${NORMAL}" | tee -a /proc/self/fd/3
}

function log_critical()
{
    echo "${BOLD}${RED}Critical: ${1}${NORMAL}" | tee -a /proc/self/fd/3
    clean_exit 1
}

function log_report_test_success () {
    echo -e "\n${BOLD}${GREEN}--- SUCCESS ---${NORMAL}\n" | tee -a /proc/self/fd/3
}

function log_report_test_warning () {
    echo -e "\n${BOLD}${ORANGE}--- WARNING ---${NORMAL}\n" | tee -a /proc/self/fd/3
}

function log_report_test_failed () {
    echo -e "\n${BOLD}${RED}--- FAIL ---${NORMAL}\n" | tee -a /proc/self/fd/3
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
    [ $seconds -gt 1 ] && pseconds="${pseconds}s" || pseconds="0s"

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

