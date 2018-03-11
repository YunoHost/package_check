#!/bin/bash

echo -e "Loads functions from testing_process.sh"

#=================================================
# Globals variables
#=================================================

# A complete list of backup hooks is available at /usr/share/yunohost/hooks/backup/
backup_hooks="conf_ssowat data_home conf_ynh_firewall conf_cron"

#=================================================

break_before_continue () {
	# Make a break if auto_remove is set

	if [ $auto_remove -eq 0 ] && [ $bash_mode -ne 1 ]
	then
		LXC_CONNECT_INFO	# Print access information
		read -p "Press a key to delete the application and continue...." < /dev/tty
	fi
}

#=================================================
# Install and remove an app
#=================================================

SETUP_APP () {
	# Install an application in a LXC container

	# Uses the default snapshot
	current_snapshot=snap0

	# Exec the pre-install instruction, if there one
	if [ -n "$pre_install" ]
	then
		ECHO_FORMAT "Pre installation request\n" "white" "bold" clog
		# Start the lxc container
		LXC_START "true"
		# Copy all the instructions into a script
		echo "$pre_install" > "$script_dir/preinstall.sh"
		chmod +x "$script_dir/preinstall.sh"
		# Replace variables
		sed -i "s/\$USER/$test_user/" "$script_dir/preinstall.sh"
		sed -i "s/\$DOMAIN/$main_domain/" "$script_dir/preinstall.sh"
		sed -i "s/\$SUBDOMAIN/$sub_domain/" "$script_dir/preinstall.sh"
		sed -i "s/\$PASSWORD/$yuno_pwd/" "$script_dir/preinstall.sh"
		# Copy the pre-install script into the container.
		scp -rq "$script_dir/preinstall.sh" "$lxc_name":
		# Then execute the script to execute the pre-install commands.
		LXC_START "./preinstall.sh >&2"
		# Print the log to print the results
		ECHO_FORMAT "$(cat "$temp_log")\n" clog
	fi

	# Install the application in a LXC container
	LXC_START "sudo PACKAGE_CHECK_EXEC=1 yunohost --debug app install \"$package_dir\" -a \"$manifest_args_mod\""

	# yunohost_result gets the return code of the installation
	yunohost_result=$?

	# Print the result of the install command
	if [ $yunohost_result -eq 0 ]; then
		ECHO_FORMAT "Installation successful. ($yunohost_result)\n" "white" clog
	else
		ECHO_FORMAT "Installation failed. ($yunohost_result)\n" "white" clog
	fi

	# Check all the witness files, to verify if them still here
	check_witness_files

	# Retrieve the app id in the log. To manage the app after
	ynh_app_id=$(sudo tac "$yunohost_log" | grep --only-matching --max-count=1 "YNH_APP_INSTANCE_NAME=[^ ]*" | cut --delimiter='=' --fields=2)

	# Analyse the log to extract "warning" and "error" lines
	LOG_EXTRACTOR
}

STANDARD_SETUP_APP () {
	# Try to find an existing snapshot for this install, or make an install

	# If it's a root install
	if [ "$check_path" = "/" ]
	then
		# Check if a snapshot already exist for this install
		if [ -z "$root_snapshot" ]
		then
			# Make an installation
			SETUP_APP
		else
			# Or uses an existing snapshot
			ECHO_FORMAT "Uses an existing snapshot for root installation.\n" "white" clog
			use_temp_snapshot $root_snapshot
		fi

	# In case of sub path install, use another snapshot
	else
		# Check if a snapshot already exist for this install
		if [ -z "$subpath_snapshot" ]
		then
			# Make an installation
			SETUP_APP
		else
			# Or uses an existing snapshot
			ECHO_FORMAT "Uses an existing snapshot for sub path installation.\n" "white" clog
			use_temp_snapshot $subpath_snapshot
		fi
	fi
}

REMOVE_APP () {
	# Remove an application

	# Make a break if auto_remove is set
	break_before_continue

	ECHO_FORMAT "\nDeleting...\n" "white" "bold" clog

	# Remove the application from the LXC container
	LXC_START "sudo PACKAGE_CHECK_EXEC=1 yunohost --debug app remove \"$ynh_app_id\""

	# yunohost_remove gets the return code of the deletion
	yunohost_remove=$?

	# Print the result of the remove command
	if [ "$yunohost_remove" -eq 0 ]; then
		ECHO_FORMAT "Deleting successful. ($yunohost_remove)\n" "white" clog
	else
		ECHO_FORMAT "Deleting failed. ($yunohost_remove)\n" "white" clog
	fi

	# Check all the witness files, to verify if them still here
	check_witness_files
}

#=================================================
# Try to access the app by its url
#=================================================

CHECK_URL () {
	# Try to access the app by its url

	if [ $use_curl -eq 1 ]
	then
		ECHO_FORMAT "\nTry to access by url...\n" "white" "bold"

		# Force a skipped_uris if public mode is not set
		if [ "$install_type" != "private" ] && [ "$install_type" != "public" ] && [ -z "$public_arg" ]
		then
			# Add a skipped_uris on / for the app
			LXC_START "sudo yunohost app setting \"$ynh_app_id\" skipped_uris -v \"/\""
			# Regen the config of sso
			LXC_START "sudo yunohost app ssowatconf"
			ECHO_FORMAT "Public access forced by a skipped_uris to check.\n" "lyellow" "bold"
		fi

		# Inform /etc/hosts with the IP of LXC to resolve the domain.
		# This is set only here and not before to prevent to help the app's scripts
		echo -e "$ip_range.2 $main_domain #package_check\n$ip_range.2 $sub_domain #package_check" | sudo tee --append /etc/hosts > /dev/null

		# Try to resolv the domain during 10 seconds maximum.
		local i=0
		for i in `seq 1 10`; do
			curl --location --insecure $check_domain > /dev/null 2>&1
			# If curl return 6, it's an error "Could not resolve host"
			if [ $? -ne 6 ]; then
				# If not, curl is ready to work.
				break
			fi
			echo -n .
			sleep 1
		done

		# curl_error indicate the result of curl test
		curl_error=0
		# 503 Service Unavailable can would have some time to work.
		local http503=0
		# yuno_portal equal 1 if the test fall on the portal
		yuno_portal=0

		# Try to access to the url in 2 times, with a final / and without
		i=1; while [ $i -ne 3 ]
		do

			# First time, try without final /
			if [ $i -eq 1 ]
			then
				# If the last character is /
				if [ "${check_path: -1}" = "/" ]
				then
					# Remove it
					local curl_check_path="${check_path:0:${#check_path}-1}"
				else
					curl_check_path=$check_path
				fi

				# The next loop will try the second test
				i=2
			elif [ $i -eq 2 ]
			then
				# Second time, try with the final /

				# If the last character isn't /
				if [ "${check_path: -1}" != "/" ]
				then
					# Add it
					curl_check_path="$check_path/"
				else
					curl_check_path=$check_path
				fi

				# The next loop will break the while loop
				i=3
			fi

			# Remove the previous curl output
			rm -f "$script_dir/url_output"

			# Call curl to try to access to the url of the app
			curl --location --insecure --silent --show-error --write-out "%{http_code};%{url_effective}\n" $check_domain$curl_check_path --output "$script_dir/url_output" > "$script_dir/curl_print"

			# Analyze the result of curl command
			if [ $? -ne 0 ]
			then
				ECHO_FORMAT "Connection error...\n" "red" "bold"
				curl_error=1
			fi

			# Print informations about the connection
			ECHO_FORMAT "Test url: $check_domain$curl_check_path\n" "white"
			ECHO_FORMAT "Real url: $(cat "$script_dir/curl_print" | cut --delimiter=';' --fields=2)\n" "white"
			local http_code=$(cat "$script_dir/curl_print" | cut -d ';' -f1)
			ECHO_FORMAT "HTTP code: $http_code\n" "white"

			# Analyze the http code
			if [ "${http_code:0:1}" = "0" ] || [ "${http_code:0:1}" = "4" ] || [ "${http_code:0:1}" = "5" ]
			then
				# If the http code is a 0xx 4xx or 5xx, it's an error code.
				curl_error=1

				# 401 is "Unauthorized", so is a answer of the server. So, it works!
				test "${http_code}" = "401" && curl_error=0

				# 503 is Service Unavailable, it's a temporary error.
				if [ "${http_code}" = "503" ]
				then
					curl_error=0
					ECHO_FORMAT "Service temporarily unavailable\n" "lyellow" "bold"
					# 3 successive error are allowed
					http503=$(( http503 + 1 ))
					if [ $http503 -ge 3 ]; then
						# Over 3, it's definitively an error
						curl_error=1
					else
						# Below 3 times, retry.
						# Decrease the value of 'i' to retry the same test
						i=$(( i - 1 ))
						# Wait 1 second to let's some time to the 503 error
						sleep 1
						# And retry immediately
						continue
					fi
				fi

				if [ $curl_error -eq 1 ]; then
					ECHO_FORMAT "The HTTP code show an error.\n" "white" "bold" clog
				fi
			fi

			# Analyze the output of curl
			if [ -e "$script_dir/url_output" ]
			then
				# Print the title of the page
				local url_title=$(grep "<title>" "$script_dir/url_output" | cut --delimiter='>' --fields=2 | cut --delimiter='<' --fields=1)
				ECHO_FORMAT "Title of the page: $url_title\n" "white"

				# Check if the page title is neither the YunoHost portail or default nginx page
				if [ "$url_title" = "YunoHost Portal" ]
				then
					ECHO_FORMAT "The connection attempt fall on the YunoHost portal.\n" "white" "bold" clog
					yuno_portal=1
				else
					yuno_portal=0
					if [ "$url_title" = "Welcome to nginx on Debian!" ]
					then
						# Falling on nginx default page is an error.
						curl_error=1
						ECHO_FORMAT "The connection attempt fall on nginx default page.\n" "white" "bold" clog
					fi

					# Print the first 20 lines of the page
					ECHO_FORMAT "Extract of the page:\n" "white"
					echo -en "\e[37m"	# Write in 'light grey'
					lynx -dump -force_html "$script_dir/url_output" | head --lines 20 | tee --append "$test_result"
					echo -e "\e[0m"

					# Get all the resources for the main page of the app.
					local HTTP_return
					local moved=0
					local ignored=0
					while read HTTP_return
					do
						# Ignore robots.txt and ynhpanel.js. They always redirect to the portal.
						if echo "$HTTP_return" | grep --quiet "$check_domain/robots.txt\|$check_domain/ynhpanel.js"; then
							ECHO_FORMAT "Ressource ignored:" "white"
							ECHO_FORMAT " ${HTTP_return##*http*://}\n"
							ignored=1
						fi

						# If it's the line with the resource to get
						if echo "$HTTP_return" | grep --quiet "^--.*--  http"
						then
							# Get only the resource itself.
							local resource=${HTTP_return##*http*://}

						# Else, if would be the HTTP return code.
						else
							# If the return code is different than 200.
							if ! echo "$HTTP_return" | grep --quiet "200 OK$"
							then
								# Skipped the check of ignored ressources.
								if [ $ignored -eq 1 ]
								then
									ignored=0
									continue
								fi
								# Isolate the http return code.
								http_code="${HTTP_return##*awaiting response... }"
								http_code="${http_code:0:3}"
								# If the return code is 301 or 302, let's check the redirection.
								if echo "$HTTP_return" | grep --quiet "30[12] Moved"
								then
									ECHO_FORMAT "Ressource moved:" "white"
									ECHO_FORMAT " $resource\n"
									moved=1
								else
									ECHO_FORMAT "Resource unreachable (Code $http_code)" "red" "bold"
									ECHO_FORMAT " $resource\n"
# 					 				curl_error=1
									moved=0
								fi
							else
								if [ $moved -eq 1 ]
								then
									if echo "$resource" | grep --quiet "/yunohost/sso/"
									then
										ECHO_FORMAT "The previous resource is redirected to the YunoHost portal\n" "red"
#	 					 				curl_error=1
									fi
								fi
								moved=0
							fi
						fi
					done <<< "$(cd "$package_path"; LC_ALL=C wget --adjust-extension --page-requisites --no-check-certificate $check_domain$curl_check_path 2>&1 | grep "^--.*--  http\|^HTTP request sent")"
					echo ""
				fi
			fi
		done

		# Detect the issue alias_traversal, https://github.com/yandex/gixy/blob/master/docs/en/plugins/aliastraversal.md
		curl --location --insecure --silent $check_domain$check_path../html/index.nginx-debian.html \
			| grep "title" | grep --quiet "Welcome to nginx on Debian" \
			&& ECHO_FORMAT "Issue alias_traversal detected ! Please see here https://github.com/YunoHost/example_ynh/pull/45 to fix that.\n" "red" "bold" && RESULT_alias_traversal=1

		# Remove the entries in /etc/hosts for the test domain
		sudo sed --in-place '/#package_check/d' /etc/hosts
	else
		# If use_curl is set to 0, the url will not tried
		ECHO_FORMAT "Connexion attempt aborted.\n" "white"
		curl_error=0
		yuno_portal=0
	fi
}

#=================================================
# Generic functions for unit tests
#=================================================

unit_test_title () {
	# Print a title for the test
	# $1 = Name of the test

	ECHO_FORMAT "\n\n>> $1 [Test $cur_test/$all_test]\n" "white" "bold" clog

	# Increment the value of the current test
	cur_test=$((cur_test+1))
}

check_manifest_key () {
	# Check if a manifest key is set
	# $1 = manifest key

	if [ -z "${1}_arg" ]
	then
		ECHO_FORMAT "Unable to find a manifest key for '${1,,}' in the check_process file. Impossible to perform this test\n" "red" clog
		return 1
	fi
}

replace_manifest_key () {
	# Replace a generic manifest key by another
	# $1 = Manifest key
	# $2 = Replacement value

	# Build the variable name by concatenate $1 and _arg
	local manifest_key=$(eval echo \$${1}_arg)

	if [ -n "$manifest_key" ]
	then
		manifest_args_mod=$(echo $manifest_args_mod | sed "s@$manifest_key=[^&]*\&@${manifest_key}=${2}\&@")
	fi
}

check_success () {
	ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
}

check_failed () {
	ECHO_FORMAT "--- FAIL ---\n" "red" "bold"
}

check_test_result () {
	# Check the result and print SUCCESS or FAIL

	if [ $yunohost_result -eq 0 ] && [ $curl_error -eq 0 ] && [ $yuno_portal -eq 0 ]
	then
		check_success
		return 0
	else
		check_failed
		return 1
	fi
}

check_test_result_remove () {
	# Check the result of a remove and print SUCCESS or FAIL

	if [ $yunohost_remove -eq 0 ]
	then
		check_success
		return 0
	else
		check_failed
		return 1
	fi
}

is_install_failed () {
	# Check if an install have previously work

	if [ $RESULT_check_sub_dir -eq 1 ]
	then
		# If subdir installation worked.
		echo subdir
	elif [ $RESULT_check_root -eq 1 ] || [ $force_install_ok -eq 1 ]
	then
		# If root installation worked, return root or force_install_ok setted, return root.
		echo root
	else
		ECHO_FORMAT "All installs failed, impossible to perform this test...\n" "red" clog
		return 1
	fi
}

#=================================================
# Unit tests
#=================================================

CHECK_SETUP () {
	# Try to install in a sub path, on root or without url access
	# $1 = install type

	local install_type=$1
	if [ "$install_type" = "subdir" ]; then
		unit_test_title "Installation in a sub path..."
	elif [ "$install_type" = "root" ]; then
		unit_test_title "Installation on the root..."
	else
		unit_test_title "Installation without url access..."
		# Disable the curl test
		use_curl=0
	fi

	# Check if the needed manifest key are set or abort the test
	if [ "$install_type" != "no_url" ]; then
		check_manifest_key "domain" || return
		check_manifest_key "path" || return
	fi

	# Copy original arguments
	local manifest_args_mod="$manifest_arguments"

	# Replace manifest key for the test
	check_domain=$sub_domain
	replace_manifest_key "domain" "$check_domain"
	if [ "$install_type" = "subdir" ]; then
		local check_path=$test_path
	elif [ "$install_type" = "root" ]; then
		local check_path=/
	fi
	replace_manifest_key "path" "$check_path"
	replace_manifest_key "user" "$test_user"
	replace_manifest_key "public" "$public_public_arg"

	# Install the application in a LXC container
	SETUP_APP

	# Try to access the app by its url
	CHECK_URL

	# Check the result and print SUCCESS or FAIL
	if check_test_result
	then	# Success
		RESULT_global_setup=1	# Installation succeed
		local check_result_setup=1	# Installation succeed
	else	# Fail
		# The global success for a installation can't be failed if another installation succeed
		if [ $RESULT_global_setup -ne 1 ]; then
			RESULT_global_setup=-1	# Installation failed
		fi
		local check_result_setup=-1	# Installation failed
	fi

	# Create a snapshot for this installation, to be able to reuse it instead of a new installation.
	# But only if this installation has worked fine
	if [ $check_result_setup -eq 1 ]; then
		if [ "$check_path" = "/" ]
		then
			# Check if a snapshot already exist for a root install
			if [ -z "$root_snapshot" ]
			then
				ECHO_FORMAT "Create a snapshot for root installation.\n" "white" clog
				create_temp_backup 2
				root_snapshot=snap2
			fi
		else
			# Check if a snapshot already exist for a subpath (or no_url) install
			if [ -z "$subpath_snapshot" ]
			then
				# Then create a snapshot
				ECHO_FORMAT "Create a snapshot for sub path installation.\n" "white" clog
				create_temp_backup 1
				subpath_snapshot=snap1
			fi
		fi
	fi

	# Remove the application
	REMOVE_APP

	# Analyse the log to extract "warning" and "error" lines
	LOG_EXTRACTOR

	# Check the result and print SUCCESS or FAIL
	if check_test_result_remove
	then	# Success
		local check_result_remove=1	# Remove in sub path succeed
		RESULT_global_remove=1	# Remove succeed
	else	# Fail
		# The global success for a deletion can't be failed if another remove succeed
		if [ $RESULT_global_remove -ne 1 ]; then
			RESULT_global_remove=-1	# Remove failed
		fi
		local check_result_remove=-1	# Remove in sub path failed
	fi

	# Reinstall the application after the removing
	# Try to resintall only if the first install is a success.
	if [ $check_result_setup -eq 1 ]
	then
		ECHO_FORMAT "\nReinstall the application after a removing.\n" "white" "bold" clog
		
		SETUP_APP

		# Try to access the app by its url
		CHECK_URL

		# Check the result and print SUCCESS or FAIL
		if check_test_result
		then	# Success
			local check_result_setup=1	# Installation succeed
		else	# Fail
			local check_result_setup=-1	# Installation failed
		fi
	fi

	# Fill the correct variable depend on the type of test
	if [ "$install_type" = "subdir" ]
	then
		RESULT_check_sub_dir=$check_result_setup
		RESULT_check_remove_sub_dir=$check_result_remove
	else	# root and no_url
		RESULT_check_root=$check_result_setup
		RESULT_check_remove_root=$check_result_remove
	fi

	# Make a break if auto_remove is set
	break_before_continue
}

CHECK_UPGRADE () {
	# Try the upgrade script

	# Do an upgrade test for each commit in the upgrade list
	while read <&4 commit
	do
		if [ "$commit" == "current" ]
		then
			unit_test_title "Upgrade from the same version..."
		else
			# Get the specific section for this upgrade from the check_process
			extract_section "^; commit=$commit" "^;" "$check_process"
			# Get the name for this upgrade.
			upgrade_name=$(grep "^name=" "$partial_check_process" | cut -d'=' -f2)
			# Or use the commit if there's no name.
			if [ -z "$upgrade_name" ]; then
				unit_test_title "Upgrade from the commit $commit..."
			else
				unit_test_title "Upgrade from $upgrade_name..."
			fi
		fi

		# Check if an install have previously work
		local previous_install=$(is_install_failed)
		# Abort if none install worked
		[ "$previous_install" = "1" ] && return

		# Copy original arguments
		local manifest_args_mod="$manifest_arguments"

		# Replace manifest key for the test
		check_domain=$sub_domain
		replace_manifest_key "domain" "$check_domain"
		# Use a path according to previous succeeded installs
		if [ "$previous_install" = "subdir" ]; then
			local check_path=$test_path
		elif [ "$previous_install" = "root" ]; then
			local check_path=/
		fi
		replace_manifest_key "path" "$check_path"
		replace_manifest_key "user" "$test_user"
		replace_manifest_key "public" "$public_public_arg"

		# Install the application in a LXC container
		ECHO_FORMAT "\nPreliminary install...\n" "white" "bold" clog
		if [ "$commit" == "current" ]
		then
			# If no commit is specified, use the current version.
			STANDARD_SETUP_APP
		else
			# Otherwise, use a specific commit
			# Backup the modified arguments
			update_manifest_args="$manifest_args_mod"
			# Get the arguments of the manifest for this upgrade.
			manifest_args_mod=$(grep "^manifest_arg=" "$partial_check_process" | cut -d'=' -f2-)
			if [ -z "$manifest_args_mod" ]; then
				# If there's no specific arguments, use the previous one.
				manifest_args_mod="$update_manifest_args"
			else
				# Otherwise, keep the new arguments, and replace the variables.
				manifest_args_mod="${manifest_args_mod//DOMAIN/$check_domain}"
				manifest_args_mod="${manifest_args_mod//PATH/$check_path}"
				manifest_args_mod="${manifest_args_mod//USER/$test_user}"
			fi
			# Make a backup of the directory
			sudo cp -a "$package_path" "${package_path}_back"
			# Change to the specified commit
			(cd "$package_path"; git checkout --force --quiet "$commit")
			# Install the application
			SETUP_APP
			# Then replace the backup
			sudo rm -r "$package_path"
			sudo mv "${package_path}_back" "$package_path"
			# And restore the arguments for the manifest
			manifest_args_mod="$update_manifest_args"
		fi

		# Check if the install had work
		if [ $yunohost_result -ne 0 ]
		then
			ECHO_FORMAT "\nInstallation failed...\n" "red" "bold"
		else
			ECHO_FORMAT "\nUpgrade...\n" "white" "bold" clog

			# Upgrade the application in a LXC container
			LXC_START "sudo PACKAGE_CHECK_EXEC=1 yunohost --debug app upgrade $ynh_app_id -f \"$package_dir\""

			# yunohost_result gets the return code of the upgrade
			yunohost_result=$?

			# Print the result of the upgrade command
			if [ $yunohost_result -eq 0 ]; then
				ECHO_FORMAT "Upgrade successful. ($yunohost_result)\n" "white" clog
			else
				ECHO_FORMAT "Upgrade failed. ($yunohost_result)\n" "white" clog
			fi

			# Check all the witness files, to verify if them still here
			check_witness_files

			# Analyse the log to extract "warning" and "error" lines
			LOG_EXTRACTOR

			# Try to access the app by its url
			CHECK_URL
		fi

		# Check the result and print SUCCESS or FAIL
		if check_test_result
		then	# Success
			# The global success for an upgrade can't be a success if another upgrade failed
			if [ $RESULT_check_upgrade -ne -1 ]; then
				RESULT_check_upgrade=1	# Upgrade succeed
			fi
		else	# Fail
			RESULT_check_upgrade=-1	# Upgrade failed
		fi

		# Remove the application
		REMOVE_APP

		# Uses the default snapshot
		current_snapshot=snap0
		# Stop and restore the LXC container
		LXC_STOP
	done 4< "$script_dir/upgrade_list"
}

CHECK_PUBLIC_PRIVATE () {
	# Try to install in public or private mode
	# $1 = install type

	local install_type=$1
	if [ "$install_type" = "private" ]; then
		unit_test_title "Installation in private mode..."
	else [ "$install_type" = "public" ]
		unit_test_title "Installation in public mode..."
	fi

	# Check if the needed manifest key are set or abort the test
	check_manifest_key "public" || return
	check_manifest_key "public_public" || return
	check_manifest_key "public_private" || return

	# Check if an install have previously work
	local previous_install=$(is_install_failed)
	# Abort if none install worked
	[ "$previous_install" = "1" ] && return

	# Copy original arguments
	local manifest_args_mod="$manifest_arguments"

	# Replace manifest key for the test
	check_domain=$sub_domain
	replace_manifest_key "domain" "$check_domain"
	replace_manifest_key "user" "$test_user"
	# Set public or private according to type of test requested
	if [ "$install_type" = "private" ]; then
		replace_manifest_key "public" "$public_private_arg"
	elif [ "$install_type" = "public" ]; then
		replace_manifest_key "public" "$public_public_arg"
	fi

	# Initialize the value
	local check_result_public_private=0

	# Try in 2 times, first in root and second in sub path.
	local i=0
	for i in 0 1
	do
		# First, try with a root install
		if [ $i -eq 0 ]
		then
			# Check if root installation worked, or if force_install_ok is setted.
			if [ $RESULT_check_root -eq 1 ] || [ $force_install_ok -eq 1 ]
			then
				# Replace manifest key for path
				local check_path=/
				replace_manifest_key "path" "$check_path"
			else
				# Jump to the second path if this check cannot be do
				ECHO_FORMAT "Root install failed, impossible to perform this test...\n" "lyellow" clog
				continue
			fi

		# Second, try with a sub path install
		elif [ $i -eq 1 ]
		then
			# Check if sub path installation worked, or if force_install_ok is setted.
			if [ $RESULT_check_sub_dir -eq 1 ] || [ $force_install_ok -eq 1 ]
			then
				# Replace manifest key for path
				local check_path=$test_path
				replace_manifest_key "path" "$check_path"
			else
				# Jump to the second path if this check cannot be do
				ECHO_FORMAT "Sub path install failed, impossible to perform this test...\n" "lyellow" clog
				return
			fi
		fi

		# Install the application in a LXC container
		SETUP_APP

		# Try to access the app by its url
		CHECK_URL

		# Change the result according to the results of the curl test
		if [ "$install_type" = "private" ]
		then
			# In private mode, if curl doesn't fell on the ynh portal, it's a fail.
			if [ $yuno_portal -eq 0 ]; then
				ECHO_FORMAT "App is not private: it should redirect to the Yunohost portal, but is publicly accessible instead\n" "lyellow" clog
				yunohost_result=1
			fi
		elif [ "$install_type" = "public" ]
		then
			# In public mode, if curl fell on the ynh portal, it's a fail.
			if [ $yuno_portal -eq 1 ]; then
				ECHO_FORMAT "App page is not public: it should be publicly accessible, but redirects to the Yunohost portal instead\n" "lyellow" clog
				yunohost_result=1
			fi
		fi

		# Check the result and print SUCCESS or FAIL
		if [ $yunohost_result -eq 0 ] && [ $curl_error -eq 0 ]
		then	# Success
			check_success
			# The global success for public/private mode can't be a success if another installation failed
			if [ $check_result_public_private -ne -1 ]; then
				check_result_public_private=1	# Installation succeed
			fi
		else	# Fail
			check_failed
			check_result_public_private=-1	# Installation failed
		fi

		# Fill the correct variable depend on the type of test
		if [ "$install_type" = "private" ]
		then
			RESULT_check_private=$check_result_public_private
		else	# public
			RESULT_check_public=$check_result_public_private
		fi

		# Make a break if auto_remove is set
		break_before_continue

		# Stop and restore the LXC container
		LXC_STOP
	done
}

CHECK_MULTI_INSTANCE () {
	# Try multi-instance installations

	unit_test_title "Multi-instance installations..."

	# Check if an install have previously work
	local previous_install=$(is_install_failed)
	# Abort if none install worked
	[ "$previous_install" = "1" ] && return

	# Copy original arguments
	local manifest_args_mod="$manifest_arguments"

	# Replace manifest key for the test
	replace_manifest_key "path" "$test_path"
	check_path=$test_path
	replace_manifest_key "user" "$test_user"
	replace_manifest_key "public" "$public_public_arg"

	# Install 2 times the same app
	local i=0
	for i in 1 2
	do
		# First installation
		if [ $i -eq 1 ]
		then
			check_domain=$main_domain
			ECHO_FORMAT "First installation: path=$check_domain$check_path\n" clog
		# Second installation
		elif [ $i -eq 2 ]
		then
			check_domain=$sub_domain
			ECHO_FORMAT "Second installation: path=$check_domain$check_path\n" clog
		fi

		# Replace path and domain manifest keys for the test
		replace_manifest_key "domain" "$check_domain"

		# Install the application in a LXC container
		SETUP_APP

		# Store the result in the correct variable
		# First installation
		if [ $i -eq 1 ]
		then
			local multi_yunohost_result_1=$yunohost_result
			local ynh_app_id_1=$ynh_app_id
		# Second installation
		elif [ $i -eq 2 ]
		then
			local multi_yunohost_result_2=$yunohost_result
			local ynh_app_id_2=$ynh_app_id
		fi
	done

	# Try to access to the 2 apps by theirs url
	for i in 1 2
	do
		# First app
		if [ $i -eq 1 ]
		then
			check_domain=$main_domain
			ynh_app_id=$ynh_app_id_1
		# Second app
		elif [ $i -eq 2 ]
		then
			check_domain=$sub_domain
			ynh_app_id=$ynh_app_id_2
		fi

		# Try to access the app by its url
		CHECK_URL

		# Check the result of curl test
		if [ $curl_error -ne 0 ] || [ $yuno_portal -ne 0 ]
		then
			# The test failed if curl fell on ynh portal or had an error.
			# First app
			if [ $i -eq 1 ]
			then
				multi_yunohost_result_1=1
			# Second app
			elif [ $i -eq 2 ]
			then
				multi_yunohost_result_2=1
			fi
		fi
	done

	# Check the result and print SUCCESS or FAIL
	# Succeed if the 2 installations work;
	if [ $multi_yunohost_result_1 -eq 0 ] && [ $multi_yunohost_result_2 -eq 0 ]
	then	# Success
		check_success
		RESULT_check_multi_instance=1
	else	# Fail
		check_failed
		RESULT_check_multi_instance=-1
	fi

	# Make a break if auto_remove is set
	break_before_continue
}

CHECK_COMMON_ERROR () {
	# Try to install with specific complications
	# $1 = install type

	local install_type=$1
	if [ "$install_type" = "incorrect_path" ]; then
		unit_test_title "Malformed path..."
		# Check if the needed manifest key are set or abort the test
		check_manifest_key "path" || return
	else [ "$install_type" = "port_already_use" ]
		unit_test_title "Port already used..."
		# Check if the needed manifest key are set or abort the test
		check_manifest_key "port" || return
	fi

	# Check if an install have previously work
	local previous_install=$(is_install_failed)
	# Abort if none install worked
	[ "$previous_install" = "1" ] && return

	# Copy original arguments
	local manifest_args_mod="$manifest_arguments"

	# Replace manifest key for the test
	check_domain=$sub_domain
	replace_manifest_key "domain" "$check_domain"
	replace_manifest_key "user" "$test_user"
	replace_manifest_key "public" "$public_public_arg"

	# Replace path manifest key for the test
	if [ "$install_type" = "incorrect_path" ]; then
		# Change the path from /path to path/
		local wrong_path=${test_path#/}/
		# Use this wrong path only for the arguments that will give to yunohost for installation.
		replace_manifest_key "path" "$wrong_path"
		local check_path=$test_path
	else [ "$install_type" = "port_already_use" ]
		# Use a path according to previous succeeded installs
		if [ "$previous_install" = "subdir" ]; then
			local check_path=$test_path
		else
			local check_path=/
		fi
		replace_manifest_key "path" "$check_path"
	fi

	# Open the specified port to force the script to find another
	if [ "$install_type" = "port_already_use" ]
	then

		# If the first character is a #, that means it this port number is not in the manifest
		if [ "${port_arg:0:1}" = "#" ]
		then
			# Retrieve the port number
			local check_port="${port_arg:1}"

		# Else, the port number is in the manifest. So the port number is set at a fixed value.
		else
			local check_port=6660
			# Replace port manifest key for the test
			replace_manifest_key "port" "$check_port"
		fi

		# Build a service with netcat for use this port before the app.
		echo -e "[Service]\nExecStart=/bin/netcat -l -k -p $check_port\n
				[Install]\nWantedBy=multi-user.target" | \
				sudo tee "/var/lib/lxc/$lxc_name/rootfs/etc/systemd/system/netcat.service" \
				> /dev/null

		# Then start this service to block this port.
		LXC_START "sudo systemctl enable netcat & sudo systemctl start netcat"
	fi

	# Install the application in a LXC container
	SETUP_APP

	# Try to access the app by its url
	CHECK_URL

	# Check the result and print SUCCESS or FAIL
	if check_test_result
	then	# Success
		local check_result_setup=1
	else	# Fail
		local check_result_setup=-1
	fi

	# Fill the correct variable depend on the type of test
	if [ "$install_type" = "incorrect_path" ]
	then
		RESULT_check_path=$check_result_setup
	elif [ "$install_type" = "port_already_use" ]; then
		RESULT_check_port=$check_result_setup
	fi

	# Make a break if auto_remove is set
	break_before_continue
}

CHECK_BACKUP_RESTORE () {
	# Try to backup then restore the app

	unit_test_title "Backup/Restore..."

	# Check if an install have previously work
	local previous_install=$(is_install_failed)
	# Abort if none install worked
	[ "$previous_install" = "1" ] && return

	# Copy original arguments
	local manifest_args_mod="$manifest_arguments"

	# Replace manifest key for the test
	check_domain=$sub_domain
	replace_manifest_key "domain" "$check_domain"
	replace_manifest_key "user" "$test_user"
	replace_manifest_key "public" "$public_public_arg"

	# Try in 2 times, first in root and second in sub path.
	local i=0
	for i in 0 1
	do
		# First, try with a root install
		if [ $i -eq 0 ]
		then
			# Check if root installation worked, or if force_install_ok is setted.
			if [ $RESULT_check_root -eq 1 ] || [ $force_install_ok -eq 1 ]
			then
				# Replace manifest key for path
				local check_path=/
				replace_manifest_key "path" "$check_path"
				ECHO_FORMAT "\nPreliminary installation on the root...\n" "white" "bold" clog
			else
				# Jump to the second path if this check cannot be do
				ECHO_FORMAT "Root install failed, impossible to perform this test...\n" "lyellow" clog
				continue
			fi

		# Second, try with a sub path install
		elif [ $i -eq 1 ]
		then
			# Check if sub path installation worked, or if force_install_ok is setted.
			if [ $RESULT_check_sub_dir -eq 1 ] || [ $force_install_ok -eq 1 ]
			then
				# Replace manifest key for path
				local check_path=$test_path
				replace_manifest_key "path" "$check_path"
				ECHO_FORMAT "\nPreliminary installation in a sub path...\n" "white" "bold" clog
			else
				# Jump to the second path if this check cannot be do
				ECHO_FORMAT "Sub path install failed, impossible to perform this test...\n" "lyellow" clog
				return
			fi
		fi

		# Install the application in a LXC container
		STANDARD_SETUP_APP

		# Remove the previous residual backups
		sudo rm -rf /var/lib/lxc/$lxc_name/rootfs/home/yunohost.backup/archives
		sudo rm -rf /var/lib/lxcsnaps/$lxc_name/$current_snapshot/rootfs/home/yunohost.backup/archives

		# BACKUP
		# Made a backup if the installation succeed
		if [ $yunohost_result -ne 0 ]
		then
			ECHO_FORMAT "\nInstallation failed...\n" "red" "bold"
		else
			ECHO_FORMAT "\nBackup of the application...\n" "white" "bold" clog

			# Made a backup of the application
			LXC_START "sudo PACKAGE_CHECK_EXEC=1 yunohost --debug backup create -n Backup_test --apps $ynh_app_id --system $backup_hooks"

			# yunohost_result gets the return code of the backup
			yunohost_result=$?

			# Print the result of the backup command
			if [ $yunohost_result -eq 0 ]; then
				ECHO_FORMAT "Backup successful. ($yunohost_result)\n" "white" clog
			else
				ECHO_FORMAT "Backup failed. ($yunohost_result)\n" "white" clog
			fi

			# Check all the witness files, to verify if them still here
			check_witness_files

			# Analyse the log to extract "warning" and "error" lines
			LOG_EXTRACTOR
		fi

		# Check the result and print SUCCESS or FAIL
		if [ $yunohost_result -eq 0 ]
		then	# Success
			check_success
			# The global success for a backup can't be a success if another backup failed
			if [ $RESULT_check_backup -ne -1 ]; then
			    RESULT_check_backup=1	# Backup succeed
			fi
		else	# Fail
			check_failed
			RESULT_check_backup=-1	# Backup failed
		fi

		# Grab the backup archive into the LXC container, and keep a copy
		sudo cp -a /var/lib/lxc/$lxc_name/rootfs/home/yunohost.backup/archives ./

		# RESTORE
		# Try the restore process in 2 times, first after removing the app, second after a restore of the container.
		local j=0
		for j in 0 1
		do
			# First, simply remove the application
			if [ $j -eq 0 ]
			then
				# Remove the application
				REMOVE_APP

				ECHO_FORMAT "\nRestore after removing the application...\n" "white" "bold" clog

			# Second, restore the whole container to remove completely the application
			elif [ $j -eq 1 ]
			then
				# Uses the default snapshot
				current_snapshot=snap0

				# Remove the previous residual backups
				sudo rm -rf /var/lib/lxcsnaps/$lxc_name/$current_snapshot/rootfs/home/yunohost.backup/archives

				# Place the copy of the backup archive in the container.
				sudo mv -f ./archives /var/lib/lxcsnaps/$lxc_name/$current_snapshot/rootfs/home/yunohost.backup/

				# Stop and restore the LXC container
				LXC_STOP

				ECHO_FORMAT "\nRestore on a clean YunoHost system...\n" "white" "bold" clog
			fi

			# Restore the application from the previous backup
			LXC_START "sudo PACKAGE_CHECK_EXEC=1 yunohost --debug backup restore Backup_test --force --apps $ynh_app_id"

			# yunohost_result gets the return code of the restore
			yunohost_result=$?

			# Print the result of the backup command
			if [ $yunohost_result -eq 0 ]; then
				ECHO_FORMAT "Restore successful. ($yunohost_result)\n" "white" clog
			else
				ECHO_FORMAT "Restore failed. ($yunohost_result)\n" "white" clog
			fi

			# Check all the witness files, to verify if them still here
			check_witness_files

			# Analyse the log to extract "warning" and "error" lines
			LOG_EXTRACTOR

			# Try to access the app by its url
			CHECK_URL

			# Check the result and print SUCCESS or FAIL
			if check_test_result
			then	# Success
				# The global success for a restore can't be a success if another restore failed
				if [ $RESULT_check_restore -ne -1 ]; then
					RESULT_check_restore=1	# Restore succeed
				fi
			else	# Fail
				RESULT_check_restore=-1	# Restore failed
			fi

			# Make a break if auto_remove is set
			break_before_continue

			# Stop and restore the LXC container
			LXC_STOP
		done
	done
}

CHECK_CHANGE_URL () {
	# Try the change_url script

	unit_test_title "Change URL..."

	# Check if the needed manifest key are set or abort the test
	check_manifest_key "domain" || return

	# Check if an install have previously work
	local previous_install=$(is_install_failed)
	# Abort if none install worked
	[ "$previous_install" = "1" ] && return

	# Copy original arguments
	local manifest_args_mod="$manifest_arguments"

	# Replace manifest key for the test
	check_domain=$sub_domain
	replace_manifest_key "domain" "$check_domain"
	replace_manifest_key "user" "$test_user"
	replace_manifest_key "public" "$public_public_arg"

	# Try in 6 times !
	# Without modify the domain, root to path, path to path and path to root.
	# And then, same with a domain change
	local i=0
	for i in ` seq 1 6`
	do
		if [ $i -eq 1 ]; then
			# Same domain, root to path
			check_path=/
			local new_path=$test_path
			local new_domain=$sub_domain
		elif [ $i -eq 2 ]; then
			# Same domain, path to path
			check_path=$test_path
			local new_path=${test_path}_2
			local new_domain=$sub_domain
		elif [ $i -eq 3 ]; then
			# Same domain, path to root
			check_path=$test_path
			local new_path=/
			local new_domain=$sub_domain

		elif [ $i -eq 4 ]; then
			# Other domain, root to path
			check_path=/
			local new_path=$test_path
			local new_domain=$main_domain
		elif [ $i -eq 5 ]; then
			# Other domain, path to path
			check_path=$test_path
			local new_path=${test_path}_2
			local new_domain=$main_domain
		elif [ $i -eq 6 ]; then
			# Other domain, path to root
			check_path=$test_path
			local new_path=/
			local new_domain=$main_domain
		fi
		replace_manifest_key "path" "$check_path"

		# Check if root or subpath installation worked, or if force_install_ok is setted.
		if [ $force_install_ok -eq 1 ]
		then
			# Try with a sub path install
			if [ "$check_path" = "/" ]
			then
				if [ $RESULT_check_root -ne 1 ] && [ $force_install_ok -ne 1 ]
				then
					# Jump this test
					ECHO_FORMAT "Root install failed, impossible to perform this test...\n" "lyellow" clog
					continue
				fi
			# And with a sub path install
			else
				if [ $RESULT_check_sub_dir -ne 1 ] && [ $force_install_ok -ne 1 ]
				then
					# Jump this test
					ECHO_FORMAT "Sub path install failed, impossible to perform this test...\n" "lyellow" clog
					continue
				fi
			fi
		fi

		# Install the application in a LXC container
		ECHO_FORMAT "\nPreliminary install...\n" "white" "bold" clog
		STANDARD_SETUP_APP

		# Check if the install had work
		if [ $yunohost_result -ne 0 ]
		then
			ECHO_FORMAT "Installation failed...\n" "red" "bold"
		else
			ECHO_FORMAT "Change the url from $sub_domain$check_path to $new_domain$new_path...\n" "white" "bold" clog

			# Change the url
			LXC_START "sudo PACKAGE_CHECK_EXEC=1 yunohost --debug app change-url $ynh_app_id -d \"$new_domain\" -p \"$new_path\""

			# yunohost_result gets the return code of the change-url script
			yunohost_result=$?

			# Print the result of the change_url command
			if [ $yunohost_result -eq 0 ]; then
				ECHO_FORMAT "Change_url script successful. ($yunohost_result)\n" "white" clog
			else
				ECHO_FORMAT "Change_url script failed. ($yunohost_result)\n" "white" clog
			fi

			# Check all the witness files, to verify if them still here
			check_witness_files

			# Analyse the log to extract "warning" and "error" lines
			LOG_EXTRACTOR

			# Try to access the app by its url
			check_path=$new_path
			check_domain=$new_domain
			CHECK_URL
		fi

		# Check the result and print SUCCESS or FAIL
		if check_test_result
		then	# Success
			# The global success for a change_url can't be a success if another change_url failed
			if [ $RESULT_change_url -ne -1 ]; then
				RESULT_change_url=1	# Change_url succeed
			fi
		else	# Fail
			RESULT_change_url=-1	# Change_url failed
		fi

		# Make a break if auto_remove is set
		break_before_continue

		# Stop and restore the LXC container
		LXC_STOP
	done
}

PACKAGE_LINTER () {
	# Package linter

	unit_test_title "Package linter..."

	# Execute package linter and linter_result gets the return code of the package linter
	"$script_dir/package_linter/package_linter.py" "$package_path" > "$temp_result"

	# linter_result gets the return code of the package linter
	local linter_result=$?

	# Print the results of package linter and copy these result in the complete log
	cat "$temp_result" | tee --append "$complete_log"

	# Check the result and print SUCCESS or FAIL
	if [ $linter_result -eq 0 ]
	then	# Success
		check_success
		RESULT_linter=1
	else	# Fail
		check_failed
		RESULT_linter=-1
	fi
}

TEST_LAUNCHER () {
	# Abstract for test execution.
	# $1 = Name of the function to execute
	# $2 = Argument for the function

	# Intialize values
	yunohost_result=-1
	yunohost_remove=-1

	# Start the timer for this test
	start_timer
	# And keep this value separately
	local global_start_timer=$starttime

	# Execute the test
	$1 $2

	# Uses the default snapshot
	current_snapshot=snap0

	# Stop and restore the LXC container
	LXC_STOP

	# Restore the started time for the timer
	starttime=$global_start_timer
	# End the timer for the test
	stop_timer 2

	# Update the lock file with the date of the last finished test.
	echo "$1 $2:$(date +%s)" > "$lock_file"
}

set_witness_files () {
	# Create files to check if the remove script does not remove them accidentally
	echo "Create witness files..." | tee --append "$test_result"

	lxc_dir="/var/lib/lxc/$lxc_name/rootfs"

	create_witness_file () {
		[ "$2" = "file" ] && local action="touch" || local action="mkdir -p"
		sudo $action "${lxc_dir}${1}"
	}

	# Nginx conf
	create_witness_file "/etc/nginx/conf.d/$main_domain.d/witnessfile.conf" file
	create_witness_file "/etc/nginx/conf.d/$sub_domain.d/witnessfile.conf" file

	# /etc
	create_witness_file "/etc/witnessfile" file

	# /opt directory
	create_witness_file "/opt/witnessdir" directory

	# /var/www directory
	create_witness_file "/var/www/witnessdir" directory

	# /home/yunohost.app/
	create_witness_file "/home/yunohost.app/witnessdir" directory

	# /var/log
	create_witness_file "/var/log/witnessfile" file

	# Config fpm
	if [ -d "${lxc_dir}/etc/php5" ]; then
		create_witness_file "/etc/php5/fpm/pool.d/witnessfile.conf" file
	fi
	if [ -d "${lxc_dir}/etc/php/7.0" ]; then
		create_witness_file "/etc/php/7.0/fpm/pool.d/witnessfile.conf" file
	fi

	# Config logrotate
	create_witness_file "/etc/logrotate.d/witnessfile" file

	# Config systemd
	create_witness_file "/etc/systemd/system/witnessfile.service" file

	# Database
	sudo lxc-attach --name=$lxc_name -- mysqladmin --user=root --password=$(sudo cat "$lxc_dir/etc/yunohost/mysql") --wait status > /dev/null 2>&1
	sudo lxc-attach --name=$lxc_name -- mysql --user=root --password=$(sudo cat "$lxc_dir/etc/yunohost/mysql") --wait --execute="CREATE DATABASE witnessdb" > /dev/null 2>&1
}

check_witness_files () {
	# Check all the witness files, to verify if them still here

	lxc_dir="/var/lib/lxc/$lxc_name/rootfs"

	check_file_exist () {
		if sudo test ! -e "${lxc_dir}${1}"
		then
			ECHO_FORMAT "The file $1 is missing ! Something gone wrong !\n" "red" "bold"
			RESULT_witness=1
		fi
	}

	# Nginx conf
	check_file_exist "/etc/nginx/conf.d/$main_domain.d/witnessfile.conf"
	check_file_exist "/etc/nginx/conf.d/$sub_domain.d/witnessfile.conf"

	# /etc
	check_file_exist "/etc/witnessfile"

	# /opt directory
	check_file_exist "/opt/witnessdir"

	# /var/www directory
	check_file_exist "/var/www/witnessdir"

	# /home/yunohost.app/
	check_file_exist "/home/yunohost.app/witnessdir"

	# /var/log
	check_file_exist "/var/log/witnessfile"

	# Config fpm
	if [ -d "${lxc_dir}/etc/php5" ]; then
		check_file_exist "/etc/php5/fpm/pool.d/witnessfile.conf" file
	fi
	if [ -d "${lxc_dir}/etc/php/7.0" ]; then
		check_file_exist "/etc/php/7.0/fpm/pool.d/witnessfile.conf" file
	fi

	# Config logrotate
	check_file_exist "/etc/logrotate.d/witnessfile"

	# Config systemd
	check_file_exist "/etc/systemd/system/witnessfile.service"

	# Database
	if ! sudo lxc-attach --name=$lxc_name -- mysqlshow --user=root --password=$(sudo cat "$lxc_dir/etc/yunohost/mysql") | grep --quiet '^| witnessdb' > /dev/null 2>&1
	then
		ECHO_FORMAT "The database witnessdb is missing ! Something gone wrong !\n" "red" "bold"
		RESULT_witness=1
	fi
	if [ $RESULT_witness -eq 1 ]
	then
		yunohost_result=1
		yunohost_remove=1
	fi
}

TESTING_PROCESS () {
	# Launch all tests successively

	ECHO_FORMAT "\nTests serie: ${tests_serie#;; }\n" "white" "underlined" clog

	# Init the value for the current test
	cur_test=1

	# By default, all tests will try to access the app with curl
	use_curl=1

	# Check the package with package linter
	if [ $pkg_linter -eq 1 ]; then
		PACKAGE_LINTER
	fi

	# Try to install in a sub path
	if [ $setup_sub_dir -eq 1 ]; then
		TEST_LAUNCHER CHECK_SETUP subdir
	fi

	# Try to install on root
	if [ $setup_root -eq 1 ]; then
		TEST_LAUNCHER CHECK_SETUP root
	fi

	# Try to install without url access
	if [ $setup_nourl -eq 1 ]; then
		TEST_LAUNCHER CHECK_SETUP no_url
	fi

	# Try the upgrade script
	if [ $upgrade -eq 1 ]; then
		TEST_LAUNCHER CHECK_UPGRADE
	fi

	# Try to install in private mode
	if [ $setup_private -eq 1 ]; then
		TEST_LAUNCHER CHECK_PUBLIC_PRIVATE private
	fi

	# Try to install in public mode
	if [ $setup_public -eq 1 ]; then
		TEST_LAUNCHER CHECK_PUBLIC_PRIVATE public
	fi

	# Try multi-instance installations
	if [ $multi_instance -eq 1 ]; then
		TEST_LAUNCHER CHECK_MULTI_INSTANCE
	fi

	# Try to install with an malformed path
	if [ $incorrect_path -eq 1 ]; then
		TEST_LAUNCHER CHECK_COMMON_ERROR incorrect_path
	fi

	# Try to install with a port already used
	if [ $port_already_use -eq 1 ]; then
		TEST_LAUNCHER CHECK_COMMON_ERROR port_already_use
	fi

	# Try to backup then restore the app
	if [ $backup_restore -eq 1 ]; then
		TEST_LAUNCHER CHECK_BACKUP_RESTORE
	fi

	# Try the change_url script
	if [ $change_url -eq 1 ]; then
		TEST_LAUNCHER CHECK_CHANGE_URL
	fi
}
