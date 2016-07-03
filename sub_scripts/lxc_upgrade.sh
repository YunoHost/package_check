#!/bin/bash

PLAGE_IP=$(cat sub_scripts/lxc_build.sh | grep PLAGE_IP= | cut -d '"' -f2)
LXC_NAME=$(cat sub_scripts/lxc_build.sh | grep LXC_NAME= | cut -d '=' -f2)

echo "Active le bridge réseau"
sudo ifup lxc-pchecker

echo "Configure le parefeu"
sudo iptables -A FORWARD -i lxc-pchecker -o eth0 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o lxc-pchecker -j ACCEPT
sudo iptables -t nat -A POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE

echo "Démarrage de la machine"
sudo lxc-start -n $LXC_NAME -d
sleep 3
sudo lxc-ls -f

echo "Update"
sudo lxc-attach -n $LXC_NAME -- apt-get update
sudo lxc-attach -n $LXC_NAME -- apt-get dist-upgrade --dry-run | grep -q "^Inst "	# Vérifie si il y aura des mises à jour.
if [ "$?" -eq 0 ]; then
	update_apt=1
fi
echo "update_apt=$update_apt"
echo "Upgrade"
sudo lxc-attach -n $LXC_NAME -- apt-get dist-upgrade
echo "Clean"
sudo lxc-attach -n $LXC_NAME -- apt-get autoremove
sudo lxc-attach -n $LXC_NAME -- apt-get autoclean

echo "Arrêt de la machine virtualisée"
sudo lxc-stop -n $LXC_NAME

echo "Suppression des règles de parefeu"
sudo iptables -D FORWARD -i lxc-pchecker -o eth0 -j ACCEPT
sudo iptables -D FORWARD -i eth0 -o lxc-pchecker -j ACCEPT
sudo iptables -t nat -D POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE
sudo ifdown lzc-pchecker


if [ "$update_apt" -eq 1 ]
then
	echo "Archivage du snapshot"
	sudo tar -czf --acls --xattrs /var/lib/lxcsnaps/$LXC_NAME/snap0.tar.gz /var/lib/lxcsnaps/$LXC_NAME/snap0
	echo "Remplacement du snapshot"
	sudo lxc-snapshot -n $LXC_NAME -d snap0
	sudo lxc-snapshot -n $LXC_NAME
fi
