# #!/bin/bash

#=================================================
# RUNNING SNAPSHOT
#=================================================

LXC_CREATE () {
    sudo lxc launch $LXC_NAME-base $LXC_NAME || exit 1
    sudo lxc config set "$LXC_NAME" security.nesting true
    _LXC_START_AND_WAIT $LXC_NAME
    set_witness_files
    sudo lxc snapshot $LXC_NAME snap0
}

LXC_SNAPSHOT_EXISTS() {
    lxc info $LXC_NAME 2>/dev/null | grep -A10 Snapshots | tail -n -1 | awk '{print $1}' | grep -q -w "$1"
}

CREATE_LXC_SNAPSHOT () {
    # Create a temporary snapshot

    local snapname=$1

    start_timer

    # Check all the witness files, to verify if them still here
    check_witness_files >&2

    # Remove swap files to avoid killing the CI with huge snapshots.
    sudo lxc exec $LXC_NAME -- bash -c 'for swapfile in $(ls /swap_* 2>/dev/null); do swapoff $swapfile; done'
    sudo lxc exec $LXC_NAME -- bash -c 'for swapfile in $(ls /swap_* 2>/dev/null); do rm -f $swapfile; done'
    
    sudo lxc stop --timeout 15 $LXC_NAME 2>/dev/null

    # Check if the snapshot already exist
    if ! LXC_SNAPSHOT_EXISTS "$snapname"
    then
        log_debug "$snapname doesn't exist, its first creation can takes a little while." >&2
        sudo lxc snapshot $LXC_NAME $snapname
    fi

    stop_timer 1
}

LOAD_LXC_SNAPSHOT () {
    snapname=$1
    sudo lxc stop --timeout 15 $LXC_NAME 2>/dev/null
    sudo lxc restore $LXC_NAME $snapname
    sudo lxc start $LXC_NAME
    _LXC_START_AND_WAIT $LXC_NAME
}

#=================================================

LXC_START () {
    # Start the lxc container and execute the given command in it
    local cmd=$1

    _LXC_START_AND_WAIT $LXC_NAME

    start_timer

    # Copy the package into the container.
    lxc exec $LXC_NAME -- rm -rf /app_folder
    lxc file push -p -r "$package_path" $LXC_NAME/app_folder --quiet

    # Execute the command given in argument in the container and log its results.
    lxc exec $LXC_NAME --env PACKAGE_CHECK_EXEC=1 -t -- $cmd | tee -a "$complete_log"

    # Store the return code of the command
    local returncode=${PIPESTATUS[0]}

    log_debug "Return code: $return_code"

    stop_timer 1
    # Return the exit code of the ssh command
    return $returncode
}

LXC_STOP () {
    sudo lxc stop --timeout 15 $LXC_NAME 2>/dev/null
}

LXC_RESET () {
    sudo lxc stop --timeout 15 $LXC_NAME 2>/dev/null
    sudo lxc delete $LXC_NAME 2>/dev/null
}


_LXC_START_AND_WAIT() {

	restart_container()
	{
		sudo lxc stop "$1"
		sudo lxc start "$1"
	}

	# Try to start the container 3 times.
	local max_try=3
	local i=0
	while [ $i -lt $max_try ]
	do
		i=$(( i +1 ))
		local failstart=0

		# Wait for container to start, we are using systemd to check this,
		# for the sake of brevity.
		for j in $(seq 1 10); do
			if lxc exec "$1" -- /bin/bash -c "systemctl isolate multi-user.target" >/dev/null 2>/dev/null; then
				break
			fi

			if [ "$j" == "10" ]; then
				log_error 'Failed to start the container'
                lxc info --show-log $1
				failstart=1

				restart_container "$1"
			fi

			sleep 1s
		done

		# Wait for container to access the internet
		for j in $(seq 1 10); do
			if lxc exec "$1" -- /bin/bash -c "! which wget > /dev/null 2>&1 || wget -q --spider http://debian.org"; then
				break
			fi

			if [ "$j" == "10" ]; then
				log_error 'Failed to access the internet'
				failstart=1

				restart_container "$1"
			fi

			sleep 1s
		done

		# Has started and has access to the internet
		if [ $failstart -eq 0 ]
		then
			break
		fi

		# Fail if the container failed to start
		if [ $i -eq $max_try ] && [ $failstart -eq 1 ]
		then
			return 1
		fi
	done

    LXC_IP=$(lxc exec $1 -- hostname -I | grep -E -o "\<[0-9.]{8,}\>")
}


RUN_INSIDE_LXC() {
    sudo lxc exec $LXC_NAME -- $@
}


