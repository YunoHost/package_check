#!/bin/bash

cd $(dirname $(realpath $0))
source "./lib/common.sh"
source "./lib/tests_coordination.sh"
source "./lib/build_base_lxc.sh"

print_help() {
    cat << EOF
 Usage: package_check.sh [OPTION]... PACKAGE_TO_CHECK

    -b, --branch=BRANCH  Specify a branch to check.
    -i, --interactive    Wait for the user to continue before each remove.
    -r, --rebuild        (Re)Build the base container
                         (N.B.: you're not supposed to use this option, images
                         are supposed to be fetch from devbaseimgs.yunohost.org automatically)
    -h, --help           Display this help
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
interactive=0
rebuild=0

function parse_args() {

    local getopts_built_arg=()

    # Read the array value per value
    for i in `seq 0 $(( ${#arguments[@]} -1 ))`
    do
        if [[ "${arguments[$i]}" =~ "--branch=" ]]
        then
            getopts_built_arg+=(-b)
            arguments[$i]=${arguments[$i]//--branch=/}
        fi
        # For each argument in the array, reduce to short argument for getopts
        arguments[$i]=${arguments[$i]//--interactive/-i}
        arguments[$i]=${arguments[$i]//--rebuild/-r}
        arguments[$i]=${arguments[$i]//--help/-h}
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
                    i)
                        # --interactive
                        interactive=1
                        shift_value=1
                        ;;
                    r)
                        # --rebuild
                        rebuild=1
                        shift_value=1
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
            shift $shift_value
        done
    }

    # Call parse_arg and pass the modified list of args as a array of arguments.
    parse_arg "${getopts_built_arg[@]}"
}

arguments=("$@")
parse_args

#=================================================
# Pick up the package
#=================================================

FETCH_PACKAGE_TO_TEST() {

    local path_to_package_to_test="$1"

    # If the url is on a specific branch, extract the branch
    if echo "$path_to_package_to_test" | grep -Eq "https?:\/\/.*\/tree\/"
    then
        gitbranch="-b ${path_to_package_to_test##*/tree/}"
        path_to_package_to_test="${path_to_package_to_test%%/tree/*}"
    fi

    log_info "Testing the package $path_to_package_to_test"
    [ -n "$gitbranch" ] && log_info " on the branch ${gitbranch##-b }"

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
        # Clone the repository
        git clone --quiet $path_to_package_to_test $gitbranch "$package_path"

        # If it's a local directory
    else
        # Do a copy in the directory of Package check
        cp -a "$path_to_package_to_test" "$package_path"
    fi

    # Check if the package directory is really here.
    if [ ! -d "$package_path" ]; then
        log_critical "Unable to find the directory $package_path for the package..."
    fi
}

#=================================================
# Check if the lock file exist
#=================================================

if test -e "$lock_file"
then
    # If the lock file exist
    echo "The lock file $lock_file is present. Package check would not continue."
    if [ $interactive -eq 1 ]; then
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

###################################
# Main code
###################################

assert_we_are_connected_to_the_internets
assert_we_have_all_dependencies

if [[ $rebuild == 0 ]]
then
    rebuild_base_lxc 2>&1 | tee -a "./build_base_lxc.log"
    clean_exit 0
fi

#self_upgrade # FIXME renenable this later
fetch_or_upgrade_package_linter

TEST_CONTEXT=$(mktemp -d /tmp/package_check.XXXXXX)

FETCH_PACKAGE_TO_TEST $path_to_package_to_test
readonly app_id="$(cat $package_path/manifest.json | jq -r .id)"

run_all_tests

clean_exit 0
