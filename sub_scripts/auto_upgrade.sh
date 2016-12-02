#!/bin/bash

# Ce script n'a vocation qu'a être dans un cron. De préférence une fois par jour ou par semaine.

# Récupère le dossier du script
if [ "${0:0:1}" == "/" ]; then script_dir="$(dirname "$0")"; else script_dir="$(echo $PWD/$(dirname "$0" | cut -d '.' -f2) | sed 's@/$@@')"; fi

echo ""
date
# Vérifie que Package check n'est pas déjà utilisé.
timeout=7200	# Durée d'attente maximale
inittime=$(date +%s)	# Enregistre l'heure de début d'attente
while test -e "$script_dir/../pcheck.lock"; do	# Vérifie la présence du lock de Package check
	sleep 60	# Attend la fin de l'exécution de Package check.
	echo -n "."
	if [ $(( $(date +%s) - $inittime )) -ge $timeout ]	# Vérifie la durée d'attente
	then	# Si la durée dépasse le timeout fixé, force l'arrêt.
		inittime=0	# Indique l'arrêt forcé du script
		echo "Temps d'attente maximal dépassé, la mise à jour est annulée."
		break
	fi
done
echo ""

if [ "$inittime" -ne 0 ]; then	# Continue seulement si le timeout n'est pas dépassé.
	"$script_dir/lxc_upgrade.sh"	# Exécute le script d'upgrade de Package check
fi
