#!/bin/bash

# Force le démarrage conteneur et active la config réseau dédiée.

# Récupère le dossier du script
if [ "${0:0:1}" == "/" ]; then script_dir="$(dirname "$0")"; else script_dir="$(echo $PWD/$(dirname "$0" | cut -d '.' -f2) | sed 's@/$@@')"; fi

pcheck_config="$script_dir/../config"
PLAGE_IP=$(cat "$pcheck_config" | grep PLAGE_IP= | cut -d '=' -f2)
LXC_NAME=$(cat "$pcheck_config" | grep LXC_NAME= | cut -d '=' -f2)
LXC_BRIDGE=$(cat "$pcheck_config" | grep LXC_BRIDGE= | cut -d '=' -f2)
main_iface=$(cat "$pcheck_config" | grep iface= | cut -d '=' -f2)

"$script_dir/lxc_force_stop.sh" > /dev/null 2>&1

echo "Initialisation du réseau pour le conteneur."
sudo ifup $LXC_BRIDGE --interfaces=/etc/network/interfaces.d/$LXC_BRIDGE

# Activation des règles iptables
echo "> Configure le parefeu"
sudo iptables -A FORWARD -i $LXC_BRIDGE -o $main_iface -j ACCEPT
sudo iptables -A FORWARD -i $main_iface -o $LXC_BRIDGE -j ACCEPT
sudo iptables -t nat -A POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE

# Démarrage de la machine
echo "> Démarrage de la machine"
sudo lxc-start -n $LXC_NAME -d --logfile "$script_dir/lxc_boot.log"
sleep 3

# Vérifie que la machine a démarré
sudo lxc-ls -f
