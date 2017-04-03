# #!/bin/bash

echo -e "Loads functions from launcher.sh"

#=================================================
# Globals variables
#=================================================

arg_ssh="-tt"

#=================================================

is_lxc_running () {
	sudo lxc-info --name=$lxc_name | grep --quiet "RUNNING"
}

LXC_INIT () {
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

	# Try to start the container 3 times.
	local max_try=3
	local i=0
	for i in `seq 1 $max_try`
	do
		# Start the container and log the booting process in $script_dir/lxc_boot.log
		# Try to start only if the container is not already started
		if ! is_lxc_running; then
			echo "Start the LXC container" | tee --append "$test_result"
			sudo lxc-start --name=$lxc_name --daemon --logfile "$script_dir/lxc_boot.log" | tee --append "$test_result" 2>&1
		else
			echo "A LXC container is already running" | tee --append "$test_result"
		fi

		# Check during 20 seconds if the container has finished to start.
		local j=0
		for j in `seq 1 20`
		do
			echo -n .
			# Try to connect with ssh to check if the container is ready to work.
			if ssh $arg_ssh $lxc_name "exit 0" > /dev/null 2>&1; then
				# Break the for loop if the container is ready.
				break
			fi
			sleep 1
		done

		local failstart=0
		# Check if the container is running
		if ! is_lxc_running; then
			ECHO_FORMAT "The LXC container didn't start...\n" "red" "bold"
			failstart=1
			if [ $i -ne $max_try ]; then
				ECHO_FORMAT "Rebooting the container...\n" "red" "bold"
			fi
			LXC_STOP	# Stop the LXC container
		elif ! ssh $arg_ssh $lxc_name "sudo ping -q -c 2 security.debian.org > /dev/null 2>&1; exit \$?" >> "$test_result" 2>&1
		then
			# Try to ping security.debian.org to check the connectivity from the container
			ECHO_FORMAT "The container failed to connect to internet...\n" "red" "bold"
			failstart=1
			if [ $i -ne $max_try ]; then
				ECHO_FORMAT "Rebooting the container...\n" "red" "bold"
			fi
			LXC_STOP	# Stop the LXC container
		else
			# Break the for loop if the container is ready.
			break
		fi

		# Failed if the container failed to start
		if [ $i -eq $max_try ] && [ $failstart -eq 1 ]
		then
			ECHO_FORMAT "The container failed to start $max_try times...\nIf this problem is persistent, try to fix it with lxc_check.sh." "red" "bold"
			ECHO_FORMAT "Boot log:\n" clog
			cat "$script_dir/lxc_boot.log" | tee --append "$test_result"
			return 1
		fi
	done

	# Count the number of line of the current yunohost log file.
	COPY_LOG 1

	# Copy the package into the container.
	scp -rq "$package_path" "$lxc_name": >> "$test_result" 2>&1

	# Execute the command given in argument in the container and log its results.
	ssh $arg_ssh $lxc_name "$1 > /dev/null 2>> temp_yunohost-cli.log; exit \$?" >> "$test_result" 2>&1
	# Store the return code of the command
	local returncode=$?

	# Retrieve the log of the previous command and copy its content in the temporary log
	sudo cat "/var/lib/lxc/$lxc_name/rootfs/home/pchecker/temp_yunohost-cli.log" >> "$temp_log"

	# Return the exit code of the ssh command
	return $returncode
}

LXC_STOP () {
	# Stop and restore the LXC container

	local snapshot_path="/var/lib/lxcsnaps/$lxc_name/snap0"

	# Stop the LXC container
	if is_lxc_running; then
		echo "Stop the LXC container" | tee --append "$test_result"
		sudo lxc-stop --name=$lxc_name | tee --append "$test_result" 2>&1
	fi

	# Fix the missing hostname in the hosts file
	# If the hostname is missing in /etc/hosts inside the snapshot
	if ! sudo grep --quiet "$lxc_name" "$snapshot_path/rootfs/etc/hosts"
	then
		# If the hostname was replaced by snap0, fix it
		if sudo grep --quiet "snap0" "$snapshot_path/rootfs/etc/hosts"
		then
			# Replace snap0 by the real hostname
			sudo sed --in-place "s/snap0/$lxc_name/" "$snapshot_path/rootfs/etc/hosts"
		else
			# Otherwise, simply add the hostname
			echo "127.0.0.1 $lxc_name" | sudo tee --append "$snapshot_path/rootfs/etc/hosts" > /dev/null
		fi
	fi

	# Restore the snapshot.
	echo "Restore the previous snapshot." | tee --append "$test_result"
	sudo rsync --acls --archive --delete --executability --itemize-changes --xattrs "$snapshot_path/rootfs/" "/var/lib/lxc/$lxc_name/rootfs/" > /dev/null 2>> "$test_result"
}

LXC_TURNOFF () {
	# Deactivate LXC network

	echo "Deactivate iptables rules."
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

	echo "Deactivate the network bridge."
	if sudo ifquery $lxc_bridge --state > /dev/null
	then
		sudo ifdown --force $lxc_bridge | tee --append "$test_result" 2>&1
	fi
}

LXC_CONNECT_INFO () {
	# Print access information

	echo "> For access the container:"
	echo "To execute one command:"
	echo -e "\e[1msudo lxc-attach -n $lxc_name -- command\e[0m"

	echo "To establish a ssh connection:"
	if [ $(cat "$script_dir/setup_user") = "root" ]; then
		echo -ne "\e[1msudo "
	fi
	echo -e "\e[1mssh $arg_ssh $lxc_name\e[0m"
}
