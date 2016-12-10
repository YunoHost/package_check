#!/bin/bash

RESULT="$script_dir/Test_results.log"
BACKUP_HOOKS="conf_ssowat data_home conf_ynh_firewall conf_cron"	# La liste des hooks disponible pour le backup se trouve dans /usr/share/yunohost/hooks/backup/

echo -e "Chargement des fonctions de testing_process.sh"

source "$script_dir/sub_scripts/log_extractor.sh"

SETUP_APP () {
# echo -e "MANIFEST_ARGS=$MANIFEST_ARGS"
# echo -e "MANIFEST_ARGS_MOD=$MANIFEST_ARGS_MOD"
	COPY_LOG 1
	LXC_START "sudo yunohost --debug app install \"$APP_PATH_YUNO\" -a \"$MANIFEST_ARGS_MOD\""
	YUNOHOST_RESULT=$?
	COPY_LOG 2
	APPID=$(grep -o -m1 "YNH_APP_INSTANCE_NAME=[^ ]*" "$OUTPUTD" | cut -d '=' -f2)	# Récupère le nom de l'app au moment de l'install. Pour pouvoir le réutiliser dans les commandes yunohost. La regex matche tout ce qui suit le =, jusqu'à l'espace.
}

REMOVE_APP () {
	if [ "$auto_remove" -eq 0 ] && [ "$bash_mode" -ne 1 ]; then	# Si l'auto_remove est désactivée. Marque une pause avant de continuer.
		if [ "$no_lxc" -eq 0 ]; then
			echo "Utilisez ssh pour vous connecter au conteneur LXC. 'ssh $ARG_SSH $LXC_NAME'"
		fi
		read -p "Appuyer sur une touche pour supprimer l'application et continuer les tests..." < /dev/tty
	fi
	ECHO_FORMAT "\nSuppression...\n" "white" "bold"
	COPY_LOG 1
	LXC_START "sudo yunohost --debug app remove \"$APPID\""
	YUNOHOST_REMOVE=$?
	COPY_LOG 2
}

CHECK_URL () {
	if [ "$use_curl" -eq 1 ]
	then
		ECHO_FORMAT "\nAccès par l'url...\n" "white" "bold"
		if [ "$no_lxc" -eq 0 ]; then
			IP_CURL="$(cat "$script_dir/sub_scripts/lxc_build.sh" | grep PLAGE_IP= | cut -d '"' -f2).2"
		else
			IP_CURL="127.0.0.1"
		fi
		echo -e "$IP_CURL $DOMAIN #package_check\n$IP_CURL $SOUS_DOMAIN #package_check" | sudo tee -a /etc/hosts > /dev/null	# Renseigne le hosts pour le domain à tester, pour passer directement sur localhost
		curl_error=0
		http503=0
		i=1
		while [ "$i" -ne 3 ]	# Tant que i vaut 1 ou 2, les tests continuent.
		do	# 2 passes, pour effectuer un test avec le / final, et un autre sans.
			if [ "$i" -eq 1 ]; then	# Test sans / final.
				if [ "${CHECK_PATH:${#CHECK_PATH}-1}" == "/" ]	# Si le dernier caractère est un /
				then
					MOD_CHECK_PATH="${CHECK_PATH:0:${#CHECK_PATH}-1}"	# Supprime le /
				else
					MOD_CHECK_PATH=$CHECK_PATH
				fi
				i=2	# La prochaine boucle passera au 2e test
			fi
			if [ "$i" -eq 2 ]; then	# Test avec / final.
				if [ "${CHECK_PATH:${#CHECK_PATH}-1}" != "/" ]	# Si le dernier caractère n'est pas un /
				then
					MOD_CHECK_PATH="$CHECK_PATH/"	# Ajoute / à la fin du path
				else
					MOD_CHECK_PATH=$CHECK_PATH
				fi
				i=3	# La prochaine boucle terminera les tests
			fi
			rm -f "$script_dir/url_output"	# Supprime le précédent fichier html si il est encore présent
			curl -LksS -w "%{http_code};%{url_effective}\n" $SOUS_DOMAIN$MOD_CHECK_PATH -o "$script_dir/url_output" > "$script_dir/curl_print"
			if [ "$?" -ne 0 ]; then
				ECHO_FORMAT "Erreur de connexion...\n" "lred" "bold"
				curl_error=1
			fi
			ECHO_FORMAT "Adresse de test: $SOUS_DOMAIN$MOD_CHECK_PATH\n" "white"
			ECHO_FORMAT "Adresse de la page: $(cat "$script_dir/curl_print" | cut -d ';' -f2)\n" "white"
			HTTP_CODE=$(cat "$script_dir/curl_print" | cut -d ';' -f1)
			ECHO_FORMAT "Code HTTP: $HTTP_CODE\n" "white"
			if [ "${HTTP_CODE:0:1}" == "0" ] || [ "${HTTP_CODE:0:1}" == "4" ] || [ "${HTTP_CODE:0:1}" == "5" ]
			then	# Si le code d'erreur http est du type 0xx 4xx ou 5xx, c'est un code d'erreur.
				if [ "${HTTP_CODE}" != "401" ]
				then	# Le code d'erreur 401 fait exception, si il y a 401 c'est en général l'application qui le renvoi. Donc l'install est bonne.
					curl_error=1
				fi
				if [ "${HTTP_CODE}" = "503" ]
				then	# Le code d'erreur 503 indique que la ressource est temporairement indisponible. On va le croire pour cette fois et lui donner une autre chance.
					curl_error=0
					ECHO_FORMAT "Service temporairement indisponible...\n" "lyellow" "bold"
					http503=$(( $http503 + 1 ))
					if [ $http503 -eq 3 ]; then
						curl_error=1	# Après 3 erreurs 503, le code est considéré définitivement comme une erreur
					else
						i=$(( $i - 1 ))	# La boucle est décrémenté de 1 pour refaire le même test.
						sleep 1 # Attend 1 seconde pour laisser le temps au service de se mettre en place.
						continue	# Retourne en début de boucle pour recommencer le test
					fi
				fi
			fi
			URL_TITLE=$(grep "<title>" "$script_dir/url_output" | cut -d '>' -f 2 | cut -d '<' -f1)
			ECHO_FORMAT "Titre de la page: $URL_TITLE\n" "white"
			if [ "$URL_TITLE" == "YunoHost Portal" ]; then
				YUNO_PORTAL=1
				# Il serait utile de réussir à s'authentifier sur le portail pour tester une app protégée par celui-ci. Mais j'y arrive pas...
			else
				YUNO_PORTAL=0
				ECHO_FORMAT "Extrait du corps de la page:\n" "white"
				echo -e "\e[37m"	# Écrit en light grey
				grep "<body" -A 20 "$script_dir/url_output" | sed 1d | tee -a "$RESULT"
				echo -e "\e[0m"
			fi
		done
		sudo sed -i '/#package_check/d' /etc/hosts	# Supprime la ligne dans le hosts
	else
		ECHO_FORMAT "Test de connexion annulé.\n" "white"
		curl_error=0
	fi
}

CHECK_SETUP_SUBDIR () {
	# Test d'installation en sous-dossier
	ECHO_FORMAT "\n\n>> Installation en sous-dossier... [Test $cur_test/$all_test]\n" "white" "bold" clog
	cur_test=$((cur_test+1))
	use_curl=1
	if [ -z "$MANIFEST_DOMAIN" ]; then
		echo "Clé de manifest pour 'domain' introuvable dans le fichier check_process. Impossible de procéder à ce test"
		return
	fi
	if [ -z "$MANIFEST_PATH" ]; then
		echo "Clé de manifest pour 'path' introuvable dans le fichier check_process. Impossible de procéder à ce test"
		return
	fi
	if [ -z "$MANIFEST_USER" ]; then
		echo "Clé de manifest pour 'user' introuvable dans le fichier check_process. Impossible de procéder à ce test"
		return
	fi
	MANIFEST_ARGS_MOD=$MANIFEST_ARGS	# Copie des arguments
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_DOMAIN=[a-Z./-$]*\&/$MANIFEST_DOMAIN=$SOUS_DOMAIN\&/")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=$PATH_TEST\&@")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_USER=[a-Z/-$]*\&@$MANIFEST_USER=$USER_TEST\&@")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PASSWORD=[a-Z$]*\&/$MANIFEST_PASSWORD=$PASSWORD_TEST\&/")
	if [ -n "$MANIFEST_PUBLIC" ] && [ -n "$MANIFEST_PUBLIC_public" ]; then	# Si possible, install en public pour le test d'accès url
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PUBLIC=[a-Z]*\&/$MANIFEST_PUBLIC=$MANIFEST_PUBLIC_public\&/")
	fi
	# Installation de l'app
	SETUP_APP
	LOG_EXTRACTOR
	# Test l'accès à l'app
	CHECK_PATH=$PATH_TEST
	CHECK_URL
	tnote=$((tnote+2))
	install_pass=1
	if [ "$YUNOHOST_RESULT" -eq 0 ] && [ "$curl_error" -eq 0 ]; then
		ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
		note=$((note+2))
		GLOBAL_CHECK_SETUP=1	# Installation réussie
		GLOBAL_CHECK_SUB_DIR=1	# Installation en sous-dossier réussie
	else
		ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
		if [ "$GLOBAL_CHECK_SETUP" -ne 1 ]; then
			GLOBAL_CHECK_SETUP=-1	# Installation échouée
		fi
		GLOBAL_CHECK_SUB_DIR=-1	# Installation en sous-dossier échouée
	fi
	# Suppression de l'app
	REMOVE_APP
	if [ "$YUNOHOST_RESULT" -eq 0 ]	# Si l'installation a été un succès. On teste la suppression
	then
		LOG_EXTRACTOR
		tnote=$((tnote+2))
		install_pass=2
		if [ "$YUNOHOST_REMOVE" -eq 0 ]; then
			ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
			note=$((note+2))
			GLOBAL_CHECK_REMOVE_SUBDIR=1	# Suppression en sous-dossier réussie
			GLOBAL_CHECK_REMOVE=1	# Suppression réussie
		else
			ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
			if [ "$GLOBAL_CHECK_REMOVE" -ne 1 ]; then
				GLOBAL_CHECK_REMOVE=-1	# Suppression échouée
			fi
			GLOBAL_CHECK_REMOVE_SUBDIR=-1	# Suppression en sous-dossier échouée
		fi
	fi
	YUNOHOST_RESULT=-1
	YUNOHOST_REMOVE=-1
}

CHECK_SETUP_ROOT () {
	# Test d'installation à la racine
	ECHO_FORMAT "\n\n>> Installation à la racine... [Test $cur_test/$all_test]\n" "white" "bold" clog
	cur_test=$((cur_test+1))
	use_curl=1
	if [ -z "$MANIFEST_DOMAIN" ]; then
		echo "Clé de manifest pour 'domain' introuvable dans le fichier check_process. Impossible de procéder à ce test"
		return
	fi
	if [ -z "$MANIFEST_PATH" ]; then
		echo "Clé de manifest pour 'path' introuvable dans le fichier check_process. Impossible de procéder à ce test"
		return
	fi
	if [ -z "$MANIFEST_USER" ]; then
		echo "Clé de manifest pour 'user' introuvable dans le fichier check_process. Impossible de procéder à ce test"
		return
	fi
	MANIFEST_ARGS_MOD=$MANIFEST_ARGS	# Copie des arguments
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_DOMAIN=[a-Z./-$]*\&/$MANIFEST_DOMAIN=$SOUS_DOMAIN\&/")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=/\&@")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_USER=[a-Z/-$]*\&@$MANIFEST_USER=$USER_TEST\&@")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PASSWORD=[a-Z$]*\&/$MANIFEST_PASSWORD=$PASSWORD_TEST\&/")
	if [ -n "$MANIFEST_PUBLIC" ] && [ -n "$MANIFEST_PUBLIC_public" ]; then	# Si possible, install en public pour le test d'accès url
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PUBLIC=[a-Z]*\&/$MANIFEST_PUBLIC=$MANIFEST_PUBLIC_public\&/")
	fi
	# Installation de l'app
	SETUP_APP
	LOG_EXTRACTOR
	# Test l'accès à l'app
	CHECK_PATH="/"
	CHECK_URL
	if [ "$install_pass" -gt 0 ]; then	# Si install_pass>0, une installation a déjà été faite.
		tnote=$((tnote+1))
	else
		install_pass=1
		tnote=$((tnote+2))
	fi
	if [ "$YUNOHOST_RESULT" -eq 0 ] && [ "$curl_error" -eq 0 ]; then
		ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
		if [ "$GLOBAL_CHECK_SETUP" -eq 1 ]; then
			note=$((note+1))
		else
			note=$((note+2))
		fi
		GLOBAL_CHECK_SETUP=1	# Installation réussie
		GLOBAL_CHECK_ROOT=1	# Installation à la racine réussie
	else
		ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
		if [ "$GLOBAL_CHECK_SETUP" -ne 1 ]; then
			GLOBAL_CHECK_SETUP=-1	# Installation échouée
		fi
		GLOBAL_CHECK_ROOT=-1	# Installation à la racine échouée
	fi
	# Suppression de l'app
	REMOVE_APP
	if [ "$YUNOHOST_RESULT" -eq 0 ]	# Si l'installation a été un succès. On teste la suppression
	then
		LOG_EXTRACTOR
		if [ "$install_pass" -eq 2 ]; then	# Si install_pass=2, une suppression a déjà été faite.
			tnote=$((tnote+1))
		else
			install_pass=2
			tnote=$((tnote+2))
		fi
		if [ "$YUNOHOST_REMOVE" -eq 0 ]; then
			ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
			if [ "$GLOBAL_CHECK_REMOVE" -eq 0 ]; then
				note=$((note+2))
			else
				note=$((note+1))
			fi
			GLOBAL_CHECK_REMOVE_ROOT=1	# Suppression à la racine réussie
			GLOBAL_CHECK_REMOVE=1	# Suppression réussie
		else
			ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
			if [ "$GLOBAL_CHECK_REMOVE" -ne 1 ]; then
				GLOBAL_CHECK_REMOVE=-1	# Suppression échouée
			fi
			GLOBAL_CHECK_REMOVE_ROOT=-1	# Suppression à la racine échouée
		fi
	fi
	YUNOHOST_RESULT=-1
	YUNOHOST_REMOVE=-1
}

CHECK_SETUP_NO_URL () {
	# Test d'installation sans accès par url
	use_curl=0
	ECHO_FORMAT "\n\n>> Installation sans accès par url... [Test $cur_test/$all_test]\n" "white" "bold" clog
	cur_test=$((cur_test+1))
	MANIFEST_ARGS_MOD=$MANIFEST_ARGS	# Copie des arguments
	# Installation de l'app
	SETUP_APP
	LOG_EXTRACTOR
	if [ "$install_pass" -eq 0 ]; then	# Si install_pass=0, aucune installation n'a été faite.
		install_pass=1
		tnote=$((tnote+1))
	fi
	if [ "$YUNOHOST_RESULT" -eq 0 ]; then
		ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
		if [ "$GLOBAL_CHECK_SETUP" -eq 0 ]; then
			note=$((note+1))
		fi
		GLOBAL_CHECK_SETUP=1	# Installation réussie
		GLOBAL_CHECK_SUB_DIR=1
	else
		ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
		if [ "$GLOBAL_CHECK_SETUP" -ne 1 ]; then
			GLOBAL_CHECK_SETUP=-1	# Installation échouée
		fi
	fi
	# Suppression de l'app
	REMOVE_APP
	if [ "$YUNOHOST_RESULT" -eq 0 ]	# Si l'installation a été un succès. On teste la suppression
	then
		LOG_EXTRACTOR
		if [ "$install_pass" -ne 2 ]; then	# Si install_pass!=2, aucune suppression n'a été faite.
			install_pass=2
			tnote=$((tnote+1))
		fi
		if [ "$YUNOHOST_REMOVE" -eq 0 ]; then
			ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
			if [ "$GLOBAL_CHECK_REMOVE_ROOT" -eq 0 ]; then
				note=$((note+1))
			fi
			GLOBAL_CHECK_REMOVE_ROOT=1	# Suppression réussie
		else
			ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
			if [ "$GLOBAL_CHECK_REMOVE" -ne 1 ]; then
				GLOBAL_CHECK_REMOVE=-1	# Suppression échouée
			fi
			GLOBAL_CHECK_REMOVE_ROOT=-1	# Suppression échouée
		fi
	fi
	YUNOHOST_RESULT=-1
	YUNOHOST_REMOVE=-1
}

CHECK_UPGRADE () {
	# Test d'upgrade
	ECHO_FORMAT "\n\n>> Upgrade... [Test $cur_test/$all_test]\n" "white" "bold" clog
	cur_test=$((cur_test+1))
	if [ "$GLOBAL_CHECK_SETUP" -ne 1 ] && [ "$force_install_ok" -ne 1 ]; then
		echo "L'installation a échouée, impossible d'effectuer ce test..."
		return;
	fi
	MANIFEST_ARGS_MOD=$MANIFEST_ARGS	# Copie des arguments
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_DOMAIN=[a-Z./-$]*\&/$MANIFEST_DOMAIN=$SOUS_DOMAIN\&/")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_USER=[a-Z/-$]*\&@$MANIFEST_USER=$USER_TEST\&@")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PASSWORD=[a-Z$]*\&/$MANIFEST_PASSWORD=$PASSWORD_TEST\&/")
	if [ -n "$MANIFEST_PUBLIC" ] && [ -n "$MANIFEST_PUBLIC_public" ]; then	# Si possible, install en public pour le test d'accès url
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PUBLIC=[a-Z]*\&/$MANIFEST_PUBLIC=$MANIFEST_PUBLIC_public\&/")
	fi
	if [ "$GLOBAL_CHECK_ROOT" -eq 1 ]; then	# Utilise une install root, si elle a fonctionné
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=/\&@")
		CHECK_PATH="/"
	elif [ "$GLOBAL_CHECK_SUB_DIR" -eq 1 ] || [ "$force_install_ok" -eq 1 ]; then	# Si l'install en sub_dir à fonctionné. Ou si l'argument force_install_ok est présent. Utilise ce mode d'installation
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=$PATH_TEST\&@")
		CHECK_PATH="$PATH_TEST"
	else
		echo "Aucun mode d'installation n'a fonctionné, impossible d'effectuer ce test..."
		return;
	fi
	ECHO_FORMAT "\nInstallation préalable...\n" "white" "bold"
	# Installation de l'app
	SETUP_APP
	LOG_EXTRACTOR
	if [ "$YUNOHOST_RESULT" -ne 0 ]; then
		ECHO_FORMAT "\nInstallation échouée...\n" "lred" "bold"
	else
		ECHO_FORMAT "\nUpgrade sur la même version du package...\n" "white" "bold"
		# Upgrade de l'app
		COPY_LOG 1
		LXC_START "sudo yunohost --debug app upgrade $APPID -f \"$APP_PATH_YUNO\""
		YUNOHOST_RESULT=$?
		COPY_LOG 2
		LOG_EXTRACTOR
		# Test l'accès à l'app
		CHECK_URL
		tnote=$((tnote+1))
	fi
	if [ "$YUNOHOST_RESULT" -eq 0 ] && [ "$curl_error" -eq 0 ]; then
		ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
		note=$((note+1))
		GLOBAL_CHECK_UPGRADE=1	# Upgrade réussie
	else
		ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
		GLOBAL_CHECK_UPGRADE=-1	# Upgrade échouée
	fi
	if [ "$no_lxc" -ne 0 ]; then
		# Suppression de l'app si lxc n'est pas utilisé.
		REMOVE_APP
	elif [ "$auto_remove" -eq 0 ] && [ "$bash_mode" -ne 1 ]; then	# Si l'auto_remove est désactivée. Marque une pause avant de continuer.
		if [ "$no_lxc" -eq 0 ]; then
			echo "Utilisez ssh pour vous connecter au conteneur LXC. 'ssh $ARG_SSH $LXC_NAME'"
		fi
		read -p "Appuyer sur une touche pour continuer les tests..." < /dev/tty
	fi
	YUNOHOST_RESULT=-1
}

CHECK_BACKUP_RESTORE () {
	# Test de backup
	ECHO_FORMAT "\n\n>> Backup/Restore... [Test $cur_test/$all_test]\n" "white" "bold" clog
	cur_test=$((cur_test+1))
	if [ "$GLOBAL_CHECK_SETUP" -ne 1 ] && [ "$force_install_ok" -ne 1 ]; then
		echo "L'installation a échouée, impossible d'effectuer ce test..."
	fi
	MANIFEST_ARGS_MOD=$MANIFEST_ARGS	# Copie des arguments
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_DOMAIN=[a-Z./-$]*\&/$MANIFEST_DOMAIN=$SOUS_DOMAIN\&/")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_USER=[a-Z/-$]*\&@$MANIFEST_USER=$USER_TEST\&@")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PASSWORD=[a-Z$]*\&/$MANIFEST_PASSWORD=$PASSWORD_TEST\&/")
	if [ -n "$MANIFEST_PUBLIC" ] && [ -n "$MANIFEST_PUBLIC_public" ]; then	# Si possible, install en public pour le test d'accès url
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PUBLIC=[a-Z]*\&/$MANIFEST_PUBLIC=$MANIFEST_PUBLIC_public\&/")
	fi
	for i in 0 1
	do	# 2 passes, pour effectuer un test en root et en sub_dir
		if [ "$i" -eq 0 ]
		then	# Commence par l'install root
			if [ "$GLOBAL_CHECK_ROOT" -eq 1 ] || [ "$force_install_ok" -eq 1 ]; then	# Utilise une install root, si elle a fonctionné. Ou si l'argument force_install_ok est présent.
				MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=/\&@")
				CHECK_PATH="/"
				ECHO_FORMAT "\nInstallation préalable à la racine...\n" "white" "bold"
			else
				echo "L'installation à la racine n'a pas fonctionnée, impossible d'effectuer ce test..."
				continue;
			fi
		elif [ "$i" -eq 1 ]
		then	# Puis teste l'install sub_dir
			if [ "$GLOBAL_CHECK_SUB_DIR" -eq 1 ] || [ "$force_install_ok" -eq 1 ]; then	# Si l'install en sub_dir à fonctionné. Ou si l'argument force_install_ok est présent. Utilise ce mode d'installation
				MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=$PATH_TEST\&@")
				CHECK_PATH="$PATH_TEST"
				ECHO_FORMAT "\nInstallation préalable en sous-dossier...\n" "white" "bold"
			else
				echo "L'installation en sous-dossier n'a pas fonctionnée, impossible d'effectuer ce test..."
				return;
			fi
		fi
		# Installation de l'app
		SETUP_APP
		LOG_EXTRACTOR
		if [ "$YUNOHOST_RESULT" -ne 0 ]; then
			ECHO_FORMAT "\nInstallation échouée...\n" "lred" "bold"
		else
			ECHO_FORMAT "\nBackup de l'application...\n" "white" "bold"
			# Backup de l'app
			COPY_LOG 1
			LXC_START "sudo yunohost --debug backup create -n Backup_test --apps $APPID --hooks $BACKUP_HOOKS"
			YUNOHOST_RESULT=$?
			COPY_LOG 2
			LOG_EXTRACTOR
			tnote=$((tnote+1))
		fi
		if [ "$YUNOHOST_RESULT" -eq 0 ]; then
			ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
			note=$((note+1))
			if [ $GLOBAL_CHECK_BACKUP -ne -1 ]; then	# Le backup ne peux pas être réussi si il a échoué précédemment...
			    GLOBAL_CHECK_BACKUP=1	# Backup réussi
			fi
		else
			ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
			GLOBAL_CHECK_BACKUP=-1	# Backup échoué
		fi
		sudo cp -a /var/lib/lxc/$LXC_NAME/rootfs/home/yunohost.backup/archives ./	# Récupère le backup sur le conteneur
		for j in 0 1
		do	# 2 passes, pour tester la restauration après suppression de l'app ET après restauration du conteneur.
			if [ "$j" -eq 0 ]
			then	# Commence par tester la restauration après suppression de l'application
				REMOVE_APP	# Suppression de l'app
				ECHO_FORMAT "\nRestauration de l'application après suppression de l'application...\n" "white" "bold"
				if [ "$no_lxc" -ne 0 ]; then	# Si lxc n'est pas utilisé, impossible d'effectuer le 2e test
					j=2	# Ignore le 2e test
					echo -e "LXC n'est pas utilisé, impossible de tester la restauration sur un système vierge...\n"
				fi
			elif [ "$j" -eq 1 ]
			then	# Puis la restauration après restauration du conteneur (si LXC est utilisé)
				LXC_STOP	# Restaure le conteneur.
				sudo mv -f ./archives /var/lib/lxc/$LXC_NAME/rootfs/home/yunohost.backup/	# Replace le backup sur le conteneur
				ECHO_FORMAT "\nRestauration de l'application sur un système vierge...\n" "white" "bold"
			fi
			# Restore de l'app
			COPY_LOG 1
			LXC_START "sudo yunohost --debug backup restore Backup_test --force --apps $APPID"
			YUNOHOST_RESULT=$?
			COPY_LOG 2
			LOG_EXTRACTOR
			# Test l'accès à l'app
			CHECK_URL
			tnote=$((tnote+1))
			if [ "$YUNOHOST_RESULT" -eq 0 ] && [ "$curl_error" -eq 0 ]; then
				ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
				note=$((note+1))
				if [ $GLOBAL_CHECK_RESTORE -ne -1 ]; then	# La restauration ne peux pas être réussie si elle a échouée précédemment...
					GLOBAL_CHECK_RESTORE=1	# Restore réussi
				fi
			else
				ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
				GLOBAL_CHECK_RESTORE=-1	# Restore échoué
			fi
			if [ "$no_lxc" -ne 0 ]; then
				# Suppression de l'app si lxc n'est pas utilisé.
				REMOVE_APP
				# Suppression de l'archive
				sudo yunohost backup delete Backup_test > /dev/null
			elif [ "$auto_remove" -eq 0 ] && [ "$bash_mode" -ne 1 ]; then	# Si l'auto_remove est désactivée. Marque une pause avant de continuer.
				if [ "$no_lxc" -eq 0 ]; then
					echo "Utilisez ssh pour vous connecter au conteneur LXC. 'ssh $ARG_SSH $LXC_NAME'"
				fi
				read -p "Appuyer sur une touche pour continuer les tests..." < /dev/tty
			fi
			YUNOHOST_RESULT=-1
			LXC_STOP        # Restaure le snapshot du conteneur avant de recommencer le processus de backup
		done
	done
}

CHECK_PUBLIC_PRIVATE () {
	# Test d'installation en public/privé
	if [ "$1" == "private" ]; then
		ECHO_FORMAT "\n\n>> Installation privée... [Test $cur_test/$all_test]\n" "white" "bold" clog
	fi
	if [ "$1" == "public" ]; then
		ECHO_FORMAT "\n\n>> Installation publique... [Test $cur_test/$all_test]\n" "white" "bold" clog
	fi
	cur_test=$((cur_test+1))
	if [ "$GLOBAL_CHECK_SETUP" -ne 1 ] && [ "$force_install_ok" -ne 1 ]; then
		echo "L'installation a échouée, impossible d'effectuer ce test..."
		return
	fi
	if [ -z "$MANIFEST_PUBLIC" ]; then
		echo "Clé de manifest pour 'is_public' introuvable dans le fichier check_process. Impossible de procéder à ce test"
		return
	fi
	if [ -z "$MANIFEST_PUBLIC_public" ]; then
		echo "Valeur 'public' pour la clé de manifest 'is_public' introuvable dans le fichier check_process. Impossible de procéder à ce test"
		return
	fi
	if [ -z "$MANIFEST_PUBLIC_private" ]; then
		echo "Valeur 'private' pour la clé de manifest 'is_public' introuvable dans le fichier check_process. Impossible de procéder à ce test"
		return
	fi
	MANIFEST_ARGS_MOD=$MANIFEST_ARGS	# Copie des arguments
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_DOMAIN=[a-Z./-$]*\&/$MANIFEST_DOMAIN=$SOUS_DOMAIN\&/")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_USER=[a-Z/-$]*\&@$MANIFEST_USER=$USER_TEST\&@")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PASSWORD=[a-Z$]*\&/$MANIFEST_PASSWORD=$PASSWORD_TEST\&/")
	# Choix public/privé
	if [ "$1" == "private" ]; then
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PUBLIC=[a-Z0-9]*\&/$MANIFEST_PUBLIC=$MANIFEST_PUBLIC_private\&/")
	fi
	if [ "$1" == "public" ]; then
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PUBLIC=[a-Z0-9]*\&/$MANIFEST_PUBLIC=$MANIFEST_PUBLIC_public\&/")
	fi
	for i in 0 1
	do	# 2 passes, pour effectuer un test en root et en sub_dir
		if [ "$i" -eq 0 ]
		then	# Commence par l'install root
			if [ "$GLOBAL_CHECK_ROOT" -eq 1 ] || [ "$force_install_ok" -eq 1 ]; then	# Utilise une install root, si elle a fonctionné. Ou si l'argument force_install_ok est présent.
				MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=/\&@")
				CHECK_PATH="/"
			else
				echo "L'installation à la racine n'a pas fonctionnée, impossible d'effectuer ce test..."
				continue;
			fi
		elif [ "$i" -eq 1 ]
		then	# Puis teste l'install sub_dir
			if [ "$GLOBAL_CHECK_SUB_DIR" -eq 1 ] || [ "$force_install_ok" -eq 1 ]; then	# Si l'install en sub_dir à fonctionné. Ou si l'argument force_install_ok est présent. Utilise ce mode d'installation
				MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=$PATH_TEST\&@")
				CHECK_PATH="$PATH_TEST"
			else
				echo "L'installation en sous-dossier n'a pas fonctionnée, impossible d'effectuer ce test..."
				return;
			fi
		fi
		# Installation de l'app
		SETUP_APP
		# Test l'accès à l'app
		CHECK_URL
		if [ "$1" == "private" ]; then
			if [ "$YUNO_PORTAL" -eq 0 ]; then	# En privé, si l'accès url n'arrive pas sur le portail. C'est un échec.
				YUNOHOST_RESULT=1
			fi
		fi
		if [ "$1" == "public" ]; then
			if [ "$YUNO_PORTAL" -eq 1 ]; then	# En public, si l'accès url arrive sur le portail. C'est un échec.
				YUNOHOST_RESULT=1
			fi
		fi	
		LOG_EXTRACTOR
		tnote=$((tnote+1))
		if [ "$YUNOHOST_RESULT" -eq 0 ] && [ "$curl_error" -eq 0 ]; then
			ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
			note=$((note+1))
			if [ "$1" == "private" ]; then
				if [ $GLOBAL_CHECK_PRIVATE -ne -1 ]; then	# L'installation ne peux pas être réussie si elle a échouée précédemment...
				    GLOBAL_CHECK_PRIVATE=1	# Installation privée réussie
				fi
			fi
			if [ "$1" == "public" ]; then
				if [ $GLOBAL_CHECK_PUBLIC -ne -1 ]; then	# L'installation ne peux pas être réussie si elle a échouée précédemment...
				    GLOBAL_CHECK_PUBLIC=1	# Installation publique réussie
				fi
			fi
		else
			ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
			if [ "$1" == "private" ]; then
				GLOBAL_CHECK_PRIVATE=-1	# Installation privée échouée
			fi
			if [ "$1" == "public" ]; then
				GLOBAL_CHECK_PUBLIC=-1	# Installation publique échouée
			fi
		fi
		if [ "$auto_remove" -eq 0 ] && [ "$bash_mode" -ne 1 ]; then	# Si l'auto_remove est désactivée. Marque une pause avant de continuer.
			if [ "$no_lxc" -eq 0 ]; then
				echo "Utilisez ssh pour vous connecter au conteneur LXC. 'ssh $ARG_SSH $LXC_NAME'"
			fi
			read -p "Appuyer sur une touche pour continuer les tests..." < /dev/tty
		fi
		REMOVE_APP
		YUNOHOST_RESULT=-1
	done
}

CHECK_MULTI_INSTANCE () {
	# Test d'installation en multi-instance
	ECHO_FORMAT "\n\n>> Installation multi-instance... [Test $cur_test/$all_test]\n" "white" "bold" clog
	cur_test=$((cur_test+1))
	if [ "$GLOBAL_CHECK_SETUP" -ne 1 ] && [ "$force_install_ok" -ne 1 ]; then
		echo "L'installation a échouée, impossible d'effectuer ce test..."
		return
	fi
	MANIFEST_ARGS_MOD=$MANIFEST_ARGS	# Copie des arguments
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_DOMAIN=[a-Z./-$]*\&/$MANIFEST_DOMAIN=$SOUS_DOMAIN\&/")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_USER=[a-Z/-$]*\&@$MANIFEST_USER=$USER_TEST\&@")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PASSWORD=[a-Z$]*\&/$MANIFEST_PASSWORD=$PASSWORD_TEST\&/")
	if [ -n "$MANIFEST_PUBLIC" ] && [ -n "$MANIFEST_PUBLIC_public" ]; then	# Si possible, install en public pour le test d'accès url
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PUBLIC=[a-Z]*\&/$MANIFEST_PUBLIC=$MANIFEST_PUBLIC_public\&/")
	fi
	if [ "$GLOBAL_CHECK_SUB_DIR" -eq 1 ] || [ "$force_install_ok" -eq 1 ]; then	# Si l'install en sub_dir à fonctionné. Ou si l'argument force_install_ok est présent. Utilise ce mode d'installation
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=$PATH_TEST\&@")
	else
		echo "L'installation en sous-dossier n'a pas fonctionné, impossible d'effectuer ce test..."
		return;
	fi
	# Installation de l'app une première fois
	ECHO_FORMAT "1ère installation: path=$PATH_TEST\n"
	SETUP_APP
	LOG_EXTRACTOR
	APPID_first=$APPID	# Stocke le nom de la première instance
	YUNOHOST_RESULT_first=$YUNOHOST_RESULT	# Stocke le résulat de l'installation de la première instance
	# Installation de l'app une deuxième fois, en ajoutant un suffixe au path
	path2="$PATH_TEST-2"
	ECHO_FORMAT "2e installation: path=$path2\n"
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=$path2\&@")
	SETUP_APP
	LOG_EXTRACTOR
	APPID_second=$APPID	# Stocke le nom de la deuxième instance
	YUNOHOST_RESULT_second=$YUNOHOST_RESULT	# Stocke le résulat de l'installation de la deuxième instance
	path3="/3-${PATH_TEST#/}"
	ECHO_FORMAT "3e installation: path=$path3\n"
	# Installation de l'app une troisième fois, en ajoutant un préfixe au path
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=$path2\&@$MANIFEST_PATH=$path3\&@")
	SETUP_APP
	LOG_EXTRACTOR
	# Test l'accès à la 1ère instance de l'app
	CHECK_PATH="$PATH_TEST"
	CHECK_URL
	if [ "$curl_error" -ne 0 ]; then
		YUNOHOST_RESULT_first=$curl_error
	fi
	# Test l'accès à la 2e instance de l'app
	CHECK_PATH="$path2"
	CHECK_URL
	if [ "$curl_error" -ne 0 ]; then
		YUNOHOST_RESULT_second=$curl_error
	fi
	# Test l'accès à la 3e instance de l'app
	CHECK_PATH="$path3"
	CHECK_URL
	if [ "$curl_error" -ne 0 ]; then
		YUNOHOST_RESULT=$curl_error
	fi
	tnote=$((tnote+1))
	if [ "$YUNOHOST_RESULT" -eq 0 ] || [ "$YUNOHOST_RESULT_second" -eq 0 ]
	then	# Si la 2e OU la 3e installation à fonctionné, le test est validé. Car le SSO peut bloquer des installations en suffixe sur la même racine.
		YUNOHOST_RESULT=0
	fi
	if [ "$YUNOHOST_RESULT" -eq 0 ] && [ "$YUNOHOST_RESULT_first" -eq 0 ] && [ "$curl_error" -eq 0 ]; then
		ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
		note=$((note+1))
		GLOBAL_CHECK_MULTI_INSTANCE=1	# Installation multi-instance réussie
	else
		ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
		GLOBAL_CHECK_MULTI_INSTANCE=-1	# Installation multi-instance échouée
	fi
	if [ "$no_lxc" -ne 0 ]; then
		# Suppression de la 2e app si lxc n'est pas utilisé.
		REMOVE_APP
		# Suppression de la 1ère app
		APPID=$APPID_first
		REMOVE_APP
	elif [ "$auto_remove" -eq 0 ] && [ "$bash_mode" -ne 1 ]; then	# Si l'auto_remove est désactivée. Marque une pause avant de continuer.
		if [ "$no_lxc" -eq 0 ]; then
			echo "Utilisez ssh pour vous connecter au conteneur LXC. 'ssh $ARG_SSH $LXC_NAME'"
		fi
		read -p "Appuyer sur une touche pour continuer les tests..." < /dev/tty
	fi
	YUNOHOST_RESULT=-1
}

CHECK_COMMON_ERROR () {
	# Test d'erreur depuis le manifest
	if [ "$1" == "wrong_user" ]; then
		ECHO_FORMAT "\n\n>> Erreur d'utilisateur... [Test $cur_test/$all_test]\n" "white" "bold" clog
	fi
	if [ "$1" == "wrong_path" ]; then
		ECHO_FORMAT "\n\n>> Erreur de domaine... [Test $cur_test/$all_test]\n" "white" "bold" clog
	fi
	if [ "$1" == "incorrect_path" ]; then
		ECHO_FORMAT "\n\n>> Path mal formé... [Test $cur_test/$all_test]\n" "white" "bold" clog
	fi
	if [ "$1" == "port_already_use" ]; then
		ECHO_FORMAT "\n\n>> Port déjà utilisé... [Test $cur_test/$all_test]\n" "white" "bold" clog
		if [ -z "$MANIFEST_PORT" ]; then
			echo "Clé de manifest pour 'port' introuvable ou port non renseigné dans le fichier check_process. Impossible de procéder à ce test"
			return
		fi
	fi
	cur_test=$((cur_test+1))
	if [ "$GLOBAL_CHECK_SETUP" -ne 1 ] && [ "$force_install_ok" -ne 1 ]; then
		echo "L'installation a échouée, impossible d'effectuer ce test..."
		return
	fi
	MANIFEST_ARGS_MOD=$MANIFEST_ARGS	# Copie des arguments
	if [ "$1" == "wrong_path" ]; then	# Force un domaine incorrect
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_DOMAIN=[a-Z./-$]*\&/$MANIFEST_DOMAIN=domainenerreur.rien\&/")
	else
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_DOMAIN=[a-Z./-$]*\&/$MANIFEST_DOMAIN=$SOUS_DOMAIN\&/")
	fi
	if [ "$1" == "wrong_user" ]; then	# Force un user incorrect
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_USER=[a-Z/-$]*\&@$MANIFEST_USER=NO_USER\&@")
	else
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_USER=[a-Z/-$]*\&@$MANIFEST_USER=$USER_TEST\&@")
	fi
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PASSWORD=[a-Z$]*\&/$MANIFEST_PASSWORD=$PASSWORD_TEST\&/")
	if [ "$1" == "incorrect_path" ]; then	# Force un path mal formé: Ce sera path/ au lieu de /path
		WRONG_PATH=${PATH_TEST#/}/	# Transforme le path de /path à path/
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=$WRONG_PATH\&@")
		CHECK_PATH="$PATH_TEST"
	else
		if [ "$GLOBAL_CHECK_ROOT" -eq 1 ]; then	# Utilise une install root, si elle a fonctionné
			MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=/\&@")
			CHECK_PATH="/"
		elif [ "$GLOBAL_CHECK_SUB_DIR" -eq 1 ] || [ "$force_install_ok" -eq 1 ]; then	# Si l'install en sub_dir à fonctionné. Ou si l'argument force_install_ok est présent. Utilise ce mode d'installation
			MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=$PATH_TEST\&@")
		else
			echo "Aucun mode d'installation n'a fonctionné, impossible d'effectuer ce test..."
			return;
		fi
	fi
	if [ -n "$MANIFEST_PUBLIC" ] && [ -n "$MANIFEST_PUBLIC_public" ]; then	# Si possible, install en public pour le test d'accès url
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PUBLIC=[a-Z]*\&/$MANIFEST_PUBLIC=$MANIFEST_PUBLIC_public\&/")
	fi
	if [ "$1" == "port_already_use" ]; then	# Force un port déjà utilisé
		if [ "${MANIFEST_PORT:0:1}" == "#" ]	# Si le premier caractère de $MANIFEST_PORT est un #, c'est un numéro de port. Absent du manifest
		then
			check_port="${MANIFEST_PORT:1}"	# Récupère le numéro de port
		else
			MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PORT=[0-9$]*\&@$MANIFEST_PORT=6660\&@")
			check_port=6660 # Sinon fixe le port à 6660 dans le manifest
		fi
		LXC_START "sudo yunohost firewall allow Both $check_port"
	fi
	# Installation de l'app
	SETUP_APP
	LOG_EXTRACTOR
	if [ "$1" == "incorrect_path" ] || [ "$1" == "port_already_use" ]; then
		# Test l'accès à l'app
		if [ "$YUNOHOST_RESULT" -eq 0 ]; then	# Test l'url si l'installation à réussie.
			CHECK_URL
			if [ "$curl_error" -ne 0 ]; then
				YUNOHOST_RESULT=$curl_error
			fi
		fi
	fi
	tnote=$((tnote+1))
	if [ "$YUNOHOST_RESULT" -eq 0 ]; then	# wrong_user et wrong_path doivent aboutir à échec de l'installation. C'est l'inverse pour incorrect_path et port_already_use.
		if [ "$1" == "wrong_user" ]; then
			ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
			GLOBAL_CHECK_ADMIN=-1	# Installation privée réussie
		fi
		if [ "$1" == "wrong_path" ]; then
			ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
			GLOBAL_CHECK_DOMAIN=-1	# Installation privée réussie
		fi
		if [ "$1" == "incorrect_path" ]; then
			ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
			note=$((note+1))
			GLOBAL_CHECK_PATH=1	# Correction de path réussie
		fi
		if [ "$1" == "port_already_use" ]; then
			ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
			note=$((note+1))
			GLOBAL_CHECK_PORT=1	# Changement de port réussi
		fi
	else
		if [ "$1" == "wrong_user" ]; then
			ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
			note=$((note+1))
			GLOBAL_CHECK_ADMIN=1	# Installation privée échouée
		fi
		if [ "$1" == "wrong_path" ]; then
			ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
			note=$((note+1))
			GLOBAL_CHECK_DOMAIN=1	# Installation privée échouée
		fi
		if [ "$1" == "incorrect_path" ]; then
			ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
			GLOBAL_CHECK_PATH=-1	# Installation privée échouée
		fi
		if [ "$1" == "port_already_use" ]; then
			ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
			GLOBAL_CHECK_PORT=-1	# Installation privée échouée
		fi
	fi
	if [ "$no_lxc" -ne 0 ]; then
		# Suppression de l'app si lxc n'est pas utilisé.
		REMOVE_APP
		if [ "$1" == "port_already_use" ]; then	# Libère le port ouvert pour le test
			sudo yunohost firewall disallow Both $check_port > /dev/null
		fi
	elif [ "$auto_remove" -eq 0 ] && [ "$bash_mode" -ne 1 ]; then	# Si l'auto_remove est désactivée. Marque une pause avant de continuer.
		if [ "$no_lxc" -eq 0 ]; then
			echo "Utilisez ssh pour vous connecter au conteneur LXC. 'ssh $ARG_SSH $LXC_NAME'"
		fi
		read -p "Appuyer sur une touche pour continuer les tests..." < /dev/tty
	fi
	YUNOHOST_RESULT=-1
}

PACKAGE_LINTER () {
	# Package linter
	ECHO_FORMAT "\n\n>> Package linter... [Test $cur_test/$all_test]\n" "white" "bold" clog
	cur_test=$((cur_test+1))
	"$script_dir/package_linter/package_linter.py" "$APP_CHECK" | tee "$script_dir/package_linter.log"	# Effectue un test du package avec package_linter
	if grep -q ">>>> " "$script_dir/package_linter.log"; then
		GLOBAL_LINTER=1	# Si au moins 1 header est trouvé, c'est que l'exécution s'est bien déroulée.
	fi
	if grep -q -F "[91m" "$script_dir/package_linter.log"; then	# Si une erreur a été détectée par package_linter.
		GLOBAL_LINTER=-1	# Au moins une erreur a été détectée par package_linter
	fi
	tnote=$((tnote+1))
	if [ "$GLOBAL_LINTER" -eq 1 ]; then
		ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
		note=$((note+1))	# package_linter n'a détecté aucune erreur
	else
		ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
	fi
}

CHECK_CORRUPT () {
	# Test d'erreur sur source corrompue
	ECHO_FORMAT "\n\n>> Source corrompue après téléchargement... [Test $cur_test/$all_test]\n" "white" "bold" clog
	cur_test=$((cur_test+1))
	if [ "$GLOBAL_CHECK_SETUP" -ne 1 ] && [ "$force_install_ok" -ne 1 ]; then
		echo "L'installation a échouée, impossible d'effectuer ce test..."
	fi
echo -n "Non implémenté"
# GLOBAL_CHECK_CORRUPT=0
}
CHECK_DL () {
	# Test d'erreur de téléchargement de la source
	ECHO_FORMAT "\n\n>> Erreur de téléchargement de la source... [Test $cur_test/$all_test]\n" "white" "bold" clog
	cur_test=$((cur_test+1))
	if [ "$GLOBAL_CHECK_SETUP" -ne 1 ] && [ "$force_install_ok" -ne 1 ]; then
		echo "L'installation a échouée, impossible d'effectuer ce test..."
	fi
echo -n "Non implémenté"
# GLOBAL_CHECK_DL=0
}
CHECK_FINALPATH () {
	# Test sur final path déjà utilisé.
	ECHO_FORMAT "\n\n>> Final path déjà utilisé... [Test $cur_test/$all_test]\n" "white" "bold" clog
	cur_test=$((cur_test+1))
	if [ "$GLOBAL_CHECK_SETUP" -ne 1 ] && [ "$force_install_ok" -ne 1 ]; then
		echo "L'installation a échouée, impossible d'effectuer ce test..."
	fi
echo -n "Non implémenté"
# GLOBAL_CHECK_FINALPATH=0
}

TEST_LAUNCHER () {
	# $1 prend le nom de la fonction à démarrer.
	# $2 prend l'argument de la fonction, le cas échéant
	# Ce launcher permet de factoriser le code autour du lancement des fonctions de test
	BUG654=1	# Patch #654
	while [ "$BUG654" -eq "1" ]; do	# Patch #654
		$1 $2	# Exécute le test demandé, avec son éventuel argument
		LXC_STOP	# Arrête le conteneur LXC
		PATCH_654	# Patch #654
		BUG654=$?	# Patch #654
		if [ "$BUG654" -eq "1" ]; then	# Patch #654
			ECHO_FORMAT "\n!! Bug 654 détecté !!\n" "red" clog	# Patch #654
			echo -e "date\nBug 654 sur $1 $2\n\n" >> "$script_dir/patch_#654.log"	# Patch #654
			cur_test=$((cur_test-1))
		fi	# Patch #654
	done	# Patch #654
}

TESTING_PROCESS () {
source "$script_dir/sub_scripts/patch_#654.sh"	# Patch #654
	# Lancement des tests
	cur_test=1
	ECHO_FORMAT "\nScénario de test: $PROCESS_NAME\n" "white" "underlined"
	if [ "$pkg_linter" -eq 1 ]; then
		PACKAGE_LINTER	# Vérification du package avec package linter
	fi
	if [ "$setup_sub_dir" -eq 1 ]; then
		TEST_LAUNCHER CHECK_SETUP_SUBDIR	# Test d'installation en sous-dossier
	fi
	if [ "$setup_root" -eq 1 ]; then
		TEST_LAUNCHER CHECK_SETUP_ROOT	# Test d'installation à la racine du domaine
	fi
	if [ "$setup_nourl" -eq 1 ]; then
		TEST_LAUNCHER CHECK_SETUP_NO_URL	# Test d'installation sans accès par url
	fi
	if [ "$upgrade" -eq 1 ]; then
		TEST_LAUNCHER CHECK_UPGRADE	# Test d'upgrade
	fi
	if [ "$setup_private" -eq 1 ]; then
		TEST_LAUNCHER CHECK_PUBLIC_PRIVATE private	# Test d'installation en privé
	fi
	if [ "$setup_public" -eq 1 ]; then
		TEST_LAUNCHER CHECK_PUBLIC_PRIVATE public	# Test d'installation en public
	fi
	if [ "$multi_instance" -eq 1 ]; then
		TEST_LAUNCHER CHECK_MULTI_INSTANCE	# Test d'installation multiple
	fi
	if [ "$wrong_user" -eq 1 ]; then
		TEST_LAUNCHER CHECK_COMMON_ERROR wrong_user	# Test d'erreur d'utilisateur
	fi
	if [ "$wrong_path" -eq 1 ]; then
		TEST_LAUNCHER CHECK_COMMON_ERROR wrong_path	# Test d'erreur de path ou de domaine
	fi
	if [ "$incorrect_path" -eq 1 ]; then
		TEST_LAUNCHER CHECK_COMMON_ERROR incorrect_path	# Test d'erreur de forme de path
	fi
	if [ "$port_already_use" -eq 1 ]; then
		TEST_LAUNCHER CHECK_COMMON_ERROR port_already_use	# Test d'erreur de port
	fi
	if [ "$corrupt_source" -eq 1 ]; then
		TEST_LAUNCHER CHECK_CORRUPT	# Test d'erreur sur source corrompue -> Comment je vais provoquer ça!?
	fi
	if [ "$fail_download_source" -eq 1 ]; then
		TEST_LAUNCHER CHECK_DL	# Test d'erreur de téléchargement de la source -> Comment!?
	fi
	if [ "$final_path_already_use" -eq 1 ]; then
		TEST_LAUNCHER CHECK_FINALPATH	# Test sur final path déjà utilisé.
	fi
	if [ "$backup_restore" -eq 1 ]; then
		TEST_LAUNCHER CHECK_BACKUP_RESTORE	# Test de backup puis de Restauration
	fi
}
