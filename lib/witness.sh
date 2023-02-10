
set_witness_files () {
    # Create files to check if the remove script does not remove them accidentally
    log_debug "Create witness files..."

    create_witness_file () {
        [ "$2" = "file" ] && local action="touch" || local action="mkdir -p"
        RUN_INSIDE_LXC timeout --signal TERM 10 $action $1
    }

    # Nginx conf
    create_witness_file "/etc/nginx/conf.d/$DOMAIN.d/witnessfile.conf" file
    create_witness_file "/etc/nginx/conf.d/$SUBDOMAIN.d/witnessfile.conf" file

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
    create_witness_file "/etc/php/$DEFAULT_PHP_VERSION/fpm/pool.d/witnessfile.conf" file

    # Config logrotate
    create_witness_file "/etc/logrotate.d/witnessfile" file

    # Config systemd
    create_witness_file "/etc/systemd/system/witnessfile.service" file

    # Database
    RUN_INSIDE_LXC mysqladmin --wait status > /dev/null 2>&1
    echo "CREATE DATABASE witnessdb" | RUN_INSIDE_LXC mysql --wait > /dev/null 2>&1
}

check_witness_files () {
    # Check all the witness files, to verify if them still here

    check_file_exist () {
        if RUN_INSIDE_LXC test ! -e "$1"
        then
            log_error "The file $1 is missing ! Something gone wrong !"
            SET_RESULT "failure" witness
        fi
    }

    sleep 2

    # Nginx conf
    check_file_exist "/etc/nginx/conf.d/$DOMAIN.d/witnessfile.conf"
    check_file_exist "/etc/nginx/conf.d/$SUBDOMAIN.d/witnessfile.conf"

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
    check_file_exist "/etc/php/$DEFAULT_PHP_VERSION/fpm/pool.d/witnessfile.conf"

    # Config logrotate
    check_file_exist "/etc/logrotate.d/witnessfile"

    # Config systemd
    check_file_exist "/etc/systemd/system/witnessfile.service"

    # Database
    if ! RUN_INSIDE_LXC mysqlshow witnessdb > /dev/null 2>&1
    then
        log_error "The database witnessdb is missing ! Something gone wrong !"
        SET_RESULT "failure" witness
        return 1
    fi
}
