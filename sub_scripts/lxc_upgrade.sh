#!/bin/bash

# Récupère le dossier du script
if [ "${0:0:1}" == "/" ]; then script_dir="$(dirname "$0")"; else script_dir="$(echo $PWD/$(dirname "$0" | cut -d '.' -f2) | sed 's@/$@@')"; fi

if test -e "$script_dir/../pcheck.lock"
then	# L'upgrade est annulé
	echo "Le fichier $script_dir/../pcheck.lock est présent. Package check est déjà utilisé. Exécution annulée..."
	exit 0
fi
touch "$script_dir/../pcheck.lock" # Met en place le lock de Package check

PLAGE_IP=$(cat "$script_dir/lxc_build.sh" | grep PLAGE_IP= | cut -d '"' -f2)
LXC_NAME=$(cat "$script_dir/lxc_build.sh" | grep LXC_NAME= | cut -d '=' -f2)

# Check user
if [ "$(whoami)" != "$(cat "$script_dir/setup_user")" ] && test -e "$script_dir/setup_user"; then
	echo -e "\e[91mCe script doit être exécuté avec l'utilisateur $(cat "$script_dir/setup_user") !\nL'utilisateur actuel est $(whoami)."
	echo -en "\e[0m"
	rm "$script_dir/../pcheck.lock" # Retire le lock
	exit 0
fi

echo "\e[1m> Active le bridge réseau\e[0m"
if ! sudo ifquery lxc-pchecker --state > /dev/null
then
	sudo ifup lxc-pchecker --interfaces=/etc/network/interfaces.d/lxc-pchecker
fi

echo "\e[1m> Configure le parefeu\e[0m"
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

echo "\e[1m> Démarrage de la machine\e[0m"
if [ $(sudo lxc-info --name $LXC_NAME | grep -c "STOPPED") -eq 0 ]; then
	# Si la machine n'est pas à l'arrêt.
	sudo lxc-stop -n $LXC_NAME	# Arrête la machine LXC
fi
# Restaure le snapshot
sudo rsync -aEAX --delete -i /var/lib/lxcsnaps/$LXC_NAME/snap0/rootfs/ /var/lib/lxc/$LXC_NAME/rootfs/ > /dev/null	# Pour être sûr!

sudo lxc-start -n $LXC_NAME -d
sleep 3
sudo lxc-ls -f

echo "\e[1m> Update\e[0m"
update_apt=0
sudo lxc-attach -n $LXC_NAME -- apt-get update
sudo lxc-attach -n $LXC_NAME -- apt-get dist-upgrade --dry-run | grep -q "^Inst "	# Vérifie si il y aura des mises à jour.
if [ "$?" -eq 0 ]; then
	update_apt=1
fi
echo "\e[1m> Upgrade\e[0m"
sudo lxc-attach -n $LXC_NAME -- apt-get dist-upgrade -y
echo "\e[1m> Clean\e[0m"
sudo lxc-attach -n $LXC_NAME -- apt-get autoremove -y
sudo lxc-attach -n $LXC_NAME -- apt-get autoclean

echo "\e[1m> Arrêt de la machine virtualisée\e[0m"
sudo lxc-stop -n $LXC_NAME

echo "\e[1m> Suppression des règles de parefeu\e[0m"
sudo iptables -D FORWARD -i lxc-pchecker -o eth0 -j ACCEPT
sudo iptables -D FORWARD -i eth0 -o lxc-pchecker -j ACCEPT
sudo iptables -t nat -D POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE
sudo ifdown --force lxc-pchecker


if [ "$update_apt" -eq 1 ]
then
	echo "\e[1m> Archivage du snapshot\e[0m"
	sudo tar -cz --acls --xattrs -f /var/lib/lxcsnaps/$LXC_NAME/snap0.tar.gz /var/lib/lxcsnaps/$LXC_NAME/snap0
	echo "\e[1m> Remplacement du snapshot\e[0m"
	sudo lxc-snapshot -n $LXC_NAME -d snap0
	sudo lxc-snapshot -n $LXC_NAME
fi

sudo rm "$script_dir/../pcheck.lock" # Retire le lock
