#!/bin/bash

USER_TEST=package_checker
PASSWORD_TEST=checker_pwd
PATH_TEST=/check
DOMAIN=$(sudo yunohost domain list -l 1 | cut -d" " -f 2)

abs_path=$(cd $(dirname $0); pwd)	# Récupère le chemin absolu du script.

source $abs_path/sub_scripts/testing_process.sh
source /usr/share/yunohost/helpers

# Vérifie l'existence de l'utilisateur de test
if ! ynh_user_exists "$USER_TEST" ; then	# Si il n'existe pas, il faut le créer.
	USER_TEST_CLEAN=${USER_TEST//"_"/""}
	sudo yunohost user create --firstname "$USER_TEST_CLEAN" --mail "$USER_TEST_CLEAN@$DOMAIN" --lastname "$USER_TEST_CLEAN" --password "$PASSWORD_TEST" "$USER_TEST"
fi

# Vérifie le type d'emplacement du package à tester
if echo "$1" | grep -Eq "https?:\/\/"
then
	GIT_PACKAGE=1
	git clone $1 $(basename $1)
	$1 = $(basename $1)
fi
APP_CHECK=$1

# Vérifie l'existence du fichier check_process
if [ ! -e $APP_CHECK/check_process ]; then
	echo "Impossible de trouver le fichier check_process pour procéder aux tests."
	exit 1
fi

## Parsing du fichier check_process de manière séquentielle.
GLOBAL_CHECK_SETUP=0
GLOBAL_CHECK_SUB_DIR=0
GLOBAL_CHECK_ROOT=0
GLOBAL_CHECK_REMOVE=0
GLOBAL_CHECK_REMOVE_SUBDIR=0
GLOBAL_CHECK_REMOVE_ROOT=0
GLOBAL_CHECK_UPGRADE=0
GLOBAL_CHECK_BACKUP=0
GLOBAL_CHECK_RESTORE=0
GLOBAL_CHECK_PRIVATE=0
GLOBAL_CHECK_PUBLIC=0
GLOBAL_CHECK_ADMIN=0
GLOBAL_CHECK_DOMAIN=0
GLOBAL_CHECK_PATH=0
GLOBAL_CHECK_CORRUPT=0
GLOBAL_CHECK_DL=0
GLOBAL_CHECK_PORT=0
GLOBAL_CHECK_FINALPATH=0
IN_PROCESS=0
MANIFEST=0
CHECKS=0
while read LIGNE
do
	if echo "$LIGNE" | grep -q "^##"; then	# Début d'un scénario de test
		if [ "$IN_PROCESS" -eq 1 ]; then	# Un scénario est déjà en cours. Donc on a atteind la fin du scénario.
			TESTING_PROCESS
		fi
		PROCESS_NAME=${LIGNE#\#\# }
		IN_PROCESS=1
	fi
	if [ "$IN_PROCESS" -eq 1 ]
	then	# Analyse des arguments du scenario de test
		if echo "$LIGNE" | grep -q "# Manifest"; then	# Arguments du manifest
			MANIFEST=1
			MANIFEST_ARGS=""	# Initialise la chaine des arguments d'installation
		fi
		if echo "$LIGNE" | grep -q "# Checks"; then	# Tests à effectuer
			MANIFEST=0
			CHECKS=1
			setup_sub_dir=0
			setup_root=0
			setup_private=0
			setup_public=0
			wrong_user=0
			wrong_path=0
			incorrect_path=0
			corrupt_source=0
			fail_download_source=0
			port_already_use=0
			final_path_already_use=0
		fi
		if [ "$MANIFEST" -eq 1 ]
		then	# Analyse des arguments du manifest
			if echo "$LIGNE" | grep -q "="; then
				if [ "${#MANIFEST_ARGS}" -gt 0 ]; then	# Si il y a déjà des arguments
					MANIFEST_ARGS="$MANIFEST_ARGS&"	#, précède de &
				fi
				MANIFEST_ARGS="$MANIFEST_ARGS$(echo $LIGNE | sed 's/[ \"]//g')"	# Ajoute l'argument du manifest, en retirant les espaces et les guillemets.
			fi
		fi
		if [ "$CHECKS" -eq 1 ]
		then	# Analyse des tests à effectuer sur ce scenario.
			if echo "$LIGNE" | grep -q "setup_sub_dir="; then	# Test d'installation en sous-dossier
				setup_sub_dir=$(echo "$LIGNE" | cut -d '=' -f2)
			fi
			if echo "$LIGNE" | grep -q "setup_root="; then	# Test d'installation à la racine
				setup_root=$(echo "$LIGNE" | cut -d '=' -f2)
			fi
			if echo "$LIGNE" | grep -q "setup_nourl="; then	# Test d'installation sans accès par url
				setup_nourl=$(echo "$LIGNE" | cut -d '=' -f2)
			fi
			if echo "$LIGNE" | grep -q "setup_private="; then	# Test d'installation en privé
				setup_private=$(echo "$LIGNE" | cut -d '=' -f2)
			fi
			if echo "$LIGNE" | grep -q "setup_public="; then	# Test d'installation en public
				setup_public=$(echo "$LIGNE" | cut -d '=' -f2)
			fi
			if echo "$LIGNE" | grep -q "wrong_user="; then	# Test d'erreur d'utilisateur
				wrong_user=$(echo "$LIGNE" | cut -d '=' -f2)
			fi
			if echo "$LIGNE" | grep -q "wrong_path="; then	# Test d'erreur de path ou de domaine
				wrong_path=$(echo "$LIGNE" | cut -d '=' -f2)
			fi
			if echo "$LIGNE" | grep -q "incorrect_path="; then	# Test d'erreur de forme de path
				incorrect_path=$(echo "$LIGNE" | cut -d '=' -f2)
			fi
			if echo "$LIGNE" | grep -q "corrupt_source="; then	# Test d'erreur sur source corrompue
				corrupt_source=$(echo "$LIGNE" | cut -d '=' -f2)
			fi
			if echo "$LIGNE" | grep -q "fail_download_source="; then	# Test d'erreur de téléchargement de la source
				fail_download_source=$(echo "$LIGNE" | cut -d '=' -f2)
			fi
			if echo "$LIGNE" | grep -q "port_already_use="; then	# Test d'erreur de port
				port_already_use=$(echo "$LIGNE" | cut -d '=' -f2)
			fi
			if echo "$LIGNE" | grep -q "final_path_already_use="; then	# Test sur final path déjà utilisé.
				final_path_already_use=$(echo "$LIGNE" | cut -d '=' -f2)
			fi
		fi

	fi
done < "$APP_CHECK/check_process"

TESTING_PROCESS

ECHO_FORMAT "Installation: "
if [ "$GLOBAL_CHECK_SETUP" -eq 1 ]; then
	ECHO_FORMAT "SUCCESS\n" "lgreen"
elif [ "$GLOBAL_CHECK_SETUP" -eq -1 ]; then
	ECHO_FORMAT "FAIL\n" "lred"
else
	ECHO_FORMAT "Not evaluated.\n" "white"
fi

ECHO_FORMAT "Installation en sous-dossier: "
if [ "$GLOBAL_CHECK_SUB_DIR" -eq 1 ]; then
	ECHO_FORMAT "SUCCESS\n" "lgreen"
elif [ "$GLOBAL_CHECK_SUB_DIR" -eq -1 ]; then
	ECHO_FORMAT "FAIL\n" "lred"
else
	ECHO_FORMAT "Not evaluated.\n" "white"
fi

ECHO_FORMAT "Installation à la racine: "
if [ "$GLOBAL_CHECK_ROOT" -eq 1 ]; then
	ECHO_FORMAT "SUCCESS\n" "lgreen"
elif [ "$GLOBAL_CHECK_ROOT" -eq -1 ]; then
	ECHO_FORMAT "FAIL\n" "lred"
else
	ECHO_FORMAT "Not evaluated.\n" "white"
fi

ECHO_FORMAT "Suppression: "
if [ "$GLOBAL_CHECK_REMOVE" -eq 1 ]; then
	ECHO_FORMAT "SUCCESS\n" "lgreen"
elif [ "$GLOBAL_CHECK_REMOVE" -eq -1 ]; then
	ECHO_FORMAT "FAIL\n" "lred"
else
	ECHO_FORMAT "Not evaluated.\n" "white"
fi

ECHO_FORMAT "Suppression depuis sous-dossier: "
if [ "$GLOBAL_CHECK_REMOVE_SUBDIR" -eq 1 ]; then
	ECHO_FORMAT "SUCCESS\n" "lgreen"
elif [ "$GLOBAL_CHECK_REMOVE_SUBDIR" -eq -1 ]; then
	ECHO_FORMAT "FAIL\n" "lred"
else
	ECHO_FORMAT "Not evaluated.\n" "white"
fi

ECHO_FORMAT "Suppression depuis racine: "
if [ "$GLOBAL_CHECK_REMOVE_ROOT" -eq 1 ]; then
	ECHO_FORMAT "SUCCESS\n" "lgreen"
elif [ "$GLOBAL_CHECK_REMOVE_ROOT" -eq -1 ]; then
	ECHO_FORMAT "FAIL\n" "lred"
else
	ECHO_FORMAT "Not evaluated.\n" "white"
fi

ECHO_FORMAT "Upgrade: "
if [ "$GLOBAL_CHECK_UPGRADE" -eq 1 ]; then
	ECHO_FORMAT "SUCCESS\n" "lgreen"
elif [ "$GLOBAL_CHECK_UPGRADE" -eq -1 ]; then
	ECHO_FORMAT "FAIL\n" "lred"
else
	ECHO_FORMAT "Not evaluated.\n" "white"
fi

ECHO_FORMAT "Backup: "
if [ "$GLOBAL_CHECK_BACKUP" -eq 1 ]; then
	ECHO_FORMAT "SUCCESS\n" "lgreen"
elif [ "$GLOBAL_CHECK_BACKUP" -eq -1 ]; then
	ECHO_FORMAT "FAIL\n" "lred"
else
	ECHO_FORMAT "Not evaluated.\n" "white"
fi

ECHO_FORMAT "Restore: "
if [ "$GLOBAL_CHECK_RESTORE" -eq 1 ]; then
	ECHO_FORMAT "SUCCESS\n" "lgreen"
elif [ "$GLOBAL_CHECK_RESTORE" -eq -1 ]; then
	ECHO_FORMAT "FAIL\n" "lred"
else
	ECHO_FORMAT "Not evaluated.\n" "white"
fi

ECHO_FORMAT "Installation privée: "
if [ "$GLOBAL_CHECK_PRIVATE" -eq 1 ]; then
	ECHO_FORMAT "SUCCESS\n" "lgreen"
elif [ "$GLOBAL_CHECK_PRIVATE" -eq -1 ]; then
	ECHO_FORMAT "FAIL\n" "lred"
else
	ECHO_FORMAT "Not evaluated.\n" "white"
fi

ECHO_FORMAT "Installation publique: "
if [ "$GLOBAL_CHECK_PUBLIC" -eq 1 ]; then
	ECHO_FORMAT "SUCCESS\n" "lgreen"
elif [ "$GLOBAL_CHECK_PUBLIC" -eq -1 ]; then
	ECHO_FORMAT "FAIL\n" "lred"
else
	ECHO_FORMAT "Not evaluated.\n" "white"
fi

ECHO_FORMAT "Mauvais utilisateur: "
if [ "$GLOBAL_CHECK_ADMIN" -eq 1 ]; then
	ECHO_FORMAT "SUCCESS\n" "lgreen"
elif [ "$GLOBAL_CHECK_ADMIN" -eq -1 ]; then
	ECHO_FORMAT "FAIL\n" "lred"
else
	ECHO_FORMAT "Not evaluated.\n" "white"
fi

ECHO_FORMAT "Erreur de domaine: "
if [ "$GLOBAL_CHECK_DOMAIN" -eq 1 ]; then
	ECHO_FORMAT "SUCCESS\n" "lgreen"
elif [ "$GLOBAL_CHECK_DOMAIN" -eq -1 ]; then
	ECHO_FORMAT "FAIL\n" "lred"
else
	ECHO_FORMAT "Not evaluated.\n" "white"
fi

ECHO_FORMAT "Correction de path: "
if [ "$GLOBAL_CHECK_PATH" -eq 1 ]; then
	ECHO_FORMAT "SUCCESS\n" "lgreen"
elif [ "$GLOBAL_CHECK_PATH" -eq -1 ]; then
	ECHO_FORMAT "FAIL\n" "lred"
else
	ECHO_FORMAT "Not evaluated.\n" "white"
fi

ECHO_FORMAT "Source corrompue: "
if [ "$GLOBAL_CHECK_CORRUPT" -eq 1 ]; then
	ECHO_FORMAT "SUCCESS\n" "lgreen"
elif [ "$GLOBAL_CHECK_CORRUPT" -eq -1 ]; then
	ECHO_FORMAT "FAIL\n" "lred"
else
	ECHO_FORMAT "Not evaluated.\n" "white"
fi

ECHO_FORMAT "Erreur de téléchargement de la source: "
if [ "$GLOBAL_CHECK_DL" -eq 1 ]; then
	ECHO_FORMAT "SUCCESS\n" "lgreen"
elif [ "$GLOBAL_CHECK_DL" -eq -1 ]; then
	ECHO_FORMAT "FAIL\n" "lred"
else
	ECHO_FORMAT "Not evaluated.\n" "white"
fi

ECHO_FORMAT "Port déjà utilisé: "
if [ "$GLOBAL_CHECK_PORT" -eq 1 ]; then
	ECHO_FORMAT "SUCCESS\n" "lgreen"
elif [ "$GLOBAL_CHECK_PORT" -eq -1 ]; then
	ECHO_FORMAT "FAIL\n" "lred"
else
	ECHO_FORMAT "Not evaluated.\n" "white"
fi

ECHO_FORMAT "Dossier déjà utilisé: "
if [ "$GLOBAL_CHECK_FINALPATH" -eq 1 ]; then
	ECHO_FORMAT "SUCCESS\n" "lgreen"
elif [ "$GLOBAL_CHECK_FINALPATH" -eq -1 ]; then
	ECHO_FORMAT "FAIL\n" "lred"
else
	ECHO_FORMAT "Not evaluated.\n" "white"
fi
