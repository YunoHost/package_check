# #!/bin/bash

echo -e "Loads functions from launcher.sh"

#=================================================
# Globals variables
#=================================================

arg_ssh="-tt"
snapshot_path="/var/lib/lxcsnaps/$lxc_name"
current_snapshot=snap0

#=================================================
# TIMER
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

	if [ $1 -eq 2 ]; then
		ECHO_FORMAT "Working time for this test: " "blue"
	elif [ $1 -eq 3 ]; then
		ECHO_FORMAT "Global working time for all tests: " "blue"
	else
		ECHO_FORMAT "Working time: " "blue"
	fi
	ECHO_FORMAT "${phours}${pminutes}${pseconds}.\n" "blue"
}

#=================================================
# RUNNING SNAPSHOT
#=================================================

create_temp_backup () {
	# Create a temporary snapshot

	# snap1 for subpath or snap2 for root install
	snap_number=$1

	start_timer
	# Check all the witness files, to verify if them still here
	check_witness_files >&2

	# Stop the container, before its snapshot
	sudo lxc-stop --name $lxc_name >&2

	# Remove swap files to avoid killing the CI with huge snapshots.
	local swap_file="/var/lib/lxc/$lxc_name/rootfs/swap_$ynh_app_id"
	if sudo test -e "$swap_file"
	then
		sudo swapoff "$swap_file"
		sudo rm "$swap_file"
	fi

	# Check if the snapshot already exist
	if [ ! -e "$snapshot_path/snap$snap_number" ]
	then
		echo "snap$snap_number doesn't exist, its first creation can takes a little while." >&2
		# Create the snapshot.
		sudo lxc-snapshot --name $lxc_name >> "$test_result" 2>&1

		# lxc always creates the first snapshot it can creates.
		# So if snap1 doesn't exist and you try to create snap2, it will be named snap1.
		if [ "$snap_number" == "2" ] && [ ! -e "$snapshot_path/snap2" ]
		then
			# Rename snap1 to snap2
			sudo mv "$snapshot_path/snap1" "$snapshot_path/snap2"
		fi
	fi

	# Update the snapshot with rsync to clone the current lxc state
	sudo rsync --acls --archive --delete --executability --itemize-changes --xattrs "/var/lib/lxc/$lxc_name/rootfs/" "$snapshot_path/snap$snap_number/rootfs/" > /dev/null 2>> "$test_result"

	# Set this snapshot as the current snapshot
	current_snapshot=snap$snap_number

	stop_timer 1 >&2

	# Restart the container, after the snapshot
	LXC_START "true" >&2
}

use_temp_snapshot () {
	# Use a temporary snapshot, if it already exists
	# $1 = Name of the snapshot to use
	current_snapshot=$1

	start_timer
	# Fix the missing hostname in the hosts file...
	echo "127.0.0.1 $lxc_name" | sudo tee --append "$snapshot_path/$current_snapshot/rootfs/etc/hosts" > /dev/null

	# Restore this snapshot.
	sudo rsync --acls --archive --delete --executability --itemize-changes --xattrs "$snapshot_path/$current_snapshot/rootfs/" "/var/lib/lxc/$lxc_name/rootfs/" > /dev/null 2>> "$test_result"

	stop_timer 1

	# Retrieve the app id in the log. To manage the app after
	ynh_app_id=$(sudo tac "$yunohost_log" | grep --only-matching --max-count=1 "YNH_APP_INSTANCE_NAME=[^ ]*" | cut --delimiter='=' --fields=2)

	# Fake the yunohost_result return code of the installation
	yunohost_result=0
}

#=================================================

is_lxc_running () {
	sudo lxc-info --name=$lxc_name | grep --quiet "RUNNING"
}

LXC_INIT () {
	# Clean previous remaining swap files
	sudo swapoff /var/lib/lxc/$lxc_name/rootfs/swap_* 2>/dev/null
	sudo rm --force /var/lib/lxc/$lxc_name/rootfs/swap_*
	sudo swapoff /var/lib/lxcsnaps/$lxc_name/snap0/rootfs/swap_* 2>/dev/null
	sudo rm --force /var/lib/lxcsnaps/$lxc_name/snap0/rootfs/swap_*
	sudo swapoff /var/lib/lxcsnaps/$lxc_name/snap1/rootfs/swap_* 2>/dev/null
	sudo rm --force /var/lib/lxcsnaps/$lxc_name/snap1/rootfs/swap_*
	sudo swapoff /var/lib/lxcsnaps/$lxc_name/snap2/rootfs/swap_* 2>/dev/null
	sudo rm --force /var/lib/lxcsnaps/$lxc_name/snap2/rootfs/swap_*

	# Initialize LXC network

	# Activate the bridge
	echo "Initialize network for LXC."
	sudo ifup $lxc_bridge --interfaces=/etc/network/interfaces.d/$lxc_bridge | tee --append "$test_result" 2>&1

	# Activate iptables rules
	echo "Activate iptables rules."
	sudo iptables --append FORWARD --in-interface $lxc_bridge --out-interface $main_iface --jump ACCEPT | tee --append "$test_result" 2>&1
	sudo iptables --append FORWARD --in-interface $main_iface --out-interface $lxc_bridge --jump ACCEPT | tee --append "$test_result" 2>&1
	sudo iptables --table nat --append POSTROUTING --source $ip_range.0/24 --jump MASQUERADE | tee --append "$test_result" 2>&1
}

LXC_START () {
	# Start the lxc container and execute the given command in it
	# $1 = Command to execute in the container

	start_timer
	# Try to start the container 3 times.
	local max_try=3
	local i=0
	while [ $i -lt $max_try ]
	do
		i=$(( $i +1 ))
		# Start the container and log the booting process in $script_dir/lxc_boot.log
		# Try to start only if the container is not already started
		if ! is_lxc_running; then
			echo -n "Start the LXC container" | tee --append "$test_result"
			sudo lxc-start --name=$lxc_name --daemon --logfile "$script_dir/lxc_boot.log" | tee --append "$test_result" 2>&1
			local avoid_witness=0
		else
			echo -n "A LXC container is already running" | tee --append "$test_result"
			local avoid_witness=1
		fi

		# Try to connect 5 times
		local j=0
		for j in `seq 1 5`
		do
			echo -n .
			# Try to connect with ssh to check if the container is ready to work.
			if ssh $arg_ssh -o ConnectTimeout=10 $lxc_name "exit 0" > /dev/null 2>&1; then
				# Break the for loop if the container is ready.
				break
			fi
			sleep 1
		done
		echo ""
		if [ "$(uname -m)" == "aarch64" ]
		then
			sleep 30
		fi
		
		local failstart=0
		# Check if the container is running
		if ! is_lxc_running; then
			ECHO_FORMAT "The LXC container didn't start...\n" "red" "bold"
			failstart=1
			if [ $i -ne $max_try ]; then
				ECHO_FORMAT "Rebooting the container...\n" "red" "bold"
			fi
			LXC_STOP	# Stop the LXC container
		elif ! ssh $arg_ssh -o ConnectTimeout=60 $lxc_name "sudo ping -q -c 2 security.debian.org > /dev/null 2>&1; exit \$?" >> "$test_result" 2>&1
		then
			# Try to ping security.debian.org to check the connectivity from the container
			ECHO_FORMAT "The container failed to connect to internet...\n" "red" "bold"
			failstart=1
			if [ $i -ne $max_try ]; then
				ECHO_FORMAT "Rebooting the container...\n" "red" "bold"
			fi
			LXC_STOP	# Stop the LXC container
		else
			# Create files to check if the remove script does not remove them accidentally
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
					ci_path=$(grep "CI_URL=" "$script_dir/../config" | cut -d= -f2)
					local subject="[YunoHost] Container in trouble on $ci_path."
					local message="The container failed to start $max_try times on $ci_path.
$lxc_check_result

Please have a look to the log of lxc_check:
$(cat "$script_dir/lxc_check.log")"
					if [ $lxc_check -eq 2 ]; then
						# Add the log of lxc_build
						message="$message

Here the log of lxc_build:
$(cat "$script_dir/sub_scripts/Build_lxc.log")"
					fi

					dest=$(grep 'dest=' "$script_dir/../config" | cut -d= -f2)
					mail -s "$subject" "$dest" <<< "$message"
				fi
			}

			ECHO_FORMAT "The container failed to start $max_try times...\n" "red" "bold"
			ECHO_FORMAT "Boot log:\n" clog
			cat "$script_dir/lxc_boot.log" | tee --append "$test_result"
			ECHO_FORMAT "lxc_check will try to fix the container...\n" "red" "bold"
			$script_dir/sub_scripts/lxc_check.sh --no-lock | tee "$script_dir/lxc_check.log"
			# PIPESTATUS is an array with the exit code of each command followed by a pipe
			local lxc_check=${PIPESTATUS[0]}
			LXC_INIT
			if [ $lxc_check -eq 0 ]; then
				local lxc_check_result="The container seems to be ok, according to lxc_check."
				ECHO_FORMAT "$lxc_check_result\n" "lgreen" "bold"
				send_email
				i=0
			elif [ $lxc_check -eq 1 ]; then
				local lxc_check_result="An error has happened with the host. Please check the configuration."
				ECHO_FORMAT "$lxc_check_result\n" "red" "bold"
				send_email
				stop_timer 1
				return 1
			elif [ $lxc_check -eq 2 ]; then
				local lxc_check_result="The container is broken, it will be rebuilt."
				ECHO_FORMAT "$lxc_check_result\n" "red" "bold"
				$script_dir/sub_scripts/lxc_build.sh
				LXC_INIT
				send_email
				i=0
			elif [ $lxc_check -eq 3 ]; then
				local lxc_check_result="The container has been fixed by lxc_check."
				ECHO_FORMAT "$lxc_check_result\n" "lgreen" "bold"
				send_email
				i=0
			fi
		fi
	done
	stop_timer 1
	start_timer

	# Count the number of lines of the current yunohost log file.
	COPY_LOG 1

    # Wait for apt to be available before the test.
    for try in `seq 1 17`
    do
            # Check if /var/lib/dpkg/lock is used by another process
            if sudo lxc-attach -n $lxc_name -- lsof /var/lib/dpkg/lock > /dev/null
            then
                echo "apt is already in use..."
                # Sleep an exponential time at each round
                sleep $(( try * try ))
            fi
    done

	# Copy the package into the container.
	rsync -rq --delete "$package_path" "$lxc_name": >> "$test_result" 2>&1

	# Execute the command given in argument in the container and log its results.
	ssh $arg_ssh $lxc_name "$1 > /dev/null 2>> temp_yunohost-cli.log; exit \$?" >> "$test_result" 2>&1
	# Store the return code of the command
	local returncode=$?

	# Retrieve the log of the previous command and copy its content in the temporary log
	sudo cat "/var/lib/lxc/$lxc_name/rootfs/home/pchecker/temp_yunohost-cli.log" >> "$temp_log"

	stop_timer 1
	# Return the exit code of the ssh command
	return $returncode
}

LXC_STOP () {
	# Stop and restore the LXC container

	start_timer
	# Stop the LXC container
	if is_lxc_running; then
		echo "Stop the LXC container" | tee --append "$test_result"
		sudo lxc-stop --name=$lxc_name | tee --append "$test_result" 2>&1
	fi

	# Fix the missing hostname in the hosts file
	# If the hostname is missing in /etc/hosts inside the snapshot
	if ! sudo grep --quiet "$lxc_name" "$snapshot_path/$current_snapshot/rootfs/etc/hosts"
	then
		# If the hostname was replaced by name of the snapshot, fix it
		if sudo grep --quiet "$current_snapshot" "$snapshot_path/$current_snapshot/rootfs/etc/hosts"
		then
			# Replace snapX by the real hostname
			sudo sed --in-place "s/$current_snapshot/$lxc_name/" "$snapshot_path/$current_snapshot/rootfs/etc/hosts"
		else
			# Otherwise, simply add the hostname
			echo "127.0.0.1 $lxc_name" | sudo tee --append "$snapshot_path/$current_snapshot/rootfs/etc/hosts" > /dev/null
		fi
	fi

	# Restore the snapshot.
	echo "Restore the previous snapshot." | tee --append "$test_result"
	sudo rsync --acls --archive --delete --executability --itemize-changes --xattrs "$snapshot_path/$current_snapshot/rootfs/" "/var/lib/lxc/$lxc_name/rootfs/" > /dev/null 2>> "$test_result"
	stop_timer 1
}

LXC_TURNOFF () {
	# Disable LXC network

	echo "Disable iptables rules."
	if sudo iptables --check FORWARD --in-interface $lxc_bridge --out-interface $main_iface --jump ACCEPT 2> /dev/null
	then
		sudo iptables --delete FORWARD --in-interface $lxc_bridge --out-interface $main_iface --jump ACCEPT >> "$test_result" 2>&1
	fi
	if sudo iptables --check FORWARD --in-interface $main_iface --out-interface $lxc_bridge --jump ACCEPT 2> /dev/null
	then
		sudo iptables --delete FORWARD --in-interface $main_iface --out-interface $lxc_bridge --jump ACCEPT | tee --append "$test_result" 2>&1
	fi
	if sudo iptables --table nat --check POSTROUTING --source $ip_range.0/24 --jump MASQUERADE 2> /dev/null
	then
		sudo iptables --table nat --delete POSTROUTING --source $ip_range.0/24 --jump MASQUERADE | tee --append "$test_result" 2>&1
	fi

	echo "Disable the network bridge."
	if sudo ifquery $lxc_bridge --state > /dev/null
	then
		sudo ifdown --force $lxc_bridge | tee --append "$test_result" 2>&1
	fi

	# Set snap0 as the current snapshot
	current_snapshot=snap0
}

LXC_CONNECT_INFO () {
	# Print access information

	echo "> To access the container:"
	echo "To execute one command:"
	echo -e "\e[1msudo lxc-attach -n $lxc_name -- command\e[0m"

	echo "To establish a ssh connection:"
	if [ $(cat "$script_dir/sub_scripts/setup_user") = "root" ]; then
		echo -ne "\e[1msudo "
	fi
	echo -e "\e[1mssh $arg_ssh $lxc_name\e[0m"
}
