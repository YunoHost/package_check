#!/bin/bash

RESULT="Test_results.log"
BACKUP_HOOKS="conf_ssowat data_home conf_ynh_firewall conf_cron"	# La liste des hooks disponible pour le backup se trouve dans /usr/share/yunohost/hooks/backup/

echo "Chargement des fonctions de testing_process.sh"

source $abs_path/sub_scripts/log_extractor.sh

echo -n "" > $RESULT	# Initialise le fichier des résulats d'analyse

SETUP_APP () {
# echo -e "MANIFEST_ARGS=$MANIFEST_ARGS_MOD"
	COPY_LOG 1
	sudo yunohost --debug app install $APP_CHECK -a "$MANIFEST_ARGS_MOD" > /dev/null 2>&1
	YUNOHOST_RESULT=$?
	COPY_LOG 2
	APPID=$(grep -o "YNH_APP_INSTANCE_NAME=[^ ]*" "$OUTPUTD" | cut -d '=' -f2)	# Récupère le nom de l'app au moment de l'install. Pour pouvoir le réutiliser dans les commandes yunohost. La regex matche tout ce qui suit le =, jusqu'à l'espace.
}

REMOVE_APP () {
	ECHO_FORMAT "\nSuppression...\n" "white" "bold"
	COPY_LOG 1
	sudo yunohost --debug app remove $APPID > /dev/null 2>&1
	YUNOHOST_REMOVE=$?
	COPY_LOG 2
}

CHECK_URL () {
	ECHO_FORMAT "\nAccès par l'url...\n" "white" "bold"
	echo "127.0.0.1 $DOMAIN #package_check" | sudo tee -a /etc/hosts > /dev/null	# Renseigne le hosts pour le domain à tester, pour passer directement sur localhost
	curl -LksS $DOMAIN/$CHECK_PATH -o url_output
	URL_TITLE=$(grep "<title>" url_output | cut -d '>' -f 2 | cut -d '<' -f1)
	ECHO_FORMAT "Titre de la page: $URL_TITLE\n" "white"
	if [ "$URL_TITLE" == "YunoHost Portal" ]; then
		YUNO_PORTAL=1
		# Il serait utile de réussir à s'authentifier sur le portail pour tester une app protégée par celui-ci. Mais j'y arrive pas...
	else
		YUNO_PORTAL=0
		ECHO_FORMAT "Extrait du corps de la page:\n" "white"
		echo -e "\e[37m"	# Écrit en light grey
		grep "<body" -A 20 url_output | sed 1d | tee -a $RESULT
		echo -e "\e[0m"
	fi
	sudo sed -i '/#package_check/d' /etc/hosts	# Supprime la ligne dans le hosts
}

CHECK_SETUP_SUBDIR () {
	# Test d'installation en sous-dossier
	ECHO_FORMAT "\n\n>> Installation en sous-dossier...\n" "white" "bold"
	MANIFEST_ARGS_MOD=$MANIFEST_ARGS	# Copie des arguments
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_DOMAIN=[a-Z./-$]*\&/$MANIFEST_DOMAIN=$DOMAIN\&/")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=$PATH_TEST\&@")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_USER=[a-Z/-$]*\&@$MANIFEST_USER=$USER_TEST\&@")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PASSWORD=[a-Z$]*\&/$MANIFEST_PASSWORD=$PASSWORD_TEST\&/")
	# Installation de l'app
	SETUP_APP
	LOG_EXTRACTOR
	if [ "$YUNOHOST_RESULT" -eq 0 ]; then
		ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
		GLOBAL_CHECK_SETUP=1	# Installation réussie
		GLOBAL_CHECK_SUB_DIR=1	# Installation en sous-dossier réussie
	else
		ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
		if [ "$GLOBAL_CHECK_SETUP" -ne 1 ]; then
			GLOBAL_CHECK_SETUP=-1	# Installation échouée
		fi
		GLOBAL_CHECK_SUB_DIR=-1	# Installation en sous-dossier échouée
	fi
	# Test l'accès à l'app
	CHECK_PATH=$PATH_TEST
	CHECK_URL
	# Suppression de l'app
	REMOVE_APP
	if [ "$YUNOHOST_RESULT" -eq 0 ]	# Si l'installation a été un succès. On teste la suppression
	then
		LOG_EXTRACTOR
		if [ "$YUNOHOST_REMOVE" -eq 0 ]; then
			ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
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
}

CHECK_SETUP_ROOT () {
	# Test d'installation à la racine
	ECHO_FORMAT "\n\n>> Installation à la racine...\n" "white" "bold"
	MANIFEST_ARGS_MOD=$MANIFEST_ARGS	# Copie des arguments
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_DOMAIN=[a-Z./-$]*\&/$MANIFEST_DOMAIN=$DOMAIN\&/")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=/\&@")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_USER=[a-Z/-$]*\&@$MANIFEST_USER=$USER_TEST\&@")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PASSWORD=[a-Z$]*\&/$MANIFEST_PASSWORD=$PASSWORD_TEST\&/")
	# Installation de l'app
	SETUP_APP
	LOG_EXTRACTOR
	if [ "$YUNOHOST_RESULT" -eq 0 ]; then
		ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
		GLOBAL_CHECK_SETUP=1	# Installation réussie
		GLOBAL_CHECK_ROOT=1	# Installation à la racine réussie
	else
		ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
		if [ "$GLOBAL_CHECK_SETUP" -ne 1 ]; then
			GLOBAL_CHECK_SETUP=-1	# Installation échouée
		fi
		GLOBAL_CHECK_ROOT=-1	# Installation à la racine échouée
	fi
	# Test l'accès à l'app
	CHECK_PATH="/"
	CHECK_URL
	# Suppression de l'app
	REMOVE_APP
	if [ "$YUNOHOST_RESULT" -eq 0 ]	# Si l'installation a été un succès. On teste la suppression
	then
		LOG_EXTRACTOR
		if [ "$YUNOHOST_REMOVE" -eq 0 ]; then
			ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
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
}

CHECK_SETUP_NO_URL () {
	# Test d'installation sans accès par url
	ECHO_FORMAT "\n\n>> Installation sans accès par url...\n" "white" "bold"
	MANIFEST_ARGS_MOD=$MANIFEST_ARGS	# Copie des arguments
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_DOMAIN=[a-Z./-$]*\&/$MANIFEST_DOMAIN=$DOMAIN\&/")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=$PATH_TEST\&@")	# Domain et path ne devrait théoriquement pas être utilisés
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_USER=[a-Z/-$]*\&@$MANIFEST_USER=$USER_TEST\&@")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PASSWORD=[a-Z$]*\&/$MANIFEST_PASSWORD=$PASSWORD_TEST\&/")
	# Installation de l'app
	SETUP_APP
	LOG_EXTRACTOR
	if [ "$YUNOHOST_RESULT" -eq 0 ]; then
		ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
		GLOBAL_CHECK_SETUP=1	# Installation réussie
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
		if [ "$YUNOHOST_REMOVE" -eq 0 ]; then
			ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
			GLOBAL_CHECK_REMOVE_ROOT=1	# Suppression réussie
		else
			ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
			if [ "$GLOBAL_CHECK_REMOVE" -ne 1 ]; then
				GLOBAL_CHECK_REMOVE=-1	# Suppression échouée
			fi
			GLOBAL_CHECK_REMOVE_ROOT=-1	# Suppression échouée
		fi
	fi
}

CHECK_UPGRADE () {
	# Test d'upgrade
	ECHO_FORMAT "\n\n>> Upgrade...\n" "white" "bold"
	if [ "$GLOBAL_CHECK_SETUP" -ne 1 ]; then
		echo "L'installation a échouée, impossible d'effectuer ce test..."
		return;
	fi
	MANIFEST_ARGS_MOD=$MANIFEST_ARGS	# Copie des arguments
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_DOMAIN=[a-Z./-$]*\&/$MANIFEST_DOMAIN=$DOMAIN\&/")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_USER=[a-Z/-$]*\&@$MANIFEST_USER=$USER_TEST\&@")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PASSWORD=[a-Z$]*\&/$MANIFEST_PASSWORD=$PASSWORD_TEST\&/")
	if [ "$GLOBAL_CHECK_SUB_DIR" -eq 1 ]; then	# Si l'install en sub_dir à fonctionné. Utilise ce mode d'installation
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=$PATH_TEST\&@")
		CHECK_PATH="$PATH_TEST"
	elif [ "$GLOBAL_CHECK_ROOT" -eq 1 ]; then	# Sinon utilise une install root, si elle a fonctionné
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=/\&@")
		CHECK_PATH="/"
	else
		echo "Aucun mode d'installation n'a fonctionné, impossible d'effectuer ce test..."
		return;
	fi
	ECHO_FORMAT "\nInstallation préalable..." "white" "bold"
	# Installation de l'app
	SETUP_APP
	ECHO_FORMAT "\nUpgrade sur la même version du package...\n" "white" "bold"
	# Upgrade de l'app
	COPY_LOG 1
	sudo yunohost --debug app upgrade $APPID -f $APP_CHECK > /dev/null 2>&1
	YUNOHOST_RESULT=$?
	COPY_LOG 2
	LOG_EXTRACTOR
	if [ "$YUNOHOST_RESULT" -eq 0 ]; then
		ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
		GLOBAL_CHECK_UPGRADE=1	# Upgrade réussie
	else
		ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
		GLOBAL_CHECK_UPGRADE=-1	# Upgrade échouée
	fi
	# Test l'accès à l'app
	CHECK_URL
	# Suppression de l'app
	REMOVE_APP
}

CHECK_BACKUP_RESTORE () {
	# Test de backup
	ECHO_FORMAT "\n\n>> Backup...\n" "white" "bold"
	if [ "$GLOBAL_CHECK_SETUP" -ne 1 ]; then
		echo "L'installation a échouée, impossible d'effectuer ce test..."
	fi
	MANIFEST_ARGS_MOD=$MANIFEST_ARGS	# Copie des arguments
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_DOMAIN=[a-Z./-$]*\&/$MANIFEST_DOMAIN=$DOMAIN\&/")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_USER=[a-Z/-$]*\&@$MANIFEST_USER=$USER_TEST\&@")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PASSWORD=[a-Z$]*\&/$MANIFEST_PASSWORD=$PASSWORD_TEST\&/")
	if [ "$GLOBAL_CHECK_SUB_DIR" -eq 1 ]; then	# Si l'install en sub_dir à fonctionné. Utilise ce mode d'installation
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=$PATH_TEST\&@")
		CHECK_PATH="$PATH_TEST"
	elif [ "$GLOBAL_CHECK_ROOT" -eq 1 ]; then	# Sinon utilise une install root, si elle a fonctionné
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=/\&@")
		CHECK_PATH="/"
	else
		echo "Aucun mode d'installation n'a fonctionné, impossible d'effectuer ce test..."
		return;
	fi
	ECHO_FORMAT "\nInstallation préalable..." "white" "bold"
	# Installation de l'app
	SETUP_APP
	ECHO_FORMAT "\nBackup de l'application...\n" "white" "bold"
	# Backup de l'app
	COPY_LOG 1
	sudo yunohost --debug backup create -n Backup_test --apps $APPID --hooks $BACKUP_HOOKS > /dev/null 2>&1
	YUNOHOST_RESULT=$?
	COPY_LOG 2
	LOG_EXTRACTOR
	if [ "$YUNOHOST_RESULT" -eq 0 ]; then
		ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
		GLOBAL_CHECK_BACKUP=1	# Backup réussi
	else
		ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
		GLOBAL_CHECK_BACKUP=-1	# Backup échoué
	fi
	# Suppression de l'app
	REMOVE_APP
	ECHO_FORMAT "\nRestauration de l'application...\n" "white" "bold"
	# Restore de l'app
	COPY_LOG 1
	sudo yunohost --debug backup restore Backup_test --force --apps $APPID > /dev/null 2>&1
	YUNOHOST_RESULT=$?
	COPY_LOG 2
	LOG_EXTRACTOR
	if [ "$YUNOHOST_RESULT" -eq 0 ]; then
		ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
		GLOBAL_CHECK_RESTORE=1	# Restore réussi
	else
		ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
		GLOBAL_CHECK_RESTORE=-1	# Restore échoué
	fi
	# Test l'accès à l'app
	CHECK_URL
	# Suppression de l'app
	REMOVE_APP
	# Suppression de l'archive
	sudo yunohost backup delete Backup_test > /dev/null 2>&1
}

CHECK_PUBLIC_PRIVATE () {
	# Test d'installation en public/privé
	if [ "$1" == "private" ]; then
		ECHO_FORMAT "\n\n>> Installation privée...\n" "white" "bold"
	fi
	if [ "$1" == "public" ]; then
		ECHO_FORMAT "\n\n>> Installation publique...\n" "white" "bold"
	fi
	if [ "$GLOBAL_CHECK_SETUP" -ne 1 ]; then
		echo "L'installation a échouée, impossible d'effectuer ce test..."
		return;
	fi
	MANIFEST_ARGS_MOD=$MANIFEST_ARGS	# Copie des arguments
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_DOMAIN=[a-Z./-$]*\&/$MANIFEST_DOMAIN=$DOMAIN\&/")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_USER=[a-Z/-$]*\&@$MANIFEST_USER=$USER_TEST\&@")
	MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PASSWORD=[a-Z$]*\&/$MANIFEST_PASSWORD=$PASSWORD_TEST\&/")
	# Choix public/privé
	if [ "$1" == "private" ]; then
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PUBLIC=[a-Z]*\&/$MANIFEST_PUBLIC=$MANIFEST_PUBLIC_private\&/")
	fi
	if [ "$1" == "public" ]; then
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s/$MANIFEST_PUBLIC=[a-Z]*\&/$MANIFEST_PUBLIC=$MANIFEST_PUBLIC_public\&/")
	fi
	if [ "$GLOBAL_CHECK_SUB_DIR" -eq 1 ]; then	# Si l'install en sub_dir à fonctionné. Utilise ce mode d'installation
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=$PATH_TEST\&@")
		CHECK_PATH="$PATH_TEST"
	elif [ "$GLOBAL_CHECK_ROOT" -eq 1 ]; then	# Sinon utilise une install root, si elle a fonctionné
		MANIFEST_ARGS_MOD=$(echo $MANIFEST_ARGS_MOD | sed "s@$MANIFEST_PATH=[a-Z/$]*\&@$MANIFEST_PATH=/\&@")
		CHECK_PATH="/"
	else
		echo "Aucun mode d'installation n'a fonctionné, impossible d'effectuer ce test..."
		return;
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
	if [ "$YUNOHOST_RESULT" -eq 0 ]; then
		ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
		if [ "$1" == "private" ]; then
			GLOBAL_CHECK_PRIVATE=1	# Installation privée réussie
		fi
		if [ "$1" == "public" ]; then
			GLOBAL_CHECK_PUBLIC=1	# Installation publique réussie
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
	# Suppression de l'app
	REMOVE_APP
}

CHECK_ADMIN () {
	# Test d'erreur d'utilisateur
	ECHO_FORMAT "\n\n>> Erreur d'utilisateur...\n" "white" "bold"
	if [ "$GLOBAL_CHECK_SETUP" -ne 1 ]; then
		echo "L'installation a échouée, impossible d'effectuer ce test..."
	fi
echo "Non implémenté"
# GLOBAL_CHECK_ADMIN=0
}
CHECK_DOMAIN () {
	# Test d'erreur de path ou de domaine
	ECHO_FORMAT "\n\n>> Erreur de domaine...\n" "white" "bold"
	if [ "$GLOBAL_CHECK_SETUP" -ne 1 ]; then
		echo "L'installation a échouée, impossible d'effectuer ce test..."
	fi
echo "Non implémenté"
# GLOBAL_CHECK_DOMAIN=0
}
CHECK_PATH () {
	# Test d'erreur de forme de path
	ECHO_FORMAT "\n\n>> Path mal formé...\n" "white" "bold"
	if [ "$GLOBAL_CHECK_SETUP" -ne 1 ]; then
		echo "L'installation a échouée, impossible d'effectuer ce test..."
	fi
echo "Non implémenté"
# GLOBAL_CHECK_PATH=0
}
CHECK_CORRUPT () {
	# Test d'erreur sur source corrompue
	ECHO_FORMAT "\n\n>> Source corrompue après téléchargement...\n" "white" "bold"
	if [ "$GLOBAL_CHECK_SETUP" -ne 1 ]; then
		echo "L'installation a échouée, impossible d'effectuer ce test..."
	fi
echo "Non implémenté"
# GLOBAL_CHECK_CORRUPT=0
}
CHECK_DL () {
	# Test d'erreur de téléchargement de la source
	ECHO_FORMAT "\n\n>> Erreur de téléchargement de la source...\n" "white" "bold"
	if [ "$GLOBAL_CHECK_SETUP" -ne 1 ]; then
		echo "L'installation a échouée, impossible d'effectuer ce test..."
	fi
echo "Non implémenté"
# GLOBAL_CHECK_DL=0
}
CHECK_PORT () {
	# Test d'erreur de port
	ECHO_FORMAT "\n\n>> Port déjà utilisé...\n" "white" "bold"
	if [ "$GLOBAL_CHECK_SETUP" -ne 1 ]; then
		echo "L'installation a échouée, impossible d'effectuer ce test..."
	fi
echo "Non implémenté"
# GLOBAL_CHECK_PORT=0
}
CHECK_FINALPATH () {
	# Test sur final path déjà utilisé.
	ECHO_FORMAT "\n\n>> Final path déjà utilisé...\n" "white" "bold"
	if [ "$GLOBAL_CHECK_SETUP" -ne 1 ]; then
		echo "L'installation a échouée, impossible d'effectuer ce test..."
	fi
echo "Non implémenté"
# GLOBAL_CHECK_FINALPATH=0
}

TESTING_PROCESS () {
	# Lancement des tests
	ECHO_FORMAT "\nScénario de test: $PROCESS_NAME\n" "white" "underlined"
	if [ "$setup_sub_dir" -eq 1 ]; then
		CHECK_SETUP_SUBDIR	# Test d'installation en sous-dossier
	fi
	if [ "$setup_root" -eq 1 ]; then
		CHECK_SETUP_ROOT	# Test d'installation à la racine du domaine
	fi
	if [ "$setup_nourl" -eq 1 ]; then
		CHECK_SETUP_NO_URL	# Test d'installation sans accès par url
	fi
	CHECK_UPGRADE
	if [ "$setup_private" -eq 1 ]; then
		CHECK_PUBLIC_PRIVATE private	# Test d'installation en privé
	fi
	if [ "$setup_public" -eq 1 ]; then
		CHECK_PUBLIC_PRIVATE public	# Test d'installation en public
	fi
	if [ "$wrong_user" -eq 1 ]; then
		CHECK_ADMIN	# Test d'erreur d'utilisateur
	fi
	if [ "$wrong_path" -eq 1 ]; then
		CHECK_DOMAIN	# Test d'erreur de path ou de domaine
	fi
	if [ "$incorrect_path" -eq 1 ]; then
		CHECK_PATH	# Test d'erreur de forme de path
	fi
	if [ "$corrupt_source" -eq 1 ]; then
		CHECK_CORRUPT	# Test d'erreur sur source corrompue -> Comment je vais provoquer ça!?
	fi
	if [ "$fail_download_source" -eq 1 ]; then
		CHECK_DL	# Test d'erreur de téléchargement de la source -> Comment!?
	fi
	if [ "$port_already_use" -eq 1 ]; then
		CHECK_PORT	# Test d'erreur de port
	fi
	if [ "$final_path_already_use" -eq 1 ]; then
		CHECK_FINALPATH	# Test sur final path déjà utilisé.
	fi
	CHECK_BACKUP_RESTORE
}
