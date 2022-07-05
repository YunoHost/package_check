#!/bin/bash

#=================================================
# RUNNING SNAPSHOT
#=================================================

LXC_CREATE () {
    log_info "Launching new LXC $LXC_NAME ..."
    # Check if we can launch container from yunohost remote image
    if lxc remote list | grep -q "yunohost" && lxc image list yunohost:$LXC_BASE | grep -q -w $LXC_BASE; then
        lxc launch yunohost:$LXC_BASE $LXC_NAME \
            -c security.nesting=true \
            -c security.privileged=true \
            -c limits.memory=80% \
            -c limits.cpu.allowance=80% \
            >>/proc/self/fd/3
    # Check if we can launch container from a local image
    elif lxc image list $LXC_BASE | grep -q -w $LXC_BASE; then
        lxc launch $LXC_BASE $LXC_NAME \
            -c security.nesting=true \
            -c security.privileged=true \
            -c limits.memory=80% \
            -c limits.cpu.allowance=80% \
            >>/proc/self/fd/3
    else
        log_critical "Can't find base image $LXC_BASE, run ./package_check.sh --rebuild"
    fi
    
    pipestatus="${PIPESTATUS[0]}"
    location=$(lxc list --format json | jq -e --arg LXC_NAME $LXC_NAME '.[] | select(.name==$LXC_NAME) | .location' | tr -d '"')
    [[ "$location" != "none" ]] && log_info "... on $location"

    [[ "$pipestatus" -eq 0 ]] || exit 1

    _LXC_START_AND_WAIT $LXC_NAME
    set_witness_files
    lxc snapshot $LXC_NAME snap0
}

LXC_SNAPSHOT_EXISTS() {
    local snapname=$1
    lxc list --format json \
        | jq -e --arg LXC_NAME $LXC_NAME --arg snapname $snapname \
        '.[] | select(.name==$LXC_NAME) | .snapshots[] | select(.name==$snapname)' \
            >/dev/null
}

CREATE_LXC_SNAPSHOT () {
    # Create a temporary snapshot

    local snapname=$1

    start_timer

    # Check all the witness files, to verify if them still here
    check_witness_files >&2

    # Remove swap files to avoid killing the CI with huge snapshots.
    CLEAN_SWAPFILES
    
    LXC_STOP $LXC_NAME

    # Check if the snapshot already exist
    if ! LXC_SNAPSHOT_EXISTS "$snapname"
    then
        log_info "(Creating snapshot $snapname ...)"
        lxc snapshot $LXC_NAME $snapname
    fi

    _LXC_START_AND_WAIT $LXC_NAME

    stop_timer 1
}

LOAD_LXC_SNAPSHOT () {
    local snapname=$1
    log_debug "Loading snapshot $snapname ..."

    # Remove swap files before restoring the snapshot.
    CLEAN_SWAPFILES

    LXC_STOP $LXC_NAME

    lxc restore $LXC_NAME $snapname
    lxc start $LXC_NAME
    _LXC_START_AND_WAIT $LXC_NAME
}

#=================================================

LXC_EXEC () {
    # Start the lxc container and execute the given command in it
    local cmd=$1

    _LXC_START_AND_WAIT $LXC_NAME

    start_timer

    # Execute the command given in argument in the container and log its results.
    lxc exec $LXC_NAME --env PACKAGE_CHECK_EXEC=1 -t -- /bin/bash -c "$cmd" | tee -a "$complete_log" $current_test_log

    # Store the return code of the command
    local returncode=${PIPESTATUS[0]}

    log_debug "Return code: $returncode"

    stop_timer 1
    # Return the exit code of the ssh command
    return $returncode
}

LXC_STOP () {
    local container_to_stop=$1
    # (We also use timeout 30 in front of the command because sometime lxc
    # commands can hang forever despite the --timeout >_>...)
    timeout 30 lxc stop --timeout 15 $container_to_stop 2>/dev/null

    # If the command times out, then add the option --force
    if [ $? -eq 124 ]; then
        timeout 30 lxc stop --timeout 15 $container_to_stop --force 2>/dev/null
    fi

}

LXC_RESET () {
    # If the container exists
    if lxc info $LXC_NAME >/dev/null 2>/dev/null; then
        # Remove swap files before deletting the continer
        CLEAN_SWAPFILES
    fi 

    LXC_STOP $LXC_NAME

    local current_storage=$(lxc list $LXC_NAME --format json --columns b | jq '.[].expanded_devices.root.pool')
    swapoff "$(lxc storage get $current_storage source)/containers/$LXC_NAME/rootfs/swap" 2>/dev/null

    lxc delete $LXC_NAME --force 2>/dev/null
}


_LXC_START_AND_WAIT() {

	restart_container()
	{
        LXC_STOP $1
		lxc start "$1"
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
			if lxc exec "$1" -- systemctl isolate multi-user.target >/dev/null 2>/dev/null; then
				break
			fi

			if [ "$j" == "10" ]; then
				log_debug 'Failed to start the container ... restarting ...'
				failstart=1

				restart_container "$1"
			fi

			sleep 1s
		done

		# Wait for container to access the internet
		for j in $(seq 1 10); do
			if lxc exec "$1" -- curl -s http://wikipedia.org > /dev/null 2>/dev/null; then
				break
			fi

			if [ "$j" == "10" ]; then
				log_debug 'Failed to access the internet ... restarting'
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
            log_error "The container miserably failed to start or to connect to the internet"
            lxc info --show-log $1
			return 1
		fi
	done

    LXC_IP=$(lxc exec $1 -- hostname -I | grep -E -o "\<[0-9.]{8,}\>")
}

CLEAN_SWAPFILES() {
    # Restart it if needed
    if [ "$(lxc info $LXC_NAME | grep Status | awk '{print tolower($2)}')" != "running" ]; then
        lxc start $LXC_NAME
        _LXC_START_AND_WAIT $LXC_NAME
    fi
    lxc exec $LXC_NAME -- bash -c 'for swapfile in $(ls /swap_* 2>/dev/null); do swapoff $swapfile; done'
    lxc exec $LXC_NAME -- bash -c 'for swapfile in $(ls /swap_* 2>/dev/null); do rm -f $swapfile; done'
}

RUN_INSIDE_LXC() {
    lxc exec $LXC_NAME -- "$@"
}

