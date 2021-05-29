#!/bin/bash

# Yunohost install parameters
YUNO_PWD="admin"
DOMAIN="domain.tld"
SUBDOMAIN="sub.$DOMAIN"
TEST_USER="package_checker"

[[ -e "./config" ]] && source "./config"

ARCH=${ARCH:-amd64}
DIST=${DIST:-buster}

# Yunohost version: stable, testing or unstable
YNH_BRANCH=${YNH_BRANCH:-stable}

LXC_BASE="ynh-appci-$DIST-$ARCH-$YNH_BRANCH-base"
LXC_NAME="ynh-appci-$DIST-$ARCH-$YNH_BRANCH-test"

readonly lock_file="./pcheck.lock"

DEFAULT_PHP_VERSION="7.3"
[[ "$DIST" == "bullseye" ]] && DEFAULT_PHP_VERSION="7.4"

#=================================================
# LXC helpers
#=================================================

assert_we_are_connected_to_the_internets() {
    ping -q -c 2 yunohost.org > /dev/null 2>&1 \
    || ping -q -c 2 framasoft.org > /dev/null 2>&1 \
    || log_critical "Unable to connect to internet."
}

assert_we_have_all_dependencies() {
    for dep in "lxc" "lxd" "lynx" "jq" "python3" "pip3"
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
 ============================================
 $1
 ============================================
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
    exit 1
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

    local time="${phours}${pminutes}${pseconds} ($(date '+%T'))"
    if [ $1 -eq 2 ]; then
        log_info "Working time for this test: $time"
    elif [ $1 -eq 3 ]; then
        log_info "Global working time for all tests: $time"
    else
        log_debug "Working time: $time"
    fi
}

#=================================================
# Package check self-upgrade
#=================================================

function self_upgrade()
{
    # We only self-upgrade if we're in a git repo on master branch
    # (which should correspond to production contexts)
    [[ -d ".git" ]] || return
    [[ $(git rev-parse --abbrev-ref HEAD) == "master" ]] || return

    git fetch origin --quiet

    # If already up to date, don't do anything else
    [[ $(git rev-parse HEAD) == $(git rev-parse origin/master) ]] && return

    log_info "Upgrading package_check..."
    git reset --hard origin/master --quiet
    exec "./package_check.sh" "${arguments[@]}"
}

#=================================================
# Upgrade Package linter
#=================================================

function fetch_or_upgrade_package_linter()
{
    local git_repository=https://github.com/YunoHost/package_linter

    if [[ ! -d "./package_linter" ]]
    then
        log_info "Installing Package linter"
        git clone --quiet $git_repository "./package_linter"
        pip3 install pyparsing six
    else
        git -C "./package_linter" fetch origin --quiet
        git -C "./package_linter" reset --hard origin/master --quiet
    fi
}

#=================================================
# Pick up the package
#=================================================

function fetch_package_to_test() {

    local path_to_package_to_test="$1"

    # If the url is on a specific branch, extract the branch
    if echo "$path_to_package_to_test" | grep -Eq "https?:\/\/.*\/tree\/"
    then
        gitbranch="-b ${path_to_package_to_test##*/tree/}"
        path_to_package_to_test="${path_to_package_to_test%%/tree/*}"
    fi

    log_info "Testing package $path_to_package_to_test"

    package_path="$TEST_CONTEXT/app_folder"

    # If the package is in a git repository
    if echo "$path_to_package_to_test" | grep -Eq "https?:\/\/"
    then
        # Force the branch master if no branch is specified.
        if [ -z "$gitbranch" ]
        then
            if git ls-remote --quiet --exit-code $path_to_package_to_test master
            then
                gitbranch="-b master"
            else
                if git ls-remote --quiet --exit-code $path_to_package_to_test stable
                then
                    gitbranch="-b stable"
                else
                    log_critical "Unable to find a default branch to test (master or stable)"
                fi
            fi
        fi

        log_info " on branch ${gitbranch##-b }"

        # Clone the repository
        git clone --quiet $path_to_package_to_test $gitbranch "$package_path"

        log_info " (commit $(git -C $package_path rev-parse HEAD))"

        # If it's a local directory
    else
        # Do a copy in the directory of Package check
        cp -a "$path_to_package_to_test" "$package_path"
    fi

    git -C $package_path rev-parse HEAD > $TEST_CONTEXT/commit

    # Check if the package directory is really here.
    if [ ! -d "$package_path" ]; then
        log_critical "Unable to find the directory $package_path for the package..."
    fi
}

#=================================================
# GET HOST ARCHITECTURE
#=================================================

function get_arch()
{
    local architecture
    if uname -m | grep -q "arm64" || uname -m | grep -q "aarch64"; then
        architecture="aarch64"
    elif uname -m | grep -q "64"; then
        architecture="amd64"
    elif uname -m | grep -q "86"; then
        architecture="i386"
    elif uname -m | grep -q "arm"; then
        architecture="armhf"
    else
        architecture="unknown"
    fi
    echo $architecture
}
