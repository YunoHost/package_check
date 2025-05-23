#!/bin/bash

cd "$(dirname "$(realpath "$0")")" || exit 1
source "./lib/common.sh"
source "./lib/tests_coordination.sh"
source "./lib/build_base_lxc.sh"

print_help() {
    cat << EOF
 Usage: package_check.sh [OPTION]... PACKAGE_TO_CHECK

    -b, --branch=BRANCH         Specify a branch to check.
    -D, --dry-run               Show a JSON representing which tests are going to be ran (meant for debugging)
    -i, --interactive           Wait for the user to continue before each remove
    -e, --interactive-on-errors Wait for the user to continue on errors
    -s, --force-stop            Force the stop of running package_check
    -r, --rebuild               (Re)Build the base container
                                (N.B.: you're not supposed to use this option,
                                images are supposed to be fetch from
                                repo.yunohost.org/incus automatically)
    -S, --storage-dir DIRECTORY Where to store temporary test files like yunohost backups
    -h, --help                  Display this help

    Pass YNHDEV_BACKEND=incus|lxd to use a specific LXD-compatible backend.
    Pass DIST=bullseye|bookworm to use a specific distribution version
    Pass YNH_BRANCH=stable|unstable to use a specific Yunohost branch

EOF
exit 0
}


#=================================================
# Pase CLI arguments
#=================================================

# If no arguments provided
# Print the help and exit
[ "$#" -eq 0 ] && print_help

gitbranch=""
dry_run=0
interactive=0
interactive_on_errors=0
rebuild=0
force_stop=0
storage_dir="${YNH_PACKAGE_CHECK_STORAGE_DIR:-}"

function parse_args() {

    local getopts_built_arg=()

    # Read the array value per value
    for i in $(seq 0 $(( ${#arguments[@]} -1 )))
    do
        if [[ "${arguments[i]}" =~ "--branch=" ]]
        then
            getopts_built_arg+=(-b)
            arguments[i]=${arguments[i]//--branch=/}
        fi
        # For each argument in the array, reduce to short argument for getopts
        arguments[i]=${arguments[i]//--interactive/-i}
        arguments[i]=${arguments[i]//--dry-run/-D}
        arguments[i]=${arguments[i]//--rebuild/-r}
        arguments[i]=${arguments[i]//--force-stop/-s}
        arguments[i]=${arguments[i]//--storage-dir/-s}
        arguments[i]=${arguments[i]//--help/-h}
        getopts_built_arg+=("${arguments[i]}")
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
                getopts ":b:Diresh" parameter || true
                case $parameter in
                    b)
                        # --branch=branch-name
                        gitbranch="$OPTARG"
                        shift_value=2
                        ;;
                    i)
                        # --interactive
                        interactive=1
                        shift_value=1
                        ;;
                    D)
                        # --dry-run
                        dry_run=1
                        shift_value=1
                        ;;
                    e)
                        # --interactive-on-errors
                        interactive_on_errors=1
                        shift_value=1
                        ;;
                    r)
                        # --rebuild
                        rebuild=1
                        shift_value=1
                        ;;
                    s)
                        # --force-stop
                        force_stop=1
                        shift_value=1
                        ;;
                    S)
                        # --storage-dir
                        storage_dir=$OPTARG
                        shift_value=2
                        ;;
                    h)
                        # --help
                        print_help
                        ;;
                    \?)
                        echo "Invalid argument: -${OPTARG:-}"
                        print_help
                        ;;
                    :)
                        echo "-$OPTARG parameter requires an argument."
                        print_help
                        ;;
                esac
                # Otherwise, it's not an option, it's an operand
            else
                path_to_package_to_test="$1"
                shift_value=1
            fi
            # Shift the parameter and its argument
            shift "$shift_value"
        done
    }

    # Call parse_arg and pass the modified list of args as a array of arguments.
    parse_arg "${getopts_built_arg[@]}"
}

arguments=("$@")
parse_args

#=================================================
# Cleanup / force-stop
#=================================================

function cleanup()
{
    trap '' SIGINT # Disable ctrl+c in this function
    LXC_RESET

    [ -n "$TEST_CONTEXT" ] && rm -rf "$TEST_CONTEXT"
    [ -n "$lock_file" ] && rm -f "$lock_file"
}

if [[ $force_stop == 1 ]]
then
    package_check_pid="$(cut -d: -f3 "$lock_file")"
    if [ -n "$package_check_pid" ]; then
        kill -15 "$package_check_pid"
    fi
    cleanup
    exit 0
fi

#=================================================
# Check if the lock file exist
#=================================================

# If the lock file exist and corresponding process still exists
if test -e "$lock_file" && ps --pid "$(cut -d: -f3 "$lock_file")" | grep --quiet "$(cut -d: -f3 "$lock_file")"
then
    if [ $interactive -eq 1 ]; then
        echo "The lock file $lock_file already exists."
        read -r -p "Do you want to continue anyway? (y/n) : " answer
    else
        log_critical "The lock file $lock_file already exists. Package check won't continue."
    fi
    # Set the answer at lowercase only
    answer=${answer,,}
    if [ "${answer:0:1}" != "y" ]
    then
        log_critical "Package check cancelled"
    fi
fi
# Create the lock file
# $$ is the PID of package_check itself.
echo "start:$(date +%s):$$" > "$lock_file"

#==========================
# Cleanup
# N.B. the traps are added AFTER the lock is taken
# because we don't want to mess with the lock and LXC
# it we ain't the process with the lock...
#==========================

trap cleanup EXIT
trap 'exit 2' TERM

#==========================
# Main code
#==========================

assert_we_are_connected_to_the_internets
assert_we_have_all_dependencies

if [[ $rebuild == 1 ]]
then
    rebuild_base_lxc 2>&1 | tee -a "./build_base_lxc.log"
    exit 0
fi

self_upgrade
fetch_or_upgrade_package_linter

if [[ -z "${TEST_CONTEXT:-}" ]]; then
    if [[ -n "$storage_dir" ]]; then
        TEST_CONTEXT=$(mktemp -d "$storage_dir/package_check.XXXXXX")
    else
        TEST_CONTEXT=$(mktemp -d "/tmp/package_check.XXXXXX")
    fi
fi
readonly TEST_CONTEXT

fetch_package_to_test "$path_to_package_to_test"
run_all_tests

exit 0
