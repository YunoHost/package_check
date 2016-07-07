#!/bin/bash

OUTPUTD="$script_dir/debug_output.log"
YUNOHOST_LOG="/var/log/yunohost/yunohost-cli.log"
COMPLETE_LOG="$script_dir/Complete.log"
temp_RESULT="$script_dir/temp_result.log"

echo "Chargement des fonctions de log_extractor.sh"

ECHO_FORMAT () {
	if [ "$2" == "red" ]; then
		echo -en "\e[91m"
	fi
	if [ "$2" == "lyellow" ]; then
		echo -en "\e[93m"
	fi
	if [ "$2" == "lred" ]; then
		echo -en "\e[91m"
	fi
	if [ "$2" == "lgreen" ]; then
		echo -en "\e[92m"
	fi
	if [ "$2" == "white" ]; then
		echo -en "\e[97m"
	fi
	if [ "$3" == "bold" ]; then
		echo -en "\e[1m"
	fi
	if [ "$3" == "underlined" ]; then
		echo -en "\e[4m"
	fi
	copy_log=--
	if [ "$4" == "clog" ]; then
 		copy_log="$COMPLETE_LOG"
	fi
	echo -en "$1" | tee -a "$RESULT" "$copy_log"
	echo -en "\e[0m"
}

COPY_LOG () {
	if [ "$1" -eq 1 ]; then
		log_line=$(sudo wc -l "$YUNOHOST_LOG" | cut -d ' ' -f 1)	# Compte le nombre de ligne du fichier de log Yunohost
		log_line=$(( $log_line + 1 ))	# Ignore la première ligne, reprise de l'ancien log.
		echo -n "" > "$OUTPUTD"	# Efface le fichier de log temporaire
	fi
	if [ "$1" -eq 2 ]; then
		sudo tail -n +$log_line "$YUNOHOST_LOG" >> "$OUTPUTD"	# Copie le fichier de log à partir de la dernière ligne du log préexistant
	fi
}

PARSE_LOG () {
	while read LOG_LIGNE_TEMP
	do	# Lit le log pour extraire les warning et les erreurs.
		if echo "$LOG_LIGNE_TEMP" | grep -q "^>ERROR: "; then
			ECHO_FORMAT "Error:" "red" "underlined"
			ECHO_FORMAT " $(echo "$LOG_LIGNE_TEMP\n" | sed 's/^>ERROR: //')" "red"
			YUNOHOST_RESULT=1
			YUNOHOST_REMOVE=1
		fi
		if echo "$LOG_LIGNE_TEMP" | grep -q "^>WARNING: "; then
			ECHO_FORMAT "Warning:" "lyellow" "underlined"
			ECHO_FORMAT " $(echo "$LOG_LIGNE_TEMP\n" | sed 's/^>WARNING: //')" "lyellow"
		fi
	done < "$temp_RESULT"
}

CLEAR_LOG () {
	# Élimine les warning parasites connus et identifiables facilement.
	sed -i '/^>WARNING: yunohost\.hook <lambda> - \[[0-9.]*\] ?$/d' "$temp_RESULT"	# Ligne de warning vide précédant et suivant la progression d'un wget
	sed -i '/^>WARNING: yunohost\.hook <lambda> - \[[0-9.]*\] *[0-9]*K \.* /d' "$temp_RESULT"	# Ligne de warning de progression d'un wget
	sed -i '/% Total    % Received % Xferd/d' "$temp_RESULT"	# Ligne de warning des statistiques d'un wget
	sed -i '/Dload  Upload   Total   Spent/d' "$temp_RESULT"	# 2e ligne de warning des statistiques d'un wget
	sed -i '/--:--:-- --:--:-- --:--:--/d' "$temp_RESULT"	# 3e ligne de warning des statistiques d'un wget
	sed -i '/^>WARNING: yunohost.backup backup_restore - \[[0-9.]*\] YunoHost est déjà installé$/d' "$temp_RESULT"	# Ligne de warning du backup car Yunohost est déjà installé
	sed -i '/^$/d' "$temp_RESULT"	# Retire les lignes vides
}

LOG_EXTRACTOR () {
	echo -n "" > "$temp_RESULT"	# Initialise le fichier des résulats d'analyse
	cat "$OUTPUTD" >> "$COMPLETE_LOG"
	while read LOG_LIGNE
	do	# Lit le log pour extraire les warning et les erreurs.
		if echo "$LOG_LIGNE" | grep -q " ERROR    "; then
			echo -n ">ERROR: " >> "$temp_RESULT"
			echo "$LOG_LIGNE" | sed 's/^.* ERROR *//' >> "$temp_RESULT"
		fi
		if echo "$LOG_LIGNE" | grep -q "yunohost.*: error:"; then	# Récupère aussi les erreurs de la moulinette
			echo -n ">ERROR: " >> "$temp_RESULT"
			echo "$LOG_LIGNE" >> "$temp_RESULT"
		fi

		if echo "$LOG_LIGNE" | grep -q " WARNING  "; then
			echo -n ">WARNING: " >> "$temp_RESULT"
			echo "$LOG_LIGNE" | sed 's/^.* WARNING *//' >> "$temp_RESULT"
		fi
	done < "$OUTPUTD"
	CLEAR_LOG
	PARSE_LOG
}
