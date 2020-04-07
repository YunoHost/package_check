#!/bin/bash

echo "Loads functions from log_extractor.sh"

ECHO_FORMAT () {
	# Simply an echo with color and typo
	# $2 = color
	# $3 = typo
	# Last arg = clog

	if [ "$2" == "red" ]; then
		echo -en "\e[91m"
	fi
	if [ "$2" == "lyellow" ]; then
		echo -en "\e[93m"
	fi
	if [ "$2" == "lgreen" ]; then
		echo -en "\e[92m"
	fi
	if [ "$2" == "blue" ]; then
		echo -en "\e[94m"
	fi
	if [ "$2" == "white" ]; then
		echo -en "\e[97m"
	fi
	if [ "$3" == "bold" ]; then
		echo -en "\e[1m"
	fi
	if [ "$3" == "underlined" ]; then
		echo -en "\e[4m"
	fi
	local copy_log=--
	# If 'clog' is given as argument, the echo command will be duplicated into the complete log.
	if [ "$2" == "clog" ] || [ "$3" == "clog" ] || [ "$4" == "clog" ]; then
		copy_log="$complete_log"
	fi
	echo -en "$1" | tee -a "$test_result" "$copy_log"
	echo -en "\e[0m"
}

COPY_LOG () {
	# Extract A small part of $yunohost_log.
	# $1 = 1 or 2. If '1', count the number of line of the current log file.
	#			   If '2', copy the log from the last read line.

	if [ $1 -eq 1 ]; then
		# Count the number of lines in YunoHost log
		log_line=$(sudo wc --lines "$yunohost_log" | cut --delimiter=' ' --fields=1)
		# Ignore the first line, it's duplicated of the previous log
		log_line=$(( $log_line + 1 ))
		# Erase the temporary log
		> "$temp_log"
	fi
	if [ $1 -eq 2 ]; then
		# Copy the log from the last read line
		sudo tail --lines=+$log_line "$yunohost_log" >> "$temp_log"
	fi
}

FALSE_ERRORS_DETECTION () {
    # Detect false positive errors.
    false_positive_error=0

    # Detect network error
    if grep --quiet "Network is unreachable" "$temp_result"
    then
        false_positive_error=1
        false_positive_error_cond="network"
    fi

    # Detect DNS error
    if grep --quiet "Temporary failure resolving" "$temp_result"
    then
        false_positive_error=1
        false_positive_error_cond="DNS failure"
    fi
    if grep --quiet "unable to resolve host address" "$temp_result"
    then
        false_positive_error=1
        false_positive_error_cond="DNS failure"
    fi

    # Detect Corrupt source
    if grep --quiet "Corrupt source" "$temp_result"
    then
        false_positive_error=1
        false_positive_error_cond="corrupt source"
    fi
}

PARSE_LOG () {
	# Print all errors and warning found in the log.

	while read log_read_line
	do
		if echo "$log_read_line" | grep --quiet "^>ERROR: "; then
			# Print a red "Error"
			ECHO_FORMAT "Error:" "red" "underlined"
			# And print the error itself
			ECHO_FORMAT " $(echo "$log_read_line\n" | sed 's/^>ERROR: //')" "red"
			YUNOHOST_RESULT=1
			YUNOHOST_REMOVE=1
		fi
		if echo "$log_read_line" | grep --quiet "^>WARNING: "; then
			# Print a yellow "Warning:"
			ECHO_FORMAT "Warning:" "lyellow" "underlined"
			# And print the warning itself
			ECHO_FORMAT " $(echo "$log_read_line\n" | sed 's/^>WARNING: //')" "lyellow"
		fi
		if echo "$log_read_line" | grep --quiet "^>INFO: "; then
			# Print a white "Info:"
			ECHO_FORMAT "Info:" "white" "underlined"
			# And print the info itself
			ECHO_FORMAT " $(echo "$log_read_line\n" | sed 's/^>INFO: //')" "white"
		fi
	done < "$temp_result"
}

CLEAR_LOG () {
	# Remove all knew useless warning lines.

	# Useless warnings from wget
	sed --in-place '/^>WARNING: yunohost\.hook <lambda> - \[[[:digit:].]*\] *$/d' "$temp_result"	# Empty line foregoing wget progression
	sed --in-place '/^>WARNING: yunohost\.hook <lambda> - \[[[:digit:].]*\] *[[:digit:]]*K \.* /d' "$temp_result"	# Wget progression
	sed --in-place '/% Total    % Received % Xferd/d' "$temp_result"	# Wget statistics
	sed --in-place '/Dload  Upload   Total   Spent/d' "$temp_result"	# Wget statistics (again)
	sed --in-place '/--:--:-- --:--:-- --:--:--/d' "$temp_result"	# Wget statistics (Yes, again...)

	# Useless warning from yunohost backup.
	sed --in-place '/^>WARNING: yunohost.backup backup_restore - \[[[:digit:].]*\] YunoHost est déjà installé$/d' "$temp_result"

	# "processing action" INFO lines
	sed --in-place '/^>INFO: .* - processing action/d' "$temp_result"
	# Clean INFO lines
	sed --in-place 's/^\(>INFO: \)yunohost\.hook <lambda> - \[[[:digit:].]*\]/\1/g' "$temp_result"

	# "This feature is experimental"
	sed --in-place '/^>WARNING: .* This feature is experimental and not considered stable/d' "$temp_result"

	# "moulinette.core translate"
	sed --in-place '/^>ERROR: moulinette.core translate/d' "$temp_result"

	# Empty lines
	sed --in-place '/^$/d' "$temp_result"
}

LOG_EXTRACTOR () {
	# Analyse the log to extract "warning" and "error" lines

	# Copy the log from the last read line.
	COPY_LOG 2

	# Erase the temporary result file
	> "$temp_result"
	# Duplicate the part of the yunohost log into the complete log.
	cat "$temp_log" >> "$complete_log"
	# Find all errors, warnings and infos in the log file
	grep --extended-regexp " ERROR    | WARNING  | INFO     |yunohost.*: error:" "$temp_log" >> "$temp_result"
	sed -i 's/^.* ERROR */>ERROR: /' "$temp_result"
	sed -i 's/^.* WARNING */>WARNING: /' "$temp_result"
	sed -i 's/^.* INFO */>INFO: /' "$temp_result"

	CLEAR_LOG	# Remove all knew useless warning lines.
	PARSE_LOG	# Print all errors and warning found in the log.
	FALSE_ERRORS_DETECTION	# Detect if there's a temporary error that shouldn't impact the test.
}
