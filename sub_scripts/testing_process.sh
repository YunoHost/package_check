#!/bin/bash

RESULT="Test_results.log"

echo "Chargement des fonctions de testing_process.sh"

source $abs_path/sub_scripts/log_extractor.sh

echo -n "" > $RESULT	# Initialise le fichier des résulats d'analyse

SETUP_APP () {
# echo -e "\nMANIFEST_ARGS=$MANIFEST_ARGS_MOD\n"
	sudo yunohost --debug app install $APP_CHECK -a "$MANIFEST_ARGS_MOD" > /dev/null 2>&1
	YUNOHOST_RESULT=$?
}

REMOVE_APP () {
	sudo yunohost --debug app remove $APPID > /dev/null 2>&1
	YUNOHOST_REMOVE=$?
}

CHECK_URL () {
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
	ECHO_FORMAT "\n>>Installation en sous-dossier...\n" "white" "bold"
	MANIFEST_ARGS_MOD=$MANIFEST_ARGS	# Copie des arguments
	MANIFEST_ARGS_MOD=${MANIFEST_ARGS_MOD//'$DOMAIN'/"$DOMAIN"}
	MANIFEST_ARGS_MOD=${MANIFEST_ARGS_MOD//'$PATH'/"$PATH_TEST"}
	MANIFEST_ARGS_MOD=${MANIFEST_ARGS_MOD//'$USER'/"$USER_TEST"}
	MANIFEST_ARGS_MOD=${MANIFEST_ARGS_MOD//'$PASSWORD'/"$PASSWORD_TEST"}
	COPY_LOG 1
	# Installation de l'app
	SETUP_APP
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
	COPY_LOG 2
	LOG_EXTRACTOR
	APPID=$(grep -o "YNH_APP_INSTANCE_NAME=[^ ]*" "$OUTPUTD" | cut -d '=' -f2)	# Récupère le nom de l'app au moment de l'install. Pour pouvoir le réutiliser dans les commandes yunohost. La regex matche tout ce qui suit le =, jusqu'à l'espace.
	ECHO_FORMAT "\nAccès par l'url...\n" "white" "bold"
	# Test l'accès à l'app
	CHECK_PATH=$PATH_TEST
	CHECK_URL
	COPY_LOG 1
	ECHO_FORMAT "\nSuppression...\n" "white" "bold"
	# Suppression de l'app
	REMOVE_APP
	if [ "$YUNOHOST_RESULT" -eq 0 ]	# Si l'installation a été un succès. On teste la suppression
	then
		if [ "$YUNOHOST_REMOVE" -eq 0 ]; then
			ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
			GLOBAL_CHECK_REMOVE_SUBDIR=1	# Suppression réussie
		else
			ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
			if [ "$GLOBAL_CHECK_REMOVE" -ne 1 ]; then
				GLOBAL_CHECK_REMOVE=-1	# Suppression échouée
			fi
			GLOBAL_CHECK_REMOVE_SUBDIR=-1	# Suppression échouée
		fi
		COPY_LOG 2
		LOG_EXTRACTOR
	fi
}

CHECK_SETUP_ROOT () {
	# Test d'installation à la racine
	ECHO_FORMAT "\n>>Installation à la racine...\n" "white" "bold"
	MANIFEST_ARGS_MOD=$MANIFEST_ARGS	# Copie des arguments
	MANIFEST_ARGS_MOD=${MANIFEST_ARGS_MOD//'$DOMAIN'/"$DOMAIN"}
	MANIFEST_ARGS_MOD=${MANIFEST_ARGS_MOD//'$PATH'/"$PATH_TEST"}	# Domain et path ne devrait théoriquement pas être utilisés
	MANIFEST_ARGS_MOD=${MANIFEST_ARGS_MOD//'$USER'/"$USER_TEST"}
	MANIFEST_ARGS_MOD=${MANIFEST_ARGS_MOD//'$PASSWORD'/"$PASSWORD_TEST"}
	COPY_LOG 1
	# Installation de l'app
	SETUP_APP
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
	COPY_LOG 2
	LOG_EXTRACTOR
	APPID=$(grep -o "YNH_APP_INSTANCE_NAME=[^ ]*" "$OUTPUTD" | cut -d '=' -f2)	# Récupère le nom de l'app au moment de l'install. Pour pouvoir le réutiliser dans les commandes yunohost. La regex matche tout ce qui suit le =, jusqu'à l'espace.
	ECHO_FORMAT "\nAccès par l'url...\n" "white" "bold"
	# Test l'accès à l'app
	CHECK_PATH="/"
	CHECK_URL
	COPY_LOG 1
	ECHO_FORMAT "\nSuppression...\n" "white" "bold"
	# Suppression de l'app
	REMOVE_APP
	if [ "$YUNOHOST_RESULT" -eq 0 ]	# Si l'installation a été un succès. On teste la suppression
	then
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
		COPY_LOG 2
		LOG_EXTRACTOR
	fi
}

CHECK_SETUP_NO_URL () {
	# Test d'installation sans accès par url
	ECHO_FORMAT "\n>>Installation sans accès par url...\n" "white" "bold"
	MANIFEST_ARGS_MOD=$MANIFEST_ARGS	# Copie des arguments
	MANIFEST_ARGS_MOD=${MANIFEST_ARGS_MOD//'$DOMAIN'/"$DOMAIN"}
	MANIFEST_ARGS_MOD=${MANIFEST_ARGS_MOD//'$PATH'/"/"}
	MANIFEST_ARGS_MOD=${MANIFEST_ARGS_MOD//'$USER'/"$USER_TEST"}
	MANIFEST_ARGS_MOD=${MANIFEST_ARGS_MOD//'$PASSWORD'/"$PASSWORD_TEST"}
	COPY_LOG 1
	# Installation de l'app
	SETUP_APP
	if [ "$YUNOHOST_RESULT" -eq 0 ]; then
		ECHO_FORMAT "--- SUCCESS ---\n" "lgreen" "bold"
		GLOBAL_CHECK_SETUP=1	# Installation réussie
	else
		ECHO_FORMAT "--- FAIL ---\n" "lred" "bold"
		if [ "$GLOBAL_CHECK_SETUP" -ne 1 ]; then
			GLOBAL_CHECK_SETUP=-1	# Installation échouée
		fi
	fi
	COPY_LOG 2
	LOG_EXTRACTOR
	APPID=$(grep -o "YNH_APP_INSTANCE_NAME=[^ ]*" "$OUTPUTD" | cut -d '=' -f2)	# Récupère le nom de l'app au moment de l'install. Pour pouvoir le réutiliser dans les commandes yunohost. La regex matche tout ce qui suit le =, jusqu'à l'espace.
	COPY_LOG 1
	ECHO_FORMAT "\nSuppression...\n" "white" "bold"
	# Suppression de l'app
	REMOVE_APP
	if [ "$YUNOHOST_RESULT" -eq 0 ]	# Si l'installation a été un succès. On teste la suppression
	then
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
		COPY_LOG 2
		LOG_EXTRACTOR
	fi
}

CHECK_UPGRADE () {
echo "Non implémenté"
# GLOBAL_CHECK_UPGRADE=0
}
CHECK_BACKUP () {
echo "Non implémenté"
# GLOBAL_CHECK_BACKUP=0
}
CHECK_RESTORE () {
echo "Non implémenté"
# GLOBAL_CHECK_RESTORE=0
}
CHECK_PRIVATE () {
echo "Non implémenté"
# GLOBAL_CHECK_PRIVATE=0
}
CHECK_PUBLIC () {
echo "Non implémenté"
# GLOBAL_CHECK_PUBLIC=0
}
CHECK_ADMIN () {
echo "Non implémenté"
# GLOBAL_CHECK_ADMIN=0
}
CHECK_DOMAIN () {
echo "Non implémenté"
# GLOBAL_CHECK_DOMAIN=0
}
CHECK_PATH () {
echo "Non implémenté"
# GLOBAL_CHECK_PATH=0
}
CHECK_CORRUPT () {
echo "Non implémenté"
# GLOBAL_CHECK_CORRUPT=0
}
CHECK_DL () {
echo "Non implémenté"
# GLOBAL_CHECK_DL=0
}
CHECK_PORT () {
echo "Non implémenté"
# GLOBAL_CHECK_PORT=0
}
CHECK_FINALPATH () {
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
	CHECK_BACKUP
	CHECK_RESTORE
	if [ "$setup_private" -eq 1 ]; then
		CHECK_PRIVATE	# Test d'installation en privé
	fi
	if [ "$setup_public" -eq 1 ]; then
		CHECK_PUBLIC	# Test d'installation en public
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
}
