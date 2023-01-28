#!/bin/bash

cd $(dirname $(realpath $0))
source "./lib/common.sh"

print_help() {
    cat << EOF
 Usage: setup_lxd.sh [OPTION]...

    -t, --type=TYPE Specify which type of storage to use: ramfs, dir or btrfs
    -s, --size=SIZE The storage size allocated to ramfs (5G, 10G...)
    -r, --reset     Removes all the storage and disks created with this script. Be careful as instances will be deleted as well
    -h, --help                  Display this help
EOF
exit 0
}


#=================================================
# Pase CLI arguments
#=================================================

# If no arguments provided
# Print the help and exit
[ "$#" -eq 0 ] && print_help

type="dir"
size="10G"
reset=0

function parse_args() {

    local getopts_built_arg=()

    # Read the array value per value
    for i in $(seq 0 $(( ${#arguments[@]} -1 )))
    do
           if [[ "${arguments[$i]}" =~ "--type=" ]]
           then
               getopts_built_arg+=(-t)
               arguments[$i]=${arguments[$i]//--type=/}
           fi
           if [[ "${arguments[$i]}" =~ "--size=" ]]
           then
               getopts_built_arg+=(-s)
               arguments[$i]=${arguments[$i]//--size=/}
           fi
     # For each argument in the array, reduce to short argument for getopts
        arguments[$i]=${arguments[$i]//--reset/-r}
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
                getopts "t:s:r" parameter || true
                case $parameter in
                    t)
                        # --type
                        type=$OPTARG
                        shift_value=2
                        ;;
                    s)
                        # --size
                        size=$OPTARG
                        shift_value=2
                        ;;
                    r)
                        # --reset
                        reset=1
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
#            else
#                path_to_package_to_test="$1"
#                shift_value=1
            fi
            # Shift the parameter and its argument
            shift $shift_value
        done
    }

    # Call parse_arg and pass the modified list of args as a array of arguments.
    parse_arg "${getopts_built_arg[@]}"
}

function create_lxd_profile () {
      if [[ $(lxc profile list --format=compact) == *"$profile_name"* ]]
      then
        lxc profile delete $profile_name
      fi
      lxc profile create $profile_name
      lxc profile device add $profile_name root disk path=/ pool=$profile_name
      lxc profile device add $profile_name eth0 nic name=eth0 network=lxdbr0
      echo "You can use the profile $profile_name (--profile $profile_name) when running package_check.sh"
}

# Create the asked storage
function create_storage() {
  case $type in
    dir)
      echo "Creating dir storage for package_check"
      if [[ $(lxc storage list --format=compact) != *"yunohost_dir"* ]]
      then
        lxc storage create yunohost_dir dir
      fi
      profile_name=yunohost_dir
      create_lxd_profile
      ;;
    ramfs)
      echo "Creating RamFS storage"

      if [[ $(lxc profile list --format=compact) == *"yunohost_ramfs"* ]]
      then
        lxc profile delete yunohost_ramfs
      fi

      if [[ $(lxc storage list --format=compact) == *"yunohost_ramfs"* ]]
      then
        lxc storage delete yunohost_ramfs
      fi

      if [[ -e /tmp/yunohost_ramfs ]]
      then
        sudo umount /tmp/yunohost_ramfs
        sudo rm -rf /tmp/yunohost_ramfs
      fi

      sudo mkdir --parents /tmp/yunohost_ramfs
      sudo mount -t tmpfs -o size=$size tmpfs /tmp/yunohost_ramfs

      lxc storage create yunohost_ramfs dir source=/tmp/yunohost_ramfs

      profile_name=yunohost_ramfs
      create_lxd_profile
      ;;
    btrfs)
      echo "Creating btrfs storage for package_check"
      if [[ $(lxc storage list --format=compact) != *"yunohost_btrfs"* ]]
      then
        lxc storage create yunohost_btrfs btrfs
      fi

      profile_name=yunohost_btrfs
      create_lxd_profile
      ;;
  esac
}

# Removes all the storage that has been created by this script
function remove_all_storage() {
  for name in "${LXC_PROFILE_LIST[@]}"
  do
      if [[ $(lxc profile list --format=compact) == *"$name"* ]]
      then
        lxc profile delete $name
      fi
      if [[ $(lxc storage list --format=compact) == *"$name"* ]]
      then
        lxc storage delete $name
      fi
  done

  if [[ -e /tmp/yunohost_ramfs ]]
  then
    sudo umount /tmp/yunohost_ramfs
    sudo rm -rf /tmp/yunohost_ramfs
  fi
}

arguments=("$@")
parse_args

#==========================
# Main code
#==========================

assert_we_are_connected_to_the_internets
assert_we_have_all_dependencies

if [[ $reset == 1 ]]
then
    remove_all_storage
    exit 0
fi

create_storage


exit 0

}
