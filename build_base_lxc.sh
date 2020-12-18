#!/bin/bash

cd $(dirname $(realpath $0))
source "./lib/common.sh"

function rebuild_base_lxc()
{
    check_lxd_setup

    set -x
    sudo lxc info $LXC_BASE >/dev/null && sudo lxc delete $LXC_BASE --force
    sudo lxc launch images:debian/$DIST/$ARCH $LXC_BASE
    sudo lxc config set $LXC_BASE security.privileged true
    sudo lxc config set $LXC_BASE security.nesting true # Need this for apparmor for some reason
    sudo lxc restart $LXC_BASE
    sleep 5
    
    IN_LXC="sudo lxc exec $LXC_BASE --"
    
    INSTALL_SCRIPT="https://install.yunohost.org/$DIST"
    $IN_LXC apt install curl -y
    $IN_LXC /bin/bash -c "curl $INSTALL_SCRIPT | bash -s -- -a $YNH_BRANCH"
    
    $IN_LXC systemctl -q stop apt-daily.timer
    $IN_LXC systemctl -q stop apt-daily-upgrade.timer
    $IN_LXC systemctl -q stop apt-daily.service
    $IN_LXC systemctl -q stop apt-daily-upgrade.service 
    $IN_LXC systemctl -q disable apt-daily.timer
    $IN_LXC systemctl -q disable apt-daily-upgrade.timer
    $IN_LXC systemctl -q disable apt-daily.service
    $IN_LXC systemctl -q disable apt-daily-upgrade.service
    $IN_LXC rm -f /etc/cron.daily/apt-compat
    $IN_LXC cp /bin/true /usr/lib/apt/apt.systemd.daily

    # Disable password strength check
    $IN_LXC yunohost tools postinstall --domain $DOMAIN --password $YUNO_PWD --force-password

    $IN_LXC yunohost settings set security.password.admin.strength -v -1
    $IN_LXC yunohost settings set security.password.user.strength -v -1

    $IN_LXC yunohost domain add $SUBDOMAIN
    TEST_USER_DISPLAY=${TEST_USER//"_"/""}
    $IN_LXC yunohost user create $TEST_USER --firstname $TEST_USER_DISPLAY --mail $TEST_USER@$DOMAIN --lastname $TEST_USER_DISPLAY --password '$YUNO_PWD'

    $IN_LXC yunohost --version

    sudo lxc stop $LXC_BASE
    sudo lxc image delete $LXC_BASE
    sudo lxc publish $LXC_BASE --alias $LXC_BASE
    set +x
}

rebuild_base_lxc 2>&1 | tee -a "./build_base_lxc.log"
