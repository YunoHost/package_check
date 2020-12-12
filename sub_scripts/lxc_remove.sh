#!/bin/bash

cd $(dirname $(realpath $0) | sed 's@/sub_scripts$@@g')
source "./sub_scripts/common.sh"

# Check user
assert_we_are_the_setup_user

touch "$lock_file"


log_title "Retire l'ip forwarding."

sudo rm -f /etc/sysctl.d/lxc_pchecker.conf
sudo sysctl -p


log_title "Désactive le bridge réseau"

sudo ifdown --force $LXC_BRIDGE


log_title "Supprime le brige réseau"

sudo rm -f /etc/network/interfaces.d/$LXC_BRIDGE


log_title "Suppression de la machine et de son snapshots"

sudo lxc-snapshot -n $LXC_NAME -d snap0
for SNAP in $(sudo ls $LXC_SNAPSHOTS/snap_*install 2>/dev/null)
do
    sudo lxc-snapshot -n $LXC_NAME -d $(basename $SNAP)
done
sudo rm -f /var/lib/lxcsnaps/$LXC_NAME/snap0.tar.gz
sudo lxc-destroy -n $LXC_NAME -f

log_title "Suppression des lignes de pchecker_lxc dans $HOME/.ssh/config"

BEGIN_LINE=$(cat $HOME/.ssh/config | grep -n "^# ssh pchecker_lxc$" | cut -d':' -f 1 | tail -n1)
sed -i "$BEGIN_LINE,/^IdentityFile/d" $HOME/.ssh/config
