#!/bin/bash

PLAGE_IP=$(cat lxc_build.sh | grep PLAGE_IP= | cut -d '"' -f2)
LXC_NAME=$(cat lxc_build.sh | grep LXC_NAME= | cut -d '=' -f2)

echo ">> Active le bridge réseau"
if ! sudo ifquery lxc-pchecker --state > /dev/null
then
	sudo ifup lxc-pchecker
fi

echo ">> Configure le parefeu"
if ! sudo iptables -D FORWARD -i lxc-pchecker -o eth0 -j ACCEPT 2> /dev/null
then
	sudo iptables -A FORWARD -i lxc-pchecker -o eth0 -j ACCEPT
fi
if ! sudo iptables -C FORWARD -i eth0 -o lxc-pchecker -j ACCEPT 2> /dev/null
then
	sudo iptables -A FORWARD -i eth0 -o lxc-pchecker -j ACCEPT
fi
if ! sudo iptables -t nat -C POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE 2> /dev/null
then
	sudo iptables -t nat -A POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE
fi

echo ">> Démarrage de la machine"
if [ $(sudo lxc-info --name $LXC_NAME | grep -c "STOPPED") -eq 0 ]; then
	# Si la machine n'est pas à l'arrêt.
	sudo lxc-stop -n $LXC_NAME	# Arrête la machine LXC
fi
# Restaure le snapshot
sudo rsync -aEAX --delete /var/lib/lxcsnaps/$LXC_NAME/snap0/rootfs/ /var/lib/lxc/$LXC_NAME/rootfs/	# Pour être sûr!

sudo lxc-start -n $LXC_NAME -d
sleep 3
sudo lxc-ls -f

echo ">> Update"
sudo lxc-attach -n $LXC_NAME -- apt-get update
sudo lxc-attach -n $LXC_NAME -- apt-get dist-upgrade --dry-run | grep -q "^Inst "	# Vérifie si il y aura des mises à jour.
if [ "$?" -eq 0 ]; then
	update_apt=1
else
	update_apt=0

fi
echo ">> Upgrade"
sudo lxc-attach -n $LXC_NAME -- apt-get dist-upgrade
echo ">> Clean"
sudo lxc-attach -n $LXC_NAME -- apt-get autoremove
sudo lxc-attach -n $LXC_NAME -- apt-get autoclean

echo ">> Arrêt de la machine virtualisée"
sudo lxc-stop -n $LXC_NAME

echo ">> Suppression des règles de parefeu"
sudo iptables -D FORWARD -i lxc-pchecker -o eth0 -j ACCEPT
sudo iptables -D FORWARD -i eth0 -o lxc-pchecker -j ACCEPT
sudo iptables -t nat -D POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE
sudo ifdown lxc-pchecker


if [ "$update_apt" -eq 1 ]
then
	echo ">> Archivage du snapshot"
	sudo tar -czf --acls --xattrs /var/lib/lxcsnaps/$LXC_NAME/snap0.tar.gz /var/lib/lxcsnaps/$LXC_NAME/snap0
	echo ">> Remplacement du snapshot"
	sudo lxc-snapshot -n $LXC_NAME -d snap0
	sudo lxc-snapshot -n $LXC_NAME
fi
