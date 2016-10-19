#!/bin/bash

# Teste différents aspect du conteneur pour chercher d'éventuelles erreurs.
# Et tente de réparer si possible...

# Récupère le dossier du script
if [ "${0:0:1}" == "/" ]; then script_dir="$(dirname "$0")"; else script_dir="$(echo $PWD/$(dirname "$0" | cut -d '.' -f2) | sed 's@/$@@')"; fi

PLAGE_IP=$(cat "$script_dir/lxc_build.sh" | grep PLAGE_IP= | cut -d '"' -f2)
ARG_SSH="-t"
LXC_NAME=$(cat "$script_dir/lxc_build.sh" | grep LXC_NAME= | cut -d '=' -f2)

STOP_CONTAINER () {
        echo "Arrêt du conteneur $LXC_NAME"
	sudo lxc-stop -n $LXC_NAME
}

START_NETWORK () {
	echo "Initialisation du réseau pour le conteneur."
	sudo ifup lxc-pchecker --interfaces=/etc/network/interfaces.d/lxc-pchecker
	# Activation des règles iptables
	sudo iptables -A FORWARD -i lxc-pchecker -o eth0 -j ACCEPT
	sudo iptables -A FORWARD -i eth0 -o lxc-pchecker -j ACCEPT
	sudo iptables -t nat -A POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE
}

STOP_NETWORK () {
	echo "Arrêt du réseau pour le conteneur."
        sudo iptables -D FORWARD -i lxc-pchecker -o eth0 -j ACCEPT > /dev/null 2>&1
        sudo iptables -D FORWARD -i eth0 -o lxc-pchecker -j ACCEPT > /dev/null 2>&1
	sudo iptables -t nat -D POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE > /dev/null 2>&1
	sudo ifdown --force lxc-pchecker > /dev/null 2>&1
}

START_CONTAINER () {
	sudo lxc-start -n $LXC_NAME -d > /dev/null 2>&1	# Démarre le conteneur
	sudo lxc-wait -n $LXC_NAME -s 'RUNNING' -t 60	# Attend pendant 60s maximum que le conteneur démarre
}

STOP_CONTAINER
STOP_NETWORK

START_NETWORK
START_CONTAINER
