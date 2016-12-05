#!/bin/bash

# Boucle de test pour partir à la chasse au bug #654 (https://dev.yunohost.org/issues/654)

# Un ctrl+C est nécessaire pour stopper la boucle!

# !!!!!! Attention, ce script doit tourner dans une VM exclusivement !!!!!!

APP="my_webapp_ynh"
APPID=multi_webapp
MANIFEST_ARGS_MOD="domain=crudelis-test4.fr&path=/site&admin=mcrudelis&sql=No&is_public=Yes"

# Récupère le dossier du script
if [ "${0:0:1}" == "/" ]; then script_dir="$(dirname "$0")"; else script_dir="$(echo $PWD/$(dirname "$0" | cut -d '.' -f2) | sed 's@/$@@')"; fi

patchlog="$script_dir/temppatchlog654"
patch654="$script_dir/patch_#654_pcheckless.log"
COMPLETE_LOG="/var/log/yunohost/yunohost-cli.log"

touch "$patch654"
lprogress=$(sudo wc -l "$COMPLETE_LOG" | cut -d ' ' -f 1)	# Compte le nombre de ligne du log complet

PATCH_654 () {
	sudo tail -n +$lprogress "$COMPLETE_LOG" > "$patchlog"	# Copie le fichier de log à partir de la dernière ligne du log préexistant
	lprogress=$(sudo wc -l "$COMPLETE_LOG" | cut -d ' ' -f 1)	# Compte le nombre de ligne du log complet
	lprogress=$(( $lprogress + 1 ))	# Ignore la première ligne, reprise de l'ancien log.

	bug=0

	if grep -q "L'exécution du script .* ne s'est pas terminée" "$patchlog"; then
		bug=1
	elif grep -q "Script execution hasn’t terminated:" "$patchlog"; then
		bug=1
	elif grep -q "La ejecución del script no ha terminado:" "$patchlog"; then
		bug=1
	elif grep -q "Skriptausführung noch nicht beendet" "$patchlog"; then
		bug=1
	fi
	if [ "$bug" -eq 1 ]
	then
		echo -e "\e[91m\n!! Bug 654 détecté !!\n\e[0m"
		echo -e "$(date)\nBug 654\n" >> "$patch654"	# Patch #654
	fi
}

while (true)	# Boucle infinie...
do
	echo "Installation"
	sudo yunohost --debug app install "$APP" -a "$MANIFEST_ARGS_MOD" > /dev/null
	PATCH_654
	echo "Remove"
	sudo yunohost --debug app remove $APPID > /dev/null
	PATCH_654
	echo "Réinstallation"
	sudo yunohost --debug app install "$APP" -a "$MANIFEST_ARGS_MOD" > /dev/null
	PATCH_654
	echo "Upgrade"
	sudo yunohost --debug app upgrade $APPID -f "$APP" > /dev/null
	PATCH_654
	echo "Backup"
	sudo yunohost backup delete Backup_test
	sudo yunohost --debug backup create -n Backup_test --apps $APPID --hooks conf_ssowat data_home conf_ynh_firewall conf_cron > /dev/null
	PATCH_654
	echo "Remove"
	sudo yunohost --debug app remove $APPID > /dev/null
	PATCH_654
	echo "Restore"
	sudo yunohost --debug backup restore Backup_test --force --apps $APPID > /dev/null
	PATCH_654
	echo "Remove"
	sudo yunohost --debug app remove $APPID > /dev/null
	PATCH_654
done
