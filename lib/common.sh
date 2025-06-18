#!/bin/bash
# shellcheck disable=SC2034,SC2155

# YunoHost install parameters
YUNO_PWD="admin"
DOMAIN="domain.tld"
SUBDOMAIN="sub.$DOMAIN"
TEST_USER="package_checker"

# shellcheck disable=SC1091
[[ -e "./config" ]] && source "./config"

ARCH=${ARCH:-amd64}
DIST=${DIST:-bullseye}
DEFAULT_PHP_VERSION=${DEFAULT_PHP_VERSION:-7.4}

# YunoHost version: stable, testing or unstable
YNH_BRANCH=${YNH_BRANCH:-stable}

WORKER_ID=${WORKER_ID:-0}
LXC_BASE="yunohost/$DIST-$YNH_BRANCH/appci"
LXC_NAME="ynh-appci-$DIST-$ARCH-$YNH_BRANCH-test-${WORKER_ID}"

readonly lock_file="./pcheck-${WORKER_ID}.lock"

#=================================================
# LXC helpers
#=================================================

assert_we_are_connected_to_the_internets() {
    ping -q -c 2 yunohost.org > /dev/null 2>&1 \
    || ping -q -c 2 framasoft.org > /dev/null 2>&1 \
    || log_critical "Unable to connect to internet."
}

assert_we_have_all_dependencies() {
    : "${lxc:=}"  # Initialize lxc to an invalid value if not already defined
    deps=("lynx" "jq" "python3" "pip3")
    if [[ "${lxc}" == "incus" ]]; then
        deps+=(incus)
    elif [[ "${lxc}" == "lxc" ]]; then
        deps+=(lxc lxd)
    fi

    for dep in "${deps[@]}"; do
        which "$dep" > /dev/null 2>&1 || log_critical "Please install $dep"
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
        if [[ ! -e /usr/local/bin/lxc ]] && [[ ! -e /usr/local/bin/lxd ]]; then
            log_critical "You might want to add lxc and lxd inside /usr/local/bin so that there's no tricky PATH issue with sudo. If you installed lxd/lxc with snapd, this should do the trick: sudo ln -s /snap/bin/lxc /usr/local/bin/lxc && sudo ln -s /snap/bin/lxd /usr/local/bin/lxd"
        fi
    fi

    ip a | grep -q lxdbr0 \
        || log_critical "There is no 'lxdbr0' interface... Did you ran 'lxd init' ?"
}

function check_incus_setup()
{
    # Check incus is installed somehow
    if ! which incus &>/dev/null; then
        log_critical "You need to have Incus installed for ynh-dev to be usable from the host machine. Refer to the README to know how to install it."
    fi
    if ! id -nG "$(whoami)" | grep -qw "incus-admin"; then
        log_critical "You need to be in the incus-admin group!"
    fi

    ip a | grep -q incusbr0 \
        || log_warning "There is no 'incusbr0' interface... Did you ran 'incus admin init' ?"

    set_incus_remote
}

function set_incus_remote()
{
    remote_url=$(incus remote list -f json | jq '.yunohost.Addr')
    if [[ "${remote_url}" == *"devbaseimgs"* ]]; then
        incus remote remove yunohost
        remote_url=null
    fi
    if [[ "$remote_url" == "null" ]]; then
        incus remote add yunohost https://repo.yunohost.org/incus --protocol simplestreams --public
    fi
}

function check_lxc_setup()
{
    if [[ "${lxc}" == "incus" ]]; then
        check_incus_setup
    else
        check_lxd_setup
    fi
}

#=================================================
# Logging helpers
#=================================================

readonly NORMAL=$(printf '\033[0m')
readonly BOLD=$(printf '\033[1m')
# readonly faint=$(printf '\033[2m')
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
    # $1 = Type of message
    msg_type="${1:-}"

    local finishtime
    finishtime=$(date +%s)
    # Calculate the gap between the starting and the ending of the timer
    local elapsedtime=$(( finishtime - starttime ))
    # Extract the number of hour
    local hours=$(( elapsedtime / 3600 ))
    local elapsedtime=$(( elapsedtime - ( 3600 * hours) ))
    # Minutes
    local minutes=$(( elapsedtime / 60 ))
    # And seconds
    local seconds=$(( elapsedtime - ( 60 * minutes) ))

    local phours=""
    local pminutes=""
    local pseconds=""

    # Avoid null values
    [ "$hours" -eq 0 ] || phours="$hours hour"
    [ "$minutes" -eq 0 ] || pminutes="$minutes minute"
    [ "$seconds" -eq 0 ] || pseconds="$seconds second"

    # Add a 's' for plural values
    [ "$hours" -eq 1 ] && phours="${phours}, " || test -z "$phours" || phours="${phours}s, "
    [ "$minutes" -eq 1 ] && pminutes="${pminutes}, " || test -z "$pminutes" || pminutes="${pminutes}s, "
    [ "$seconds" -gt 1 ] && pseconds="${pseconds}s" || pseconds="0s"

    local time
    time="${phours}${pminutes}${pseconds} ($(date '+%T %Z' -u))"
    if [ "$msg_type" = "one_test" ]; then
        log_info "Working time for this test: $time"
    elif [ "$msg_type" = "all_tests" ]; then
        log_info "Global working time for all tests: $time"
    else
        log_debug "Working time: $time"
    fi
}

#=================================================
# Resource metrics helpers
#=================================================
# Communication between the background thread and the main one
# is done via a shared memory.

get_ram_usage() {
    RUN_INSIDE_LXC free -m | grep Mem | awk '{print $3}'
}

get_disk_usage() {
    RUN_INSIDE_LXC df --output="used" --total -k -l | tail -n 1
}

metrics_background_thread() {
    declare -A resources=( [ram]=0 )
    while true; do
        ram_usage=$(get_ram_usage)
        #echo "$ram_usage"
        if ((ram_usage > resources[ram])); then
            resources[ram]=$ram_usage
        fi
        declare -p resources > "$TEST_CONTEXT/metrics_vars"
        sleep 1
    done
}

metrics_start() {
    ram_usage_base=$(get_ram_usage)
    disk_usage_base=$(get_disk_usage)
    metrics_background_thread &
    metrics_background_thread_pid=$!
}

metrics_stop() {
    kill "$metrics_background_thread_pid"
    # shellcheck disable=SC1091
    source "$TEST_CONTEXT/metrics_vars"
    ram_usage_end=$(get_ram_usage)
    disk_usage_end=$(get_disk_usage)

    max_ram_usage_diff_peak=$((resources[ram] - ram_usage_base))
    max_ram_usage_diff_end=$((ram_usage_end - ram_usage_base))
    max_disk_usage_diff_end=$(awk -v before="$disk_usage_base" -v after="$disk_usage_end"\
        'BEGIN{printf "%.1f\n", (after - before)/1024}')

    log_info "Peak RAM usage during this test: ${max_ram_usage_diff_peak}MB"
    log_info "RAM usage diff after test: ${max_ram_usage_diff_end}MB"
    log_info "Disk usage diff after test: ${max_disk_usage_diff_end}MB"
}

#=================================================
# Package check self-upgrade
#=================================================

function self_upgrade()
{
    # We only self-upgrade if we're in a git repo on main branch
    # (which should correspond to production contexts)
    [[ -d ".git" ]] || return
    [[ $(git rev-parse --abbrev-ref HEAD) == "master" ]] || \
    [[ $(git rev-parse --abbrev-ref HEAD) == "main" ]] || return

    git fetch origin --quiet

    # If already up to date, don't do anything else
    [[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] && return

    log_info "Upgrading package_check..."
    git reset --hard origin/main --quiet
    # shellcheck disable=SC2154
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
    else
        git -C "./package_linter" fetch origin --quiet
        git -C "./package_linter" reset --hard origin/main --quiet
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
        gitbranch="${path_to_package_to_test##*/tree/}"
        path_to_package_to_test="${path_to_package_to_test%%/tree/*}"
    fi

    log_info "Testing package $path_to_package_to_test"

    package_path="$TEST_CONTEXT/app_folder"

    # If the package is in a git repository
    if echo "$path_to_package_to_test" | grep -Eq "https?:\/\/"; then
        # Force the branch main or master if no branch is specified.
        if [ -z "$gitbranch" ]; then
            branches=(main master stable)
            for branch in "${branches[@]}"; do
                if git ls-remote --quiet --exit-code "$path_to_package_to_test" "$branch" >/dev/null; then
                    gitbranch="$branch"
                    break
                fi
            done
            if [ -z "$gitbranch" ]; then
                log_critical "Unable to find a default branch to test (master or stable)"
            fi
        fi

        log_info " on branch ${gitbranch}"

        # Clone the repository
        git clone --quiet "$path_to_package_to_test" -b "$gitbranch" "$package_path"

        if [[ ! -e "$package_path" ]]
        then
            log_critical "Failed to git clone the repo / branch ?"
        fi

        log_info " (commit $(git -C "$package_path" rev-parse HEAD))"

        # If it's a local directory
    else
        # Do a copy in the directory of Package check
        cp -a "$path_to_package_to_test" "$package_path"
    fi

    git -C "$package_path" rev-parse HEAD > "$TEST_CONTEXT/commit"
    git -C "$package_path" show --no-patch --format=%ct HEAD > "$TEST_CONTEXT/commit_timestamp"

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
