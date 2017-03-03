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

touch "$script_dir/../pcheck.lock" # Met en place le lock de Package check

echo -e "\e[1m> Retire l'ip forwarding.\e[0m"
sudo rm /etc/sysctl.d/lxc_pchecker.conf
sudo sysctl -p

echo -e "\e[1m> Désactive le bridge réseau\e[0m"
sudo ifdown --force $LXC_BRIDGE

echo -e "\e[1m> Supprime le brige réseau\e[0m"
sudo rm /etc/network/interfaces.d/$LXC_BRIDGE

echo -e "\e[1m> Suppression de la machine et de son snapshots\e[0m"
sudo lxc-snapshot -n $LXC_NAME -d snap0
sudo rm -f /var/lib/lxcsnaps/$LXC_NAME/snap0.tar.gz
sudo lxc-destroy -n $LXC_NAME -f

echo -e "\e[1m> Remove lxc lxctl\e[0m"
sudo apt-get remove lxc lxctl

echo -e "\e[1m> Suppression des lignes de pchecker_lxc dans .ssh/config\e[0m"
BEGIN_LINE=$(cat $HOME/.ssh/config | grep -n "^# ssh pchecker_lxc$" | cut -d':' -f 1)
sed -i "$BEGIN_LINE,/^IdentityFile/d" $HOME/.ssh/config
