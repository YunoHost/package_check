#!/bin/bash

# Récupère le dossier du script
if [ "${0:0:1}" == "/" ]; then script_dir="$(dirname "$0")"; else script_dir="$(echo $PWD/$(dirname "$0" | cut -d '.' -f2) | sed 's@/$@@')"; fi

LXC_NAME=$(cat "$script_dir/lxc_build.sh" | grep LXC_NAME= | cut -d '=' -f2)

# Check user
if [ "$(whoami)" != "$(cat "$script_dir/setup_user")" ] && test -e "$script_dir/setup_user"; then
	echo -e "\e[91mCe script doit être exécuté avec l'utilisateur $(cat "$script_dir/setup_user") !\nL'utilisateur actuel est $(whoami)."
	echo -en "\e[0m"
	exit 0
fi

sudo rm "$script_dir/../pcheck.lock" # Retire le lock

echo "> Retire l'ip forwarding."
sudo rm /etc/sysctl.d/lxc_pchecker.conf
sudo sysctl -p

echo "> Désactive le bridge réseau"
sudo ifdown --force lxc-pchecker

echo "> Supprime le brige réseau"
sudo rm /etc/network/interfaces.d/lxc-pchecker

echo "> Suppression de la machine et de son snapshots"
sudo lxc-snapshot -n $LXC_NAME -d snap0
sudo rm -f /var/lib/lxcsnaps/$LXC_NAME/snap0.tar.gz
sudo lxc-destroy -n $LXC_NAME -f

echo "> Remove lxc lxctl"
sudo apt-get remove lxc lxctl

echo "> Suppression des lignes de pchecker_lxc dans .ssh/config"
BEGIN_LINE=$(cat $HOME/.ssh/config | grep -n "^# ssh pchecker_lxc$" | cut -d':' -f 1)
sed -i "$BEGIN_LINE,/^IdentityFile/d" $HOME/.ssh/config
