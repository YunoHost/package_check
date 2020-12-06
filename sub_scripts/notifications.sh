#!/bin/bash

#=================================================
# Determine if it's a CI environment
#=================================================

# By default, it's a standalone execution.
type_exec_env=0
# CI environment
[ -e "./../config" ] && type_exec_env=1
# Official CI environment
[ -e "./../auto_build/auto.conf" ] && type_exec_env=2


# Try to find a optionnal email address to notify the maintainer
# In this case, this email will be used instead of the email from the manifest.
notification_email="$(grep -m1 "^Email=" $TEST_CONTEXT/check_process.options | cut -d '=' -f2)"

# Try to find a optionnal option for the grade of notification
notification_mode="$(grep -m1 "^Notification=" $TEST_CONTEXT/check_process.options | cut -d '=' -f2)"


#=================================================
# Notification grade
#=================================================

notif_grade () {
    # Check the level of notification from the check_process.
    # Echo 1 if the grade is reached

    compare_grade ()
    {
        if echo "$notification_mode" | grep -q "$1"; then
            echo 1
        else
            echo 0
        fi
    }

    case "$1" in
        all)
            # If 'all' is needed, only a grade of notification at 'all' can match
            compare_grade "^all$"
            ;;
        change)
            # If 'change' is needed, notification at 'all' or 'change' can match
            compare_grade "^all$\|^change$"
            ;;
        down)
            # If 'down' is needed, notification at 'all', 'change' or 'down' match
            compare_grade "^all$\|^change$\|^down$"
            ;;
        *)
            echo 0
            ;;
    esac
}

#=================================================
# Inform of the results by XMPP and/or by mail
#=================================================

send_mail=0

# If package check it's in the official CI environment
# Check the level variation
if [ $type_exec_env -eq 2 ]
then

    # Get the job name, stored in the work_list
    job=$(head -n1 "./../work_list" | cut -d ';' -f 3)

    # Identify the type of test, stable (0), testing (1) or unstable (2)
    # Default stable
    test_type=0
    message=""
    if echo "$job" | grep -q "(testing)"
    then
        message="(TESTING) "
        test_type=1
    elif echo "$job" | grep -q "(unstable)"
    then
        message="(UNSTABLE) "
        test_type=2
    fi

    # Build the log path (and replace all space by %20 in the job name)
    if [ -n "$job" ]; then
        if systemctl list-units | grep --quiet jenkins
        then
            job_log="/job/${job// /%20}/lastBuild/console"
        elif systemctl list-units | grep --quiet yunorunner
        then
            # Get the directory of YunoRunner
            ci_dir="$(grep WorkingDirectory= /etc/systemd/system/yunorunner.service | cut -d= -f2)"
            # List the jobs from YunoRunner and grep the job (without Community or Official).
            job_id="$(cd "$ci_dir"; ve3/bin/python ciclic list | grep ${job%% *} | head -n1)"
            # Keep only the id of the job, by removing everything after -
            job_id="${job_id%% -*}"
            # And remove any space before the id.
            job_id="${job_id##* }"
            job_log="/job/$job_id"
        fi
    fi

    # If it's a test on testing or unstable
    if [ $test_type -gt 0 ]
    then
        # Remove unstable or testing of the job name to find its stable version in the level list
        job="${job% (*)}"
    fi

    # Get the previous level, found in the file list_level_stable
    previous_level=$(grep "^$job:" "./../auto_build/list_level_stable" | cut -d: -f2)

    # Print the variation of the level. If this level is different than 0
    if [ $global_level -gt 0 ]
    then
        message="${message}Application $app_id"
        # If non previous level was found
        if [ -z "$previous_level" ]; then
            message="$message just reach the level $global_level"
            send_mail=$(notif_grade all)
            # If the level stays the same
        elif [ $global_level -eq $previous_level ]; then
            message="$message stays at level $global_level"
            # Need notification at 'all' to notify by email
            send_mail=$(notif_grade all)
            # If the level go up
        elif [ $global_level -gt $previous_level ]; then
            message="$message rise from level $previous_level to level $global_level"
            # Need notification at 'change' to notify by email
            send_mail=$(notif_grade change)
            # If the level go down
        elif [ $global_level -lt $previous_level ]; then
            message="$message go down from level $previous_level to level $global_level"
            # Need notification at 'down' to notify by email
            send_mail=$(notif_grade down)
        fi
    fi
fi

# If the app completely failed and obtained 0
if [ $global_level -eq 0 ]
then
    message="${message}Application $app_id has completely failed the continuous integration tests"

    # Always send an email if the app failed
    send_mail=1
fi

subject="[YunoHost] $message"

# If the test was perform in the official CI environment
# Add the log address
# And inform with xmpp
if [ $type_exec_env -eq 2 ]
then

    # Build the address of the server from auto.conf
    ci_path=$(grep "DOMAIN=" "./../auto_build/auto.conf" | cut -d= -f2)/$(grep "CI_PATH=" "./../auto_build/auto.conf" | cut -d= -f2)

    # Add the log adress to the message
    message="$message on https://$ci_path$job_log"

    # Send a xmpp notification on the chat room "apps"
    # Only for a test with the stable version of YunoHost
    if [ $test_type -eq 0 ]
    then
        "./../auto_build/xmpp_bot/xmpp_post.sh" "$message" > /dev/null 2>&1
    fi
fi

# Send a mail to main maintainer according to notification option in the check_process.
# Only if package check is in a CI environment (Official or not)
if [ $type_exec_env -ge 1 ] && [ $send_mail -eq 1 ]
then

    # Add a 'from' header for the official CI only.
    # Apparently, this trick is not needed anymore !?
    #	if [ $type_exec_env -eq 2 ]; then
    #		from_yuno="-a \"From: yunohost@yunohost.org\""
    #	fi

    # Get the maintainer email from the manifest. If it doesn't found if the check_process
    if [ -z "$notification_email" ]; then
        notification_email=$(grep '\"email\": ' "$package_path/manifest.json" | cut -d '"' -f 4)
    fi

    # Send the message by mail, if a address has been find
    if [ -n "$notification_email" ]; then
        mail $from_yuno -s "$subject" "$notification_email" <<< "$message"
    fi
fi


