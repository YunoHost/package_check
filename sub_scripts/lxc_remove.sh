#!/bin/bash

LXC_NAME=$(cat sub_scripts/lxc_build.sh | grep LXC_NAME= | cut -d '=' -f2)

# Check root
CHECK_ROOT=$EUID
if [ -z "$CHECK_ROOT" ];then CHECK_ROOT=0;fi
if [ $CHECK_ROOT -eq 0 ]
then	# $EUID est vide sur une exécution avec sudo. Et vaut 0 pour root
   echo "Le script ne doit pas être exécuté avec les droits root"
   exit 1
fi

echo "Retire l'ip forwarding."
sudo rm /etc/sysctl.d/lxc_pchecker.conf
sudo sysctl -p

echo "Désactive le bridge réseau"
sudo ifdown lxc-pchecker

echo "Supprime le brige réseau"
sudo rm /etc/network/interfaces.d/lxc-pchecker

echo "Suppression de la machine et de son snapshots"
sudo lxc-snapshot -n $LXC_NAME -d snap0
sudo rm -f /var/lib/lxcsnaps/$LXC_NAME/snap0.tar.gz
sudo lxc-destroy -n $LXC_NAME -f

echo "Remove lxc lxctl"
sudo apt-get remove lxc lxctl

echo "Suppression des lignes de pchecker_lxc dans .ssh/config"
BEGIN_LINE=$(cat $HOME/.ssh/config | grep -n "^# ssh pchecker_lxc$" | cut -d':' -f 1)
sed -i "$BEGIN_LINE,/^IdentityFile/d" $HOME/.ssh/config
