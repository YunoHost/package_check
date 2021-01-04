#!/bin/bash

function launch_new_lxc()
{
    lxc info $LXC_BASE >/dev/null && lxc delete $LXC_BASE --force

    if [ $(get_arch) = $ARCH ];
    then
        lxc launch images:debian/$DIST/$ARCH $LXC_BASE -c security.privileged=true -c security.nesting=true
    else
        lxc image info $LXC_BASE >/dev/null && lxc image delete $LXC_BASE

        tmp_dir=$(mktemp -d)
        pushd $tmp_dir

        lxc image export images:debian/$DIST/$ARCH

        tar xJf lxd.tar.xz
        local current_arch=$(get_arch)
        sed -i "0,/architecture: $ARCH/s//architecture: $current_arch/" metadata.yaml
        tar cJf lxd.tar.xz metadata.yaml templates
        lxc image import lxd.tar.xz rootfs.squashfs --alias $LXC_BASE
        popd
        rm -rf "$tmp_dir"

        lxc launch $LXC_BASE $LXC_BASE -c security.privileged=true -c security.nesting=true
    fi
}

function rebuild_base_lxc()
{
    check_lxd_setup

    set -x
    launch_new_lxc
    sleep 5
    
    IN_LXC="lxc exec $LXC_BASE --"
    
    INSTALL_SCRIPT="https://install.yunohost.org/$DIST"
    $IN_LXC apt install curl -y
    $IN_LXC /bin/bash -c "curl $INSTALL_SCRIPT | bash -s -- -a -d $YNH_BRANCH"
    
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
    $IN_LXC yunohost user create $TEST_USER --firstname $TEST_USER_DISPLAY --mail $TEST_USER@$DOMAIN --lastname $TEST_USER_DISPLAY --password "$YUNO_PWD"

    $IN_LXC yunohost --version

    lxc stop $LXC_BASE
    lxc image delete $LXC_BASE
    lxc publish $LXC_BASE --alias $LXC_BASE --public
    lxc delete $LXC_BASE
    set +x
}
