#!/bin/bash

# Récupère le dossier du script
if [ "${0:0:1}" == "/" ]; then script_dir="$(dirname "$0")"; else script_dir="$(echo $PWD/$(dirname "$0" | cut -d '.' -f2) | sed 's@/$@@')"; fi

pcheck_config="$script_dir/../config"
LXC_NAME=$(cat "$pcheck_config" | grep LXC_NAME= | cut -d '=' -f2)
LXC_BRIDGE=$(cat "$pcheck_config" | grep LXC_BRIDGE= | cut -d '=' -f2)

# Check user
if [ "$(whoami)" != "$(cat "$script_dir/setup_user")" ] && test -e "$script_dir/setup_user"; then
	echo -e "\e[91mCe script doit être exécuté avec l'utilisateur $(cat "$script_dir/setup_user") !\nL'utilisateur actuel est $(whoami)."
	echo -en "\e[0m"
	exit 0
fi

echo_bold () {
	if [ $quiet_remove -eq 0 ]
	then
		echo -e "\e[1m> $1\e[0m"
	fi
}

quiet_remove=0
# Check argument "quiet"
if [ "$1" = "quiet" ]
then
	quiet_remove=1
fi

touch "$script_dir/../pcheck.lock" # Met en place le lock de Package check

echo_bold "Retire l'ip forwarding."
sudo rm /etc/sysctl.d/lxc_pchecker.conf
sudo sysctl -p

echo_bold "Désactive le bridge réseau"
sudo ifdown --force $LXC_BRIDGE

echo_bold "Supprime le brige réseau"
sudo rm /etc/network/interfaces.d/$LXC_BRIDGE

echo_bold "Suppression de la machine et de son snapshots"
sudo lxc-snapshot -n $LXC_NAME -d snap0
sudo lxc-snapshot -n $LXC_NAME -d snap1
sudo lxc-snapshot -n $LXC_NAME -d snap2
sudo rm -f /var/lib/lxcsnaps/$LXC_NAME/snap0.tar.gz
sudo lxc-destroy -n $LXC_NAME -f

if [ $quiet_remove -eq 0 ]
then
	echo_bold "Remove lxc lxctl"
	sudo apt-get remove lxc lxctl
fi

echo_bold "Suppression des lignes de pchecker_lxc dans $HOME/.ssh/config"
BEGIN_LINE=$(cat $HOME/.ssh/config | grep -n "^# ssh pchecker_lxc$" | cut -d':' -f 1 | tail -n1)
sed -i "$BEGIN_LINE,/^IdentityFile/d" $HOME/.ssh/config
