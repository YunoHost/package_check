#!/bin/bash

cd $(dirname $(realpath $0) | sed 's@/sub_scripts$@@g')
source "./sub_scripts/common.sh"

function check_lxd_setup()
{
    # Check lxd is installed somehow
    [[ -e /snap/bin/lxd ]] || which lxd &>/dev/null \
        || critical "You need to have LXD installed. Refer to the README to know how to install it."

    # Check that we'll be able to use lxc/lxd using sudo (for which the PATH is defined in /etc/sudoers and probably doesn't include /snap/bin)
    if [[ ! -e /usr/bin/lxc ]] && [[ ! -e /usr/bin/lxd ]]
    then
        [[ -e /usr/local/bin/lxc ]] && [[ -e /usr/local/bin/lxd ]] \
            || critical "You might want to add lxc and lxd inside /usr/local/bin so that there's no tricky PATH issue with sudo. If you installed lxd/lxc with snapd, this should do the trick: sudo ln -s /snap/bin/lxc /usr/local/bin/lxc && sudo ln -s /snap/bin/lxd /usr/local/bin/lxd"
    fi

    ip a | grep -q lxdbr0 \
        || critical "There is no 'lxdbr0' interface... Did you ran 'lxd init' ?"
}

function rebuild_ynh_appci_base()
{
    check_lxd_setup

    local DIST=${1:-$DEFAULT_DIST}
    local BOX=${2:-ynh-appci}-${DIST}

    set -x
    sudo lxc info $BOX-base >/dev/null && sudo lxc delete $BOX-base --force
    sudo lxc launch images:debian/$DIST/$ARCH $BOX-base
    sudo lxc config set $BOX-base security.privileged true
    sudo lxc config set $BOX-base security.nesting true # Need this for apparmor for some reason
    sudo lxc restart $BOX-base
    sleep 5
    
    IN_LXC="sudo lxc exec $BOX-base -- /bin/bash -c"
    
    INSTALL_SCRIPT="https://install.yunohost.org/$DIST"
    $IN_LXC "apt install curl -y"
    $IN_LXC "curl $INSTALL_SCRIPT | bash -s -- -a $YNH_BRANCH"
    
    $IN_LXC "systemctl -q stop apt-daily.timer"
    $IN_LXC "systemctl -q stop apt-daily-upgrade.timer"
    $IN_LXC "systemctl -q stop apt-daily.service"
    $IN_LXC "systemctl -q stop apt-daily-upgrade.service "
    $IN_LXC "systemctl -q disable apt-daily.timer"
    $IN_LXC "systemctl -q disable apt-daily-upgrade.timer"
    $IN_LXC "systemctl -q disable apt-daily.service"
    $IN_LXC "systemctl -q disable apt-daily-upgrade.service"
    $IN_LXC "rm -f /etc/cron.daily/apt-compat"
    $IN_LXC "cp /bin/true /usr/lib/apt/apt.systemd.daily"

    # Disable password strength check
    $IN_LXC "yunohost tools postinstall --domain $DOMAIN --password $YUNO_PWD --force-password"

    $IN_LXC "yunohost settings set security.password.admin.strength -v -1"
    $IN_LXC "yunohost settings set security.password.user.strength -v -1"

    $IN_LXC "yunohost domain add $SUBDOMAIN"
    TEST_USER_DISPLAY=${TEST_USER//"_"/""}
    $IN_LXC "yunohost user create $TEST_USER --firstname $TEST_USER_DISPLAY --mail $TEST_USER@$DOMAIN --lastname $TEST_USER_DISPLAY --password '$YUNO_PWD'"

    $IN_LXC "yunohost --version"

    sudo lxc stop $BOX-base
    sudo lxc publish $BOX-base --alias $BOX-base
    set +x
}

rebuild_ynh_appci_base 2>&1 | tee -a "./lxc_build.log"
