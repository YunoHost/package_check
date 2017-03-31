#!/bin/bash

#=================================================
# Grab the script directory
#=================================================

if [ "${0:0:1}" == "/" ]; then script_dir="$(dirname "$0")"; else script_dir="$(echo $PWD/$(dirname "$0" | cut -d '.' -f2) | sed 's@/$@@')"; fi

#=================================================
# Starting and checking
#=================================================
# Generic functions
#=================================================

clean_exit () {
	# Exit and remove all temp files
	# $1 = exit code
	
	# Deactivate LXC network
	LXC_TURNOFF

	# Remove temporary files
	rm -f "$temp_log"
	rm -f "$temp_result"
	rm -f "$script_dir/url_output"
	rm -f "$script_dir/curl_print"
	rm -f "$script_dir/manifest_extract"

	# Remove the application which been tested
	if [ -n "$package_path" ]; then
		rm -rf "$package_path"
	fi

	# Remove the lock file
	rm -f "$lock_file"

	exit $1
}

#=================================================
# Check and read CLI arguments
#=================================================

echo ""

# Init arguments value
gitbranch=0
force_install_ok=0
interrupt=0
notice=0
build_lxc=0
bash_mode=0

# If no arguments provided
if [ "$#" -eq 0 ]
then
	# Print the help and exit
	notice=1
else
	# Reduce the arguments for getopts
	arguments="$*"
	arguments=${arguments//--branch=/-b }
	arguments=${arguments//--force-install-ok/-f}
	arguments=${arguments//--interrupt/-i}
	arguments=${arguments//--help/-h}
	arguments=${arguments//--build-lxc/-l}
	arguments=${arguments//--bash-mode/-y}

	# Read and parse all the arguments
	while [ $# -ne 0 ]
	do
		# Initialize the index of getopts
		OPTIND=1
		# Parse with getopts only if the argument begin by -
		if [ ${1:0:1} = "-" ]
		then
			getopts ":b:fihly " parameter
			case $parameter in
				b)
					# --branch=branch-name
					gitbranch="$OPTARG"
					;;
				f)
					# --force-install-ok
					force_install_ok=1
					;;
				i)
					# --interrupt
					interrupt=1
					;;
				h)
					# --help
					notice=1
					;;
				l)
					# --build-lxc
					build_lxc=1
					;;
				y)
					# --bash-mode
					bash_mode=1
					;;
				\?)
					echo "Invalid argument: -$OPTARG" >&2
					notice=1
					;;
				:)
					echo "-$OPTARG parameter requires an argument." >&2
					notice=1
					;;
			esac
		else
			other_args="$other_args $1"
		fi
		shift
	done
fi

# Prevent a conflict between --interrupt and --bash-mode
if [ $interrupt -eq 1 ] && [ $bash_mode -eq 1 ]
then
	echo "You can't use --interrupt and --bash-mode together !"
	notice=1
fi

# Print help
if [ $notice -eq 1 ]
then
	cat << EOF

Usage:
package_check.sh [OPTION]... PACKAGE_TO_CHECK
	-b, --branch=BRANCH
		Specify a branch to check.
	-f, --force-install-ok
		Force following test even if all install have failed.
	-i, --interrupt
		Force auto_remove value, break before each remove.
	-h, --help
		Display this notice.
	-l, --build-lxc
		Install LXC and build the container if necessary.
	-y, --bash-mode
		Do not ask for continue check. Ignore auto_remove.
EOF
	clean_exit 0
fi

#=================================================
# Check if the lock file exist
#=================================================

lock_file="$script_dir/pcheck.lock"

if test -e "$lock_file"
then
	# If the lock file exist
	echo "The lock file $lock_file is present. Package check would not continue."
	answer="y"
	if [ $bash_mode -ne 1 ]; then
		echo -n "Do you want to continue anymore? (y/n) :"
		read answer
	fi
	# Set the answer at lowercase only
	answer=${answer,,}
	if [ "${rep:0:1}" != "y" ]
	then
		echo "Cancel Package check execution"
		clean_exit 0
	fi
fi
# Create the lock file
touch "$lock_file"

#=================================================
# Upgrade Package check
#=================================================

git_repository=https://github.com/YunoHost/package_check
version_file="$script_dir/pcheck_version"

check_version="$(git ls-remote $git_repository | cut -f 1 | head -n1)"

# If the version file exist, check for an upgrade
if [ -e "$version_file" ]
then
	# Check if the last commit on the repository match with the current version
	if [ "$check_version" != "$(cat "$version_file")" ]
	then
		# If the versions don't matches. Do an upgrade
		echo -e "\e[97m\e[1mUpgrade Package check...\n\e[0m"

		# Build the upgrade script
		cat > "$script_dir/upgrade_script.sh" << EOF

#!/bin/bash
# Clone in another directory
git clone --quiet $git_repository "$script_dir/upgrade"
cp -a "$script_dir/upgrade/." "$script_dir/."
rm -r "$script_dir/upgrade"
# Update the version file
echo "$check_version" > "$version_file"
rm "$script_dir/pcheck.lock"
# Execute package check by replacement of this process
exec "$script_dir/package_check.sh" "$arguments"
EOF

		# Give the execution right
		chmod +x "$script_dir/upgrade_script.sh"

		# Start the upgrade script by replacement of this process
		exec "$script_dir/upgrade_script.sh"
	fi
fi

# Update the version file
echo "$check_version" > "$version_file"

#=================================================
# Upgrade Package linter
#=================================================

git_repository=https://github.com/YunoHost/package_linter
version_file="$script_dir/plinter_version"

check_version="$(git ls-remote $git_repository | cut -f 1 | head -n1)"

# If the version file exist, check for an upgrade
if [ -e "$version_file" ]
then
	# Check if the last commit on the repository match with the current version
	if [ "$check_version" != "$(cat "$version_file")" ]
	then
		# If the versions don't matches. Do an upgrade
		echo -e "\e[97m\e[1mUpgrade Package linter...\n\e[0m"

		# Clone in another directory
		git clone --quiet https://github.com/YunoHost/package_linter "$script_dir/package_linter_tmp"

		# And replace
		cp -a "$script_dir/package_linter_tmp/." "$script_dir/package_linter/."
		rm -r "$script_dir/package_linter_tmp"
	fi
else
	echo -e "\e[97mInstall Package linter.\n\e[0m"
	git clone --quiet $git_repository "$script_dir/package_linter"
fi

# Update the version file
echo "$check_version" > "$version_file"

#=================================================
# Get variables from the config file
#=================================================

pcheck_config="$script_dir/config"
build_script="$script_dir/sub_scripts/lxc_build.sh"

if [ -e "$pcheck_config" ]
then
	# Read the config file if it exists
	ip_range=$(grep PLAGE_IP= "$pcheck_config" | cut -d '=' -f2)
	main_domain=$(grep DOMAIN= "$pcheck_config" | cut -d '=' -f2)
	yuno_pwd=$(grep YUNO_PWD= "$pcheck_config" | cut -d '=' -f2)
	lxc_name=$(grep LXC_NAME= "$pcheck_config" | cut -d '=' -f2)
	lxc_bridge=$(grep LXC_BRIDGE= "$pcheck_config" | cut -d '=' -f2)
	main_iface=$(grep iface= "$pcheck_config" | cut -d '=' -f2)
fi

# Use default value from the build script if needed
if [ -z "$ip_range" ]; then
	ip_range=$(grep "|| PLAGE_IP=" "$build_script" | cut -d '"' -f4)
	echo -e "# Ip range for the container\nPLAGE_IP=$ip_range\n" >> "$pcheck_config"
fi
if [ -z "$main_domain" ]; then
	main_domain=$(grep "|| DOMAIN="  "$build_script" | cut -d '=' -f2)
	echo -e "# Test domain\nDOMAIN=$main_domain\n" >> "$pcheck_config"
fi
if [ -z "$yuno_pwd" ]; then
	yuno_pwd=$(grep "|| YUNO_PWD="  "$build_script" | cut -d '=' -f2)
	echo -e "# YunoHost password, in the container\nYUNO_PWD=$yuno_pwd\n" >> "$pcheck_config"
fi
if [ -z "$lxc_name" ]; then
	lxc_name=$(grep "|| LXC_NAME="  "$build_script" | cut -d '=' -f2)
	echo -e "# Container name\nLXC_NAME=$lxc_name\n" >> "$pcheck_config"
fi
if [ -z "$lxc_bridge" ]; then
	lxc_bridge=$(grep "|| LXC_BRIDGE="  "$build_script" | cut -d '=' -f2)
	echo -e "# Bridge name\nLXC_BRIDGE=$lxc_bridge\n" >> "$pcheck_config"
fi

if [ -z "$main_iface" ]; then
	# Try to determine the main iface
	main_iface=$(sudo route | grep default | awk '{print $8;}')
	if [ -z $main_iface ]
	then
		echo -e "\e[91mUnable to find the name of the main iface.\e[0m"
		clean_exit 1
	fi
	# Store the main iface in the config file
	echo -e "# Main host iface\niface=$main_iface\n" >> "$pcheck_config"
fi

#=================================================
# Check the user who try to execute this script
#=================================================

setup_user_file="$script_dir/sub_scripts/setup_user"
if [ -e "$setup_user_file" ]
then
	# Compare the current user and the user stored in $setup_user_file
	authorised_user="$(cat "$setup_user_file")"
	if [ "$(whoami)" != "$authorised_user" ]
	then
		echo -e "\e[91mThis script need to be executed by the user $setup_user_file !\nThe current user is $(whoami).\e[0m"
		clean_exit 1
	fi
else
	echo -e "\e[93mUnable to define the user who authorised to use package check. Please fill the file $setup_user_file\e[0m"
fi

#=================================================
# Check the internet connectivity
#=================================================

# Try to ping yunohost.org
ping -q -c 2 yunohost.org > /dev/null 2>&1
if [ "$?" -ne 0 ]; then
	# If fail, try to ping another domain
	ping -q -c 2 framasoft.org > /dev/null 2>&1
	if [ "$?" -ne 0 ]; then
		# If ping failed twice, it's seems the internet connection is down.
		echo "\e[91mUnable to connect to internet.\e[0m"
		clean_exit 1
	fi
fi

#=================================================
# Define globals variables
#=================================================

# Complete result log. Complete log of YunoHost
complete_log="$script_dir/Complete.log"
# Partial YunoHost log, just the log for the current test
temp_log="$script_dir/temp_yunohost-cli.log"
# Temporary result log
temp_result="$script_dir/temp_result.log"
# Result log with warning and error only
test_result="$script_dir/Test_results.log"
# Real YunoHost log
yunohost_log="/var/lib/lxc/$lxc_name/rootfs/var/log/yunohost/yunohost-cli.log"

sub_domain="sous.$main_domain"
test_user=package_checker
test_path=/check

#=================================================
# Load all functions
#=================================================

source "$script_dir/sub_scripts/lxc_launcher.sh"
source "$script_dir/sub_scripts/testing_process.sh"
source "$script_dir/sub_scripts/log_extractor.sh"
source /usr/share/yunohost/helpers

#=================================================
# Check LXC
#=================================================

# Check if lxc is already installed
if dpkg-query -W -f '${Status}' "lxc" 2>/dev/null | grep -q "ok installed"
then
	# If lxc is installed, check if the container is already built.
	if ! sudo lxc-ls | grep -q "$lxc_name"
	then
		if [ $build_lxc -eq 1 ]
		then
			# If lxc's not installed and build_lxc set. Asks to build the container.
			build_lxc=2
		else
			ECHO_FORMAT "LXC is not installed or the container $lxc_name doesn't exist.\n" "red"
			ECHO_FORMAT "Use the script 'lxc_build.sh' to fix them.\n" "red"
			clean_exit 1
		fi
	fi
elif [ $build_lxc -eq 1 ]
then
	# If lxc's not installed and build_lxc set. Asks to build the container.
	build_lxc=2
fi

if [ $build_lxc -eq 2 ]
then
	# Install LXC and build the container before continue.
	"$script_dir/sub_scripts/lxc_build.sh"
fi

# Stop and restore the LXC container. In case of previous incomplete execution.
LXC_STOP
# Deactivate LXC network
LXC_TURNOFF

#=================================================
# Determine if it's a CI environment
#=================================================

# By default, it's a standalone execution.
type_exec_env=0
if [ -e "$script_dir/../config" ]
then
	# CI environment
	type_exec_env=1
fi
if [ -e "$script_dir/../auto_build/auto.conf" ]
then
	# Official CI environment
	type_exec_env=2
fi

#=================================================
# Pick up the package
#=================================================

echo "Pick up the package which will be tested."

# Remove the previous package if it's still here.
rm -rf "$script_dir"/*_check

package_dir="$(basename "$other_args")_check"
package_path="$script_dir/$package_dir"

# If the package is in a git repository
if echo "$other_args" | grep -Eq "https?:\/\/"
then
	# Clone the repository
	git clone $other_args $gitbranch "$package_path"

# If it's a local directory
else
	# Do a copy in the directory of Package check
	cp -a "$other_args" "$package_path"
fi

# Check if the package directory is really here.
if [ ! -d "$package_path" ]; then
	ECHO_FORMAT "Unable to find the directory $package_path for the package...\n" "red"
	clean_exit 1
fi

# Remove the .git directory.
rm -rf "$package_path/.git"





#=================================================
# Parsing and performing tests
#=================================================
# Check if a check_process file exist
#=================================================

check_file=1
check_process="$package_path/check_process"

if [ ! -e "$check_process" ]
then
	ECHO_FORMAT "\nUnable to find a check_process file.\n" "red"
	ECHO_FORMAT "Package check will be used in lower mode.\n" "lyellow"
	check_file=0
fi

#=================================================
# Initialize tests
#=================================================

# Default values for level
level[1]=auto
level[2]=auto
level[3]=auto
level[4]=0
level[5]=auto
level[6]=auto
level[7]=auto
level[8]=0
level[9]=0
level[10]=0

# Purge some log files
> "$complete_log"
> "$test_result"
> "$script_dir/lxc_boot.log"

# Initialize LXC network
LXC_INIT

# Default values for check_process and TESTING_PROCESS
initialize_values() {
	# Test results
	RESULT_linter=0
	RESULT_global_setup=0
	RESULT_global_remove=0
	RESULT_check_sub_dir=0
	RESULT_check_root=0
	RESULT_check_remove_sub_dir=0
	RESULT_check_remove_root=0
	RESULT_check_upgrade=0
	RESULT_check_backup=0
	RESULT_check_restore=0
	RESULT_check_private=0
	RESULT_check_public=0
	RESULT_check_multi_instance=0
	RESULT_check_path=0
	RESULT_check_port=0
	RESULT_check_=0

	# auto_remove parameter
	if [ $interrupt -eq 1 ]; then
		auto_remove=0
	else
		auto_remove=1
	fi

	# Number of tests to proceed
	all_test=0
}

#=================================================
# Parse the check_process
#=================================================

# Parse the check_process only if it's exist
if [ $check_file -eq 1 ]
then
	ECHO_FORMAT "Parsing of check_process file"

	# Remove all commented lines in the check_process
	sed --in-place '/^#/d' "$check_process"
	# Remove all spaces at the beginning of the lines
	sed --in-place 's/^[ \t]*//g' "$check_process"

	# Check if a string can be find in the current line
	check_line () {
		return $(echo "$line" | grep -q "$1")
	}

	# Search a string in the partial check_process
	find_string () {
		echo $(grep "$1" "$partial_check_process")
	}

	# Extract a section found between $1 and $2 from the file $3
	extract_section () {
		# Erase the partial check_process
		> "$partial_check_process"
		local source_file="$3"
		local extract=0
		local line=""
		while read line
		do
			# Search for the first line
			if check_line "$1"; then
				# Activate the extract process
				extract=1
			fi

			# Extract the line
			if [ $extract -eq 1 ]
			then
				# Check if the line is the second line to found
				if check_line "$2"; then
					# Break the loop to finish the extract process
					break;
				fi
				# Copy the line in the partial check_process
				echo $line >> "$partial_check_process"
			fi
		done < "$source_file"
	}

	# Use 2 partial files, to keep one for a whole tests serie
	partial1="${check_process}_part1"
	partial2="${check_process}_part2"

	# Extract the level section
	partial_check_process=$partial1
	extract_section "^;;; Levels" "^;; " "$check_process"

	# Get the value associated to each level
	for i in `seq 1 10`
	do
		# Find the line for this level
		line=$(find_string "^Level $i=")
		# And get the value
		level[$i]=$(echo "$line" | cut -d '=' -f2)
	done

	# Parse each tests serie
	while read tests_serie
	do
		# Initialize the values for this serie of tests
		initialize_values

		# Use the second file to extract the whole section of a tests serie
		partial_check_process=$partial2

		# Extract the section of the current tests serie
		extract_section "^;; " "^;;" "$check_process"

		# Parse all infos about arguments of manifest
		# Extract the manifest arguments section from the second partial file
		partial_check_process=$partial1
		extract_section "^; Manifest" "^; " "$partial2"

		# Initialize the arguments list
		manifest_arguments=""

		# Read each arguments and store them
		while read line
		do
			# Extract each argument by removing spaces or tabulations before a parenthesis
			add_arg="$(echo $line | sed 's/[ *|\t*](.*//')"
			# Then add this argument and follow it by &
			manifest_arguments="${manifest_arguments}${add_arg}&"
		done < "$partial_check_process"

		# Try to find all specific arguments needed for the tests
		keep_name_arg_only () {
			# Find the line for the given argument
			local argument=$(find_string "($1")
			# If a line exist for this argument
			if [ -n "$argument" ]; then
				# Keep only the name of the argument
				echo "$(echo "$argument" | cut -d '=' -f1)"
			fi
		}
		domain_arg=$(keep_name_arg_only "DOMAIN")
		path_arg=$(keep_name_arg_only "PATH")
		user_arg=$(keep_name_arg_only "USER")
		port_arg=$(keep_name_arg_only "PORT")
		public_arg=$(keep_name_arg_only "PUBLIC")
		# Find the values for public and private
		if [ -n "$public_arg" ]
		then
			line=$(find_string "(PUBLIC")
			public_public_arg=$(echo $line | grep -o "|public=[[:alnum:]]*" | cut -d "=" -f2))
			public_private_arg=$(echo $line | grep -o "|public=[[:alnum:]]*" | cut -d "=" -f2))
		fi


		# Parse all tests to perform
		# Extract the checks options section from the second partial file
		extract_section "^; Checks" "^; " "$partial2"

		read_check_option () {
			# Find the line for the given check option
			local line=$(find_string "^$1=")
			# Get only the value
			local value=$(echo "$line" | cut -d '=' -f2)
			# And return this value
			if [ "${value:0:1}" = "1" ]
			then
				all_test=$((all_test+1))
				return 1
			else
				return 0
			fi
		}

		pkg_linter=$(read_check_option pkg_linter)
		setup_sub_dir=$(read_check_option setup_sub_dir)
		setup_root=$(read_check_option setup_root)
		setup_nourl=$(read_check_option setup_nourl)
		setup_private=$(read_check_option setup_private)
		setup_public=$(read_check_option setup_public)
		upgrade=$(read_check_option upgrade)
		backup_restore=$(read_check_option backup_restore)
		multi_instance=$(read_check_option multi_instance)
		incorrect_path=$(read_check_option incorrect_path)
		port_already_use=$(read_check_option port_already_use)
		# For port_already_use, check if there is also a port number
		if [ $port_already_use -eq 1 ]
		then
			line=$(find_string "^port_already_use=")
			# If there is port number
			if echo "$line" | grep -q "([0-9]*)"
			then
				# Store the port number in port_arg and prefix it by # to means that not really a manifest arg
				port_arg="#$(echo "$line" | cut -d '(' -f2 | cut -d ')' -f1)"
			fi
		fi

		# Launch all tests successively
		TESTING_PROCESS
		# Print the final results of the tests
		TEST_RESULTS


if [ "$bash_mode" -ne 1 ]; then
	read -p "Appuyer sur une touche pour démarrer le scénario de test suivant..." < /dev/tty
fi

	done <<< "$(grep "^;; " "$check_process")"


else
# No check process...
fi


# dégradé
	domain_arg="null"
	path_arg="null"
	user_arg="null"
	public_arg="null"
	public_public_arg="null"
	public_private_arg="null"
	port_arg="null"






# Cette fonctionne détermine le niveau final de l'application, en prenant en compte d'éventuels forçages
APP_LEVEL () {
	level=0 	# Initialise le niveau final à 0
	# Niveau 1: L'application ne s'installe pas ou ne fonctionne pas après installation.
	if [ "${level[1]}" == "auto" ] || [ "${level[1]}" -eq 2 ]; then
		if [ "$GLOBAL_CHECK_SETUP" -eq 1 ] && [ "$GLOBAL_CHECK_REMOVE" -eq 1 ]
		then level[1]=2 ; else level[1]=0 ; fi
	fi

	# Niveau 2: L'application s'installe et se désinstalle dans toutes les configurations communes.
	if [ "${level[2]}" == "auto" ] || [ "${level[2]}" -eq 2 ]; then
		if 	[ "$GLOBAL_CHECK_SUB_DIR" -ne -1 ] && \
			[ "$GLOBAL_CHECK_REMOVE_SUBDIR" -ne -1 ] && \
			[ "$GLOBAL_CHECK_ROOT" -ne -1 ] && \
			[ "$GLOBAL_CHECK_REMOVE_ROOT" -ne -1 ] && \
			[ "$GLOBAL_CHECK_PRIVATE" -ne -1 ] && \
			[ "$GLOBAL_CHECK_PUBLIC" -ne -1 ] && \
			[ "$GLOBAL_CHECK_MULTI_INSTANCE" -ne -1 ]
		then level[2]=2 ; else level[2]=0 ; fi
	fi

	# Niveau 3: L'application supporte l'upgrade depuis une ancienne version du package.
	if [ "${level[3]}" == "auto" ] || [ "${level[3]}" == "2" ]; then
		if [ "$GLOBAL_CHECK_UPGRADE" -eq 1 ] || ( [ "${level[3]}" == "2" ] && [ "$GLOBAL_CHECK_UPGRADE" -ne -1 ] )
		then level[3]=2 ; else level[3]=0 ; fi
	fi

	# Niveau 4: L'application prend en charge de LDAP et/ou HTTP Auth. -- Doit être vérifié manuellement

	# Niveau 5: Aucune erreur dans package_linter.
	if [ "${level[5]}" == "auto" ] || [ "${level[5]}" == "2" ]; then
		if [ "$GLOBAL_LINTER" -eq 1 ] || ( [ "${level[5]}" == "2" ] && [ "$GLOBAL_LINTER" -ne -1 ] )
		then level[5]=2 ; else level[5]=0 ; fi
	fi

	# Niveau 6: L'application peut-être sauvegardée et restaurée sans erreurs sur la même machine ou une autre.
	if [ "${level[6]}" == "auto" ] || [ "${level[6]}" == "2" ]; then
		if [ "$GLOBAL_CHECK_BACKUP" -eq 1 ] && [ "$GLOBAL_CHECK_RESTORE" -eq 1 ] || ( [ "${level[6]}" == "2" ] && [ "$GLOBAL_CHECK_BACKUP" -ne -1 ] && [ "$GLOBAL_CHECK_RESTORE" -ne -1 ] )
		then level[6]=2 ; else level[6]=0 ; fi
	fi

	# Niveau 7: Aucune erreur dans package check.
	if [ "${level[7]}" == "auto" ] || [ "${level[7]}" == "2" ]; then
		if 	[ "$GLOBAL_CHECK_SETUP" -ne -1 ] && \
			[ "$GLOBAL_CHECK_REMOVE" -ne -1 ] && \
			[ "$GLOBAL_CHECK_SUB_DIR" -ne -1 ] && \
			[ "$GLOBAL_CHECK_REMOVE_SUBDIR" -ne -1 ] && \
			[ "$GLOBAL_CHECK_REMOVE_ROOT" -ne -1 ] && \
			[ "$GLOBAL_CHECK_UPGRADE" -ne -1 ] && \
			[ "$GLOBAL_CHECK_PRIVATE" -ne -1 ] && \
			[ "$GLOBAL_CHECK_PUBLIC" -ne -1 ] && \
			[ "$GLOBAL_CHECK_MULTI_INSTANCE" -ne -1 ] && \
			[ "$GLOBAL_CHECK_ADMIN" -ne -1 ] && \
			[ "$GLOBAL_CHECK_DOMAIN" -ne -1 ] && \
			[ "$GLOBAL_CHECK_PATH" -ne -1 ] && \
			[ "$GLOBAL_CHECK_PORT" -ne -1 ] && \
			[ "$GLOBAL_CHECK_BACKUP" -ne -1 ] && \
			[ "$GLOBAL_CHECK_RESTORE" -ne -1 ] && \
			[ "${level[5]}" -ge -1 ]	# Si tout les tests sont validés. Et si le level 5 est validé ou forcé.
		then level[7]=2 ; else level[7]=0 ; fi
	fi

	# Niveau 8: L'application respecte toutes les YEP recommandées. -- Doit être vérifié manuellement

	# Niveau 9: L'application respecte toutes les YEP optionnelles. -- Doit être vérifié manuellement

	# Niveau 10: L'application est jugée parfaite. -- Doit être vérifié manuellement

	# Calcule le niveau final
	for i in {1..10}; do
		if [ "${level[i]}" == "auto" ]; then
			level[i]=0	# Si des niveaux sont encore à auto, c'est une erreur de syntaxe dans le check_process, ils sont fixé à 0.
		elif [ "${level[i]}" == "na" ]; then
			continue	# Si le niveau est "non applicable" (na), il est ignoré dans le niveau final
		elif [ "${level[i]}" -ge 1 ]; then
			level=$i	# Si le niveau est validé, il est pris en compte dans le niveau final
		else
			break		# Dans les autres cas (niveau ni validé, ni ignoré), la boucle est stoppée. Le niveau final est donc le niveau précédemment validé
		fi
	done
}

TEST_RESULTS () {
	APP_LEVEL
	ECHO_FORMAT "\n\nPackage linter: "
	if [ "$GLOBAL_LINTER" -eq 1 ]; then
		ECHO_FORMAT "\t\t\tSUCCESS\n" "lgreen"
	elif [ "$GLOBAL_LINTER" -eq -1 ]; then
		ECHO_FORMAT "\t\t\tFAIL\n" "red"
	else
		ECHO_FORMAT "\t\t\tNot evaluated.\n" "white"
	fi
	ECHO_FORMAT "Installation: "
	if [ "$GLOBAL_CHECK_SETUP" -eq 1 ]; then
		ECHO_FORMAT "\t\t\t\tSUCCESS\n" "lgreen"
	elif [ "$GLOBAL_CHECK_SETUP" -eq -1 ]; then
		ECHO_FORMAT "\t\t\t\tFAIL\n" "red"
	else
		ECHO_FORMAT "\t\t\t\tNot evaluated.\n" "white"
	fi

	ECHO_FORMAT "Suppression: "
	if [ "$GLOBAL_CHECK_REMOVE" -eq 1 ]; then
		ECHO_FORMAT "\t\t\t\tSUCCESS\n" "lgreen"
	elif [ "$GLOBAL_CHECK_REMOVE" -eq -1 ]; then
		ECHO_FORMAT "\t\t\t\tFAIL\n" "red"
	else
		ECHO_FORMAT "\t\t\t\tNot evaluated.\n" "white"
	fi

	ECHO_FORMAT "Installation en sous-dossier: "
	if [ "$GLOBAL_CHECK_SUB_DIR" -eq 1 ]; then
		ECHO_FORMAT "\t\tSUCCESS\n" "lgreen"
	elif [ "$GLOBAL_CHECK_SUB_DIR" -eq -1 ]; then
		ECHO_FORMAT "\t\tFAIL\n" "red"
	else
		ECHO_FORMAT "\t\tNot evaluated.\n" "white"
	fi

	ECHO_FORMAT "Suppression depuis sous-dossier: "
	if [ "$GLOBAL_CHECK_REMOVE_SUBDIR" -eq 1 ]; then
		ECHO_FORMAT "\tSUCCESS\n" "lgreen"
	elif [ "$GLOBAL_CHECK_REMOVE_SUBDIR" -eq -1 ]; then
		ECHO_FORMAT "\tFAIL\n" "red"
	else
		ECHO_FORMAT "\tNot evaluated.\n" "white"
	fi

	ECHO_FORMAT "Installation à la racine: "
	if [ "$GLOBAL_CHECK_ROOT" -eq 1 ]; then
		ECHO_FORMAT "\t\tSUCCESS\n" "lgreen"
	elif [ "$GLOBAL_CHECK_ROOT" -eq -1 ]; then
		ECHO_FORMAT "\t\tFAIL\n" "red"
	else
		ECHO_FORMAT "\t\tNot evaluated.\n" "white"
	fi

	ECHO_FORMAT "Suppression depuis racine: "
	if [ "$GLOBAL_CHECK_REMOVE_ROOT" -eq 1 ]; then
		ECHO_FORMAT "\t\tSUCCESS\n" "lgreen"
	elif [ "$GLOBAL_CHECK_REMOVE_ROOT" -eq -1 ]; then
		ECHO_FORMAT "\t\tFAIL\n" "red"
	else
		ECHO_FORMAT "\t\tNot evaluated.\n" "white"
	fi

	ECHO_FORMAT "Upgrade: "
	if [ "$GLOBAL_CHECK_UPGRADE" -eq 1 ]; then
		ECHO_FORMAT "\t\t\t\tSUCCESS\n" "lgreen"
	elif [ "$GLOBAL_CHECK_UPGRADE" -eq -1 ]; then
		ECHO_FORMAT "\t\t\t\tFAIL\n" "red"
	else
		ECHO_FORMAT "\t\t\t\tNot evaluated.\n" "white"
	fi

	ECHO_FORMAT "Installation privée: "
	if [ "$GLOBAL_CHECK_PRIVATE" -eq 1 ]; then
		ECHO_FORMAT "\t\t\tSUCCESS\n" "lgreen"
	elif [ "$GLOBAL_CHECK_PRIVATE" -eq -1 ]; then
		ECHO_FORMAT "\t\t\tFAIL\n" "red"
	else
		ECHO_FORMAT "\t\t\tNot evaluated.\n" "white"
	fi

	ECHO_FORMAT "Installation publique: "
	if [ "$GLOBAL_CHECK_PUBLIC" -eq 1 ]; then
		ECHO_FORMAT "\t\t\tSUCCESS\n" "lgreen"
	elif [ "$GLOBAL_CHECK_PUBLIC" -eq -1 ]; then
		ECHO_FORMAT "\t\t\tFAIL\n" "red"
	else
		ECHO_FORMAT "\t\t\tNot evaluated.\n" "white"
	fi

	ECHO_FORMAT "Installation multi-instance: "
	if [ "$GLOBAL_CHECK_MULTI_INSTANCE" -eq 1 ]; then
		ECHO_FORMAT "\t\tSUCCESS\n" "lgreen"
	elif [ "$GLOBAL_CHECK_MULTI_INSTANCE" -eq -1 ]; then
		ECHO_FORMAT "\t\tFAIL\n" "red"
	else
		ECHO_FORMAT "\t\tNot evaluated.\n" "white"
	fi

	ECHO_FORMAT "Mauvais utilisateur: "
	if [ "$GLOBAL_CHECK_ADMIN" -eq 1 ]; then
		ECHO_FORMAT "\t\t\tSUCCESS\n" "lgreen"
	elif [ "$GLOBAL_CHECK_ADMIN" -eq -1 ]; then
		ECHO_FORMAT "\t\t\tFAIL\n" "red"
	else
		ECHO_FORMAT "\t\t\tNot evaluated.\n" "white"
	fi

	ECHO_FORMAT "Erreur de domaine: "
	if [ "$GLOBAL_CHECK_DOMAIN" -eq 1 ]; then
		ECHO_FORMAT "\t\t\tSUCCESS\n" "lgreen"
	elif [ "$GLOBAL_CHECK_DOMAIN" -eq -1 ]; then
		ECHO_FORMAT "\t\t\tFAIL\n" "red"
	else
		ECHO_FORMAT "\t\t\tNot evaluated.\n" "white"
	fi

	ECHO_FORMAT "Correction de path: "
	if [ "$GLOBAL_CHECK_PATH" -eq 1 ]; then
		ECHO_FORMAT "\t\t\tSUCCESS\n" "lgreen"
	elif [ "$GLOBAL_CHECK_PATH" -eq -1 ]; then
		ECHO_FORMAT "\t\t\tFAIL\n" "red"
	else
		ECHO_FORMAT "\t\t\tNot evaluated.\n" "white"
	fi

	ECHO_FORMAT "Port déjà utilisé: "
	if [ "$GLOBAL_CHECK_PORT" -eq 1 ]; then
		ECHO_FORMAT "\t\t\tSUCCESS\n" "lgreen"
	elif [ "$GLOBAL_CHECK_PORT" -eq -1 ]; then
		ECHO_FORMAT "\t\t\tFAIL\n" "red"
	else
		ECHO_FORMAT "\t\t\tNot evaluated.\n" "white"
	fi

# 	ECHO_FORMAT "Source corrompue: "
# 	if [ "$GLOBAL_CHECK_CORRUPT" -eq 1 ]; then
# 		ECHO_FORMAT "\t\t\tSUCCESS\n" "lgreen"
# 	elif [ "$GLOBAL_CHECK_CORRUPT" -eq -1 ]; then
# 		ECHO_FORMAT "\t\t\tFAIL\n" "red"
# 	else
# 		ECHO_FORMAT "\t\t\tNot evaluated.\n" "white"
# 	fi

# 	ECHO_FORMAT "Erreur de téléchargement de la source: "
# 	if [ "$GLOBAL_CHECK_DL" -eq 1 ]; then
# 		ECHO_FORMAT "\tSUCCESS\n" "lgreen"
# 	elif [ "$GLOBAL_CHECK_DL" -eq -1 ]; then
# 		ECHO_FORMAT "\tFAIL\n" "red"
# 	else
# 		ECHO_FORMAT "\tNot evaluated.\n" "white"
# 	fi

# 	ECHO_FORMAT "Dossier déjà utilisé: "
# 	if [ "$GLOBAL_CHECK_FINALPATH" -eq 1 ]; then
# 		ECHO_FORMAT "\t\t\tSUCCESS\n" "lgreen"
# 	elif [ "$GLOBAL_CHECK_FINALPATH" -eq -1 ]; then
# 		ECHO_FORMAT "\t\t\tFAIL\n" "red"
# 	else
# 		ECHO_FORMAT "\t\t\tNot evaluated.\n" "white"
# 	fi

	ECHO_FORMAT "Backup: "
	if [ "$GLOBAL_CHECK_BACKUP" -eq 1 ]; then
		ECHO_FORMAT "\t\t\t\tSUCCESS\n" "lgreen"
	elif [ "$GLOBAL_CHECK_BACKUP" -eq -1 ]; then
		ECHO_FORMAT "\t\t\t\tFAIL\n" "red"
	else
		ECHO_FORMAT "\t\t\t\tNot evaluated.\n" "white"
	fi

	ECHO_FORMAT "Restore: "
	if [ "$GLOBAL_CHECK_RESTORE" -eq 1 ]; then
		ECHO_FORMAT "\t\t\t\tSUCCESS\n" "lgreen"
	elif [ "$GLOBAL_CHECK_RESTORE" -eq -1 ]; then
		ECHO_FORMAT "\t\t\t\tFAIL\n" "red"
	else
		ECHO_FORMAT "\t\t\t\tNot evaluated.\n" "white"
	fi
	ECHO_FORMAT "\t\t    Notes de résultats: $note/$tnote - " "white" "bold"
	if [ "$note" -gt 0 ]
	then
		note=$(( note * 20 / tnote ))
	fi
		if [ "$note" -le 5 ]; then
			color_note="red"
			typo_note="bold"
			smiley=":'("	# La contribution à Shasha. Qui m'a forcé à ajouté les smiley sous la contrainte ;)
		elif [ "$note" -le 10 ]; then
			color_note="red"
			typo_note=""
			smiley=":("
		elif [ "$note" -le 15 ]; then
			color_note="lyellow"
			typo_note=""
			smiley=":s"
		elif [ "$note" -gt 15 ]; then
			color_note="lgreen"
			typo_note=""
			smiley=":)"
		fi
		if [ "$note" -ge 20 ]; then
			color_note="lgreen"
			typo_note="bold"
			smiley="\o/"
		fi
	ECHO_FORMAT "$note/20 $smiley\n" "$color_note" "$typo_note"
	ECHO_FORMAT "\t   Ensemble de tests effectués: $tnote/21\n\n" "white" "bold"

	# Affiche le niveau final
	ECHO_FORMAT "Niveau de l'application: $level\n" "white" "bold"
	for i in {1..10}
	do
		ECHO_FORMAT "\t   Niveau $i: "
		if [ "${level[i]}" == "na" ]; then
			ECHO_FORMAT "N/A\n"
		elif [ "${level[i]}" -ge 1 ]; then
			ECHO_FORMAT "1\n" "white" "bold"
		else
			ECHO_FORMAT "0\n"
		fi
	done
}


else	# Si le fichier check_process n'a pas été trouvé, fonctionne en mode dégradé.
	python "$script_dir/sub_scripts/ci/maniackc.py" "$package_path/manifest.json" > "$script_dir/manifest_extract" # Extrait les infos du manifest avec le script de Bram
	pkg_linter=1
	setup_sub_dir=1
	setup_root=1
	upgrade=1
	backup_restore=1
	multi_instance=1
	wrong_user=1
	wrong_path=1
	incorrect_path=1
	all_test=$((all_test+9))
	while read LIGNE
	do
		if echo "$LIGNE" | grep -q ":ynh.local"; then
			domain_arg=$(echo "$LIGNE" | grep ":ynh.local" | cut -d ':' -f1)	# Garde uniquement le nom de la clé.
		fi
		if echo "$LIGNE" | grep -q "path:"; then
			path_arg=$(echo "$LIGNE" | grep "path:" | cut -d ':' -f1)	# Garde uniquement le nom de la clé.
		fi
		if echo "$LIGNE" | grep -q "user:\|admin:"; then
			user_arg=$(echo "$LIGNE" | grep "user:\|admin:" | cut -d ':' -f1)	# Garde uniquement le nom de la clé.
		fi
		manifest_arguments="$manifest_arguments$(echo "$LIGNE" | cut -d ':' -f1,2 | sed s/:/=/)&"	# Ajoute l'argument du manifest
	done < "$script_dir/manifest_extract"
	if [ "$domain_arg" == "null" ]
	then
		ECHO_FORMAT "La clé de manifest du domaine n'a pas été trouvée.\n" "lyellow"
		setup_sub_dir=0
		setup_root=0
		multi_instance=0
		wrong_user=0
		incorrect_path=0
		all_test=$((all_test-5))
	fi
	if [ "$path_arg" == "null" ]
	then
		ECHO_FORMAT "La clé de manifest du path n'a pas été trouvée.\n" "lyellow"
		setup_root=0
		multi_instance=0
		incorrect_path=0
		all_test=$((all_test-3))
	fi
	if [ "$user_arg" == "null" ]
	then
		ECHO_FORMAT "La clé de manifest de l'user admin n'a pas été trouvée.\n" "lyellow"
		wrong_user=0
		all_test=$((all_test-1))
	fi
	if grep multi_instance "$package_path/manifest.json" | grep -q false
	then	# Retire le test multi instance si la clé du manifest est à false
		multi_instance=0
	fi
fi

TESTING_PROCESS
if [ "$no_lxc" -eq 0 ]; then
	LXC_TURNOFF
fi
TEST_RESULTS

app_name=${arg_app%_ynh}	# Supprime '_ynh' à la fin du nom de l'app
# Mail et bot xmpp pour le niveau de l'app
if [ "$level" -eq 0 ]; then
	message="L'application $(basename "$app_name") vient d'échouer aux tests d'intégration continue"
fi

if [ $type_exec_env -eq 2 ]
then
	# Récupère le nom du job dans le CI
	id=$(cat "$script_dir/../CI.lock")	# Récupère l'id du job en cours
	job=$(grep "$id" "$script_dir/../work_list" | cut -d ';' -f 3)	# Et récupère le nom du job dans le work_list
	job=${job// /%20}       # Replace all space by %20
	if [ -n "$job" ]; then
		job_log="/job/$job/lastBuild/console"
	fi
	# Prend le niveau précédemment calculé
	previous_level=$(grep "$(basename "$app_name")" "$script_dir/../auto_build/list_level_stable" | cut -d: -f2)
	if [ "$level" -ne 0 ]
	then
		message="L'application $(basename "$app_name")"
		if [ -z "$previous_level" ]; then
			message="$message vient d'atteindre le niveau $level"
		elif [ $level -eq $previous_level ]; then
			message="$message reste au niveau $level"
		elif [ $level -gt $previous_level ]; then
			message="$message monte du niveau $previous_level au niveau $level"
		elif [ $level -lt $previous_level ]; then
			message="$message descend du niveau $previous_level au niveau $level"
		fi
	fi
	ci_path=$(grep "main_domain=" "$script_dir/../auto_build/auto.conf" | cut -d= -f2)/$(grep "CI_PATH=" "$script_dir/../auto_build/auto.conf" | cut -d= -f2)
	message="$message sur https://$ci_path$job_log"
	if ! echo "$job" | grep -q "(testing)\|(unstable)"; then	# Notifie par xmpp seulement sur stable
		"$script_dir/../auto_build/xmpp_bot/xmpp_post.sh" "$message"	# Notifie sur le salon apps
	fi
fi

if [ "$level" -eq 0 ] && [ $type_exec_env -eq 1 ]
then	# Si l'app est au niveau 0, et que le test tourne en CI, envoi un mail d'avertissement.
	dest=$(cat "$package_path/manifest.json" | grep '\"email\": ' | cut -d '"' -f 4)	# Utilise l'adresse du mainteneur de l'application
	ci_path=$(grep "CI_URL=" "$script_dir/../config" | cut -d= -f2)
	if [ -n "$ci_path" ]; then
		message="$message sur $ci_path"
	fi
	mail -s "[YunoHost] Échec d'installation d'une application dans le CI" "$dest" <<< "$message"	# Envoi un avertissement par mail.
fi

echo "Le log complet des installations et suppressions est disponible dans le fichier $complete_log"
# Clean
