#!/bin/bash

# Boucle de test pour partir à la chasse au bug #654 (https://dev.yunohost.org/issues/654)

# Donner en argument le package à tester
# Un ctrl+C est nécessaire pour stopper la boucle!
# Sur un second terminal, tail -f package_check/patch_#654.log pour récupérer les erreurs

if [ "$#" -eq 0 ]; then
	echo "Le script prend en argument le package à tester."
	exit 1
fi
if [ "$#" -gt 1 ]; then
	echo "Le script prend un seul argument."
	exit 1
fi

# Récupère le dossier du script
if [ "${0:0:1}" == "/" ]; then script_dir="$(dirname "$0")"; else script_dir="$(echo $PWD/$(dirname "$0" | cut -d '.' -f2) | sed 's@/$@@')"; fi

sudo rm "$script_dir/../pcheck.lock" # Retire le lock
touch "$script_dir/../patch_#654.log"

while (true)	# Boucle infinie...
do
	"$script_dir/../package_check.sh" --bash-mode "$1"
# 	"$script_dir/../package_check.sh" --bash-mode --no_lxc "$1"
done
