# #!/bin/bash

#=================================================
# Globals variables
#=================================================

# -q aims to disable the display of 'Debian GNU/Linux' each time a command is ran
arg_ssh="-tt -q"

#=================================================
# RUNNING SNAPSHOT
#=================================================

CREATE_LXC_SNAPSHOT () {
    # Create a temporary snapshot

    local snapname=$1

    start_timer
    # Check all the witness files, to verify if them still here
    check_witness_files >&2

    # Stop the container, before its snapshot
    sudo lxc-stop --name $LXC_NAME >&2

    # Remove swap files to avoid killing the CI with huge snapshots.
    local swap_file="$LXC_ROOTFS/swap_$app_id"
    if sudo test -e "$swap_file"
    then
        sudo swapoff "$swap_file"
        sudo rm "$swap_file"
    fi

    # Check if the snapshot already exist
    if [ ! -e "$LXC_SNAPSHOTS/$snapname" ]
    then
        log_debug "$snapname doesn't exist, its first creation can takes a little while." >&2
        # Create the snapshot.
        sudo lxc-snapshot --name $LXC_NAME >> "$complete_log" 2>&1

        # lxc always creates the first snapshot it can creates.
        # So if snap1 doesn't exist and you try to create snap_foo, it will be named snap1.
        if [ "$snapname" != "snap1" ] && [ ! -e "$LXC_SNAPSHOTS/$snapname" ]
        then
            # Rename snap1
            sudo mv "$LXC_SNAPSHOTS/snap1" "$LXC_SNAPSHOTS/$snapname"
        fi
    fi

    # Update the snapshot with rsync to clone the current lxc state
    sudo rsync --acls --archive --delete --executability --itemize-changes --xattrs "$LXC_ROOTFS/" "$LXC_SNAPSHOTS/$snapname/rootfs/" > /dev/null 2>> "$complete_log"

    stop_timer 1

    # Restart the container, after the snapshot
    LXC_START "true" >&2
}

LOAD_LXC_SNAPSHOT () {
    # Use a temporary snapshot, if it already exists
    # $1 = Name of the snapshot to use
    local snapshot=$1

    log_debug "Restoring snapshot $snapshot"

    start_timer
    # Fix the missing hostname in the hosts file...
    echo "127.0.0.1 $LXC_NAME" | sudo tee --append "$LXC_SNAPSHOTS/$snapshot/rootfs/etc/hosts" > /dev/null

    # Restore this snapshot.
    sudo rsync --acls --archive --delete --executability --itemize-changes --xattrs "$LXC_SNAPSHOTS/$snapshot/rootfs/" "$LXC_ROOTFS/" > /dev/null 2>> "$complete_log"
    local ret=$?

    stop_timer 1

    return $ret
}

#=================================================

is_lxc_running () {
    sudo lxc-info --name=$LXC_NAME | grep --quiet "RUNNING"
}

LXC_INIT () {
    # Clean previous remaining swap files
    sudo swapoff $LXC_ROOTFS/swap_* 2>/dev/null
    sudo rm --force $LXC_ROOTFS/swap_*
    sudo swapoff $LXC_SNAPSHOTS/snap0/rootfs/swap_* 2>/dev/null
    sudo rm --force $LXC_SNAPSHOTS/snap0/rootfs/swap_*
    sudo swapoff $LXC_SNAPSHOTS/snap_afterinstall/rootfs/swap_* 2>/dev/null
    sudo rm --force $LXC_SNAPSHOTS/snap_afterinstall/rootfs/swap_*

    LXC_PURGE_SNAPSHOTS

    # Initialize LXC network

    # Activate the bridge
    echo "Initialize network for LXC."
    sudo ifup $LXC_BRIDGE --interfaces=/etc/network/interfaces.d/$LXC_BRIDGE | tee --append "$complete_log" 2>&1

    # Activate iptables rules
    echo "Activate iptables rules."
    sudo iptables --append FORWARD --in-interface $LXC_BRIDGE --out-interface $MAIN_NETWORK_INTERFACE --jump ACCEPT | tee --append "$complete_log" 2>&1
    sudo iptables --append FORWARD --in-interface $MAIN_NETWORK_INTERFACE --out-interface $LXC_BRIDGE --jump ACCEPT | tee --append "$complete_log" 2>&1
    sudo iptables --table nat --append POSTROUTING --source $LXC_NETWORK.0/24 --jump MASQUERADE | tee --append "$complete_log" 2>&1
}

LXC_PURGE_SNAPSHOTS() {
    LXC_STOP

    for SNAP in $(sudo ls $LXC_SNAPSHOTS/snap_*install)
    do
        sudo lxc-snapshot -n $LXC_NAME -d $(basename $SNAP)
    done
}

LXC_START () {
    # Start the lxc container and execute the given command in it
    local cmd=$1

    start_timer
    # Try to start the container 3 times.
    local max_try=3
    local i=0
    while [ $i -lt $max_try ]
    do
        i=$(( $i +1 ))
        # Start the container and log the booting process in ./lxc_boot.log
        # Try to start only if the container is not already started
        if ! is_lxc_running; then
            log_debug "Start the LXC container" >> "$complete_log"
            sudo lxc-start --name=$LXC_NAME --daemon --logfile "./lxc_boot.log" | tee --append "$complete_log" 2>&1
            local avoid_witness=0
        else
            log_debug "A LXC container is already running"
            local avoid_witness=1
        fi

        # Try to connect 5 times
        local j=0
        for j in `seq 1 5`
        do
            log_debug "." >> "$complete_log"
            # Try to connect with ssh to check if the container is ready to work.
            if ssh $arg_ssh -o ConnectTimeout=10 $LXC_NAME "exit 0" > /dev/null 2>&1; then
                # Break the for loop if the container is ready.
                break
            fi
            sleep 1
        done

        [ "$(uname -m)" == "aarch64" ] && sleep 30

        local failstart=0

        # Check if the container is running
        if ! is_lxc_running; then
            log_critical "The LXC container didn't start..."
            failstart=1
            if [ $i -ne $max_try ]; then
                log_info "Rebooting the container..."
            fi
            LXC_STOP
            # Try to ping security.debian.org to check the connectivity from the container
        elif ! ssh $arg_ssh -o ConnectTimeout=60 $LXC_NAME "sudo ping -q -c 2 security.debian.org > /dev/null 2>&1; exit \$?" >> "$complete_log" 2>&1
        then
            log_critical "The container failed to connect to internet..."
            failstart=1
            if [ $i -ne $max_try ]; then
                log_info "Rebooting the container..."
            fi
            LXC_STOP
            # Create files to check if the remove script does not remove them accidentally
        else
            [ $avoid_witness -eq 0 ] && set_witness_files

            # Break the for loop if the container is ready.
            break
        fi

        # Fail if the container failed to start
        if [ $i -eq $max_try ] && [ $failstart -eq 1 ]
        then
            send_email () {
                # Send an email only if it's a CI environment
                if [ $type_exec_env -ne 0 ]
                then
                    ci_path=$(grep "CI_URL=" "./../config" | cut -d= -f2)
                    local subject="[YunoHost] Container in trouble on $ci_path."
                    local message="The container failed to start $max_try times on $ci_path.
                    $lxc_check_result

                    Please have a look to the log of lxc_check:
                    $(cat "./lxc_check.log")"
                    if [ $lxc_check -eq 2 ]; then
                        # Add the log of lxc_build
                        message="$message

                        Here the log of lxc_build:
                        $(cat "./sub_scripts/Build_lxc.log")"
                    fi

                    dest=$(grep 'dest=' "./../config" | cut -d= -f2)
                    mail -s "$subject" "$dest" <<< "$message"
                fi
            }

            log_critical "The container failed to start $max_try times..."
            log_info "Boot log:\n"
            cat "./lxc_boot.log" | tee --append "$complete_log"
            log_info "lxc_check will try to fix the container..."
            ./sub_scripts/lxc_check.sh --no-lock | tee "./lxc_check.log"
            # PIPESTATUS is an array with the exit code of each command followed by a pipe
            local lxc_check=${PIPESTATUS[0]}
            LXC_INIT
            if [ $lxc_check -eq 0 ]; then
                local lxc_check_result="The container seems to be ok, according to lxc_check."
                log_success "$lxc_check_result"
                send_email
                i=0
            elif [ $lxc_check -eq 1 ]; then
                local lxc_check_result="An error has happened with the host. Please check the configuration."
                log_critical "$lxc_check_result"
                send_email
                stop_timer 1
                return 1
            elif [ $lxc_check -eq 2 ]; then
                local lxc_check_result="The container is broken, it will be rebuilt."
                log_critical "$lxc_check_result"
                ./sub_scripts/lxc_build.sh
                LXC_INIT
                send_email
                i=0
            elif [ $lxc_check -eq 3 ]; then
                local lxc_check_result="The container has been fixed by lxc_check."
                log_success "$lxc_check_result"
                send_email
                i=0
            fi
        fi
    done
    stop_timer 1
    start_timer

    # Copy the package into the container.
    rsync -rq --delete "$package_path" "$LXC_NAME": >> "$complete_log" 2>&1

    # Execute the command given in argument in the container and log its results.
    ssh $arg_ssh $LXC_NAME "$cmd; exit $?" | tee -a "$complete_log"

    # Store the return code of the command
    local returncode=${PIPESTATUS[0]}

    stop_timer 1
    # Return the exit code of the ssh command
    return $returncode
}

LXC_STOP () {
    if is_lxc_running;
    then
        log_debug "Stop the LXC container"
        sudo lxc-stop --name=$LXC_NAME | tee --append "$complete_log" 2>&1
    fi
}

LOAD_LXC_SNAPSHOT () {
    snapname=$1

    LXC_STOP

    log_debug "Restoring snapshot $snapname"
    sudo rsync --acls --archive --delete --executability --itemize-changes --xattrs "$LXC_SNAPSHOTS/$snapname/rootfs/" "$LXC_ROOTFS/" > /dev/null 2>> "$complete_log"
}

LXC_TURNOFF () {
    # Disable LXC network

    log_debug "Disable iptables rules."
    if sudo iptables --check FORWARD --in-interface $LXC_BRIDGE --out-interface $MAIN_NETWORK_INTERFACE --jump ACCEPT 2> /dev/null
    then
        sudo iptables --delete FORWARD --in-interface $LXC_BRIDGE --out-interface $MAIN_NETWORK_INTERFACE --jump ACCEPT >> "$complete_log" 2>&1
    fi
    if sudo iptables --check FORWARD --in-interface $MAIN_NETWORK_INTERFACE --out-interface $LXC_BRIDGE --jump ACCEPT 2> /dev/null
    then
        sudo iptables --delete FORWARD --in-interface $MAIN_NETWORK_INTERFACE --out-interface $LXC_BRIDGE --jump ACCEPT | tee --append "$complete_log" 2>&1
    fi
    if sudo iptables --table nat --check POSTROUTING --source $LXC_NETWORK.0/24 --jump MASQUERADE 2> /dev/null
    then
        sudo iptables --table nat --delete POSTROUTING --source $LXC_NETWORK.0/24 --jump MASQUERADE | tee --append "$complete_log" 2>&1
    fi

    log_debug "Disable the network bridge."
    if sudo ifquery $LXC_BRIDGE --state > /dev/null
    then
        sudo ifdown --force $LXC_BRIDGE | tee --append "$complete_log" 2>&1
    fi
}
