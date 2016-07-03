#!/bin/bash

ARG_SSH="-t"
PLAGE_IP=$(cat sub_scripts/lxc_build.sh | grep PLAGE_IP= | cut -d '"' -f2)

echo -e "\nChargement des fonctions de lxc_launcher.sh"

LXC_INIT () {
	# Activation du bridge réseau
	echo "Initialisation du réseau pour le conteneur."
	sudo ifup lxc-pchecker | tee -a $RESULT 2>&1

	# Activation des règles iptables
	sudo iptables -A FORWARD -i lxc-pchecker -o eth0 -j ACCEPT | tee -a $RESULT 2>&1
	sudo iptables -A FORWARD -i eth0 -o lxc-pchecker -j ACCEPT | tee -a $RESULT 2>&1
	sudo iptables -t nat -A POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE | tee -a $RESULT 2>&1

	if [ "$no_lxc" -eq 0 ]; then
		YUNOHOST_LOG=/var/lib/lxc/$LXC_NAME/rootfs$YUNOHOST_LOG	#Prend le log de la machine lxc plutôt que celui de l'hôte
	fi
}

LXC_START () {
	if [ "$no_lxc" -eq 0 ]
	then
		# Démarrage de la machine
		sudo lxc-start -n $LXC_NAME -d | tee -a $RESULT 2>&1
		for i in `seq 1 10`
		do	# Vérifie que la machine est accessible en ssh avant de commencer. Il lui faut le temps de démarrer.
			echo -n .
			if ssh $ARG_SSH $LXC_NAME "exit 0" > /dev/null 2>&1; then
				break
			fi
			sleep 1
		done
		sudo lxc-ls -f | grep $LXC_NAME | sed 's/-     NO//'
		if [ $(sudo lxc-info --name $LXC_NAME | grep -c "STOPPED") -ne 0 ]; then
			ECHO_FORMAT "Le conteneur n'a pas démarré correctement...\n" "lred" "bold"
			return 1
		fi
		scp -rq "$APP_CHECK" "$LXC_NAME": >> $RESULT 2>&1
		ssh $ARG_SSH $LXC_NAME "$1 > /dev/null 2>> \"$OUTPUTD\"; exit \$?" >> $RESULT 2>&1	# Exécute la commande dans la machine LXC
		sudo cat "/var/lib/lxc/$LXC_NAME/rootfs/home/pchecker/$OUTPUTD" >> "$OUTPUTD" # Récupère le contenu du OUTPUTD distant pour le réinjecter dans le local
		return "$?"
	else	# Sinon exécute la commande directement.
 		command=$(echo "$1" | sed "s@\"@@g")	# Remplace les guillemets doubles par des simples 
		$command > /dev/null 2>> "$OUTPUTD"
	fi
}

LXC_STOP () {
	if [ "$no_lxc" -eq 0 ]
	then
		# Arrêt de la machine virtualisée
		if [ $(sudo lxc-info --name $LXC_NAME | grep -c "STOPPED") -eq 0 ]; then
			echo "Arrêt du conteneur LXC" | tee -a $RESULT
			sudo lxc-stop -n $LXC_NAME | tee -a $RESULT 2>&1
		fi		
		# Restaure le snapshot.
		echo "Restauration du snapshot de la machine lxc" | tee -a $RESULT
		sudo rsync -aEAX --delete -i /var/lib/lxcsnaps/$LXC_NAME/snap0/rootfs/ /var/lib/lxc/$LXC_NAME/rootfs/ >> $RESULT 2>&1
	fi
}

LXC_TURNOFF () {
	echo "Arrêt du réseau pour le conteneur."
	# Suppression des règles de parefeu
	if sudo iptables -D FORWARD -i lxc-pchecker -o eth0 -j ACCEPT 2> /dev/null
	then
		sudo iptables -D FORWARD -i lxc-pchecker -o eth0 -j ACCEPT >> $RESULT 2>&1
	fi
	if sudo iptables -C FORWARD -i eth0 -o lxc-pchecker -j ACCEPT 2> /dev/null
	then
		sudo iptables -D FORWARD -i eth0 -o lxc-pchecker -j ACCEPT | tee -a $RESULT 2>&1
	fi
	if sudo iptables -t nat -C POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE 2> /dev/null
	then
		sudo iptables -t nat -D POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE | tee -a $RESULT 2>&1
	fi
	# Et arrêt du bridge
	if sudo ifquery lxc-pchecker --state > /dev/null
	then
		sudo ifdown lxc-pchecker | tee -a $RESULT 2>&1
	fi
}
