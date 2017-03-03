#!/bin/bash

# Force l'arrêt du conteneur et désactive la config réseau dédiée.

# Récupère le dossier du script
if [ "${0:0:1}" == "/" ]; then script_dir="$(dirname "$0")"; else script_dir="$(echo $PWD/$(dirname "$0" | cut -d '.' -f2) | sed 's@/$@@')"; fi

pcheck_config="$script_dir/../config"
PLAGE_IP=$(cat "$pcheck_config" | grep PLAGE_IP= | cut -d '=' -f2)
LXC_NAME=$(cat "$pcheck_config" | grep LXC_NAME= | cut -d '=' -f2)
LXC_BRIDGE=$(cat "$pcheck_config" | grep LXC_BRIDGE= | cut -d '=' -f2)
main_iface=$(cat "$pcheck_config" | grep iface= | cut -d '=' -f2)

echo "> Arrêt du conteneur"
sudo lxc-stop -n $LXC_NAME

echo "> Suppression des règles de parefeu"
if sudo iptables -C FORWARD -i $LXC_BRIDGE -o $main_iface -j ACCEPT 2> /dev/null
then
	sudo iptables -D FORWARD -i $LXC_BRIDGE -o $main_iface -j ACCEPT
fi
if sudo iptables -C FORWARD -i $main_iface -o $LXC_BRIDGE -j ACCEPT 2> /dev/null
then
	sudo iptables -D FORWARD -i $main_iface -o $LXC_BRIDGE -j ACCEPT
fi
if sudo iptables -t nat -C POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE 2> /dev/null
then
	sudo iptables -t nat -D POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE
fi

echo "Arrêt de l'interface réseau pour le conteneur."
# Et arrêt du bridge
if sudo ifquery $LXC_BRIDGE --state > /dev/null
then
	sudo ifdown --force $LXC_BRIDGE
fi

sudo lxc-ls -f
