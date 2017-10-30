#!/bin/bash

# Test différents aspect du conteneur pour chercher d'éventuelles erreurs.
# Et tente de réparer si possible...

# Récupère le dossier du script
if [ "${0:0:1}" == "/" ]; then script_dir="$(dirname "$0")"; else script_dir="$(echo $PWD/$(dirname "$0" | cut -d '.' -f2) | sed 's@/$@@')"; fi

ARG_SSH="-t"
# Récupère les informations depuis le fichier de conf (Ou le complète le cas échéant)
pcheck_config="$script_dir/../config"
# Tente de lire les informations depuis le fichier de config si il existe
if [ -e "$pcheck_config" ]
then
	PLAGE_IP=$(cat "$pcheck_config" | grep PLAGE_IP= | cut -d '=' -f2)
	DOMAIN=$(cat "$pcheck_config" | grep DOMAIN= | cut -d '=' -f2)
	YUNO_PWD=$(cat "$pcheck_config" | grep YUNO_PWD= | cut -d '=' -f2)
	LXC_NAME=$(cat "$pcheck_config" | grep LXC_NAME= | cut -d '=' -f2)
	LXC_BRIDGE=$(cat "$pcheck_config" | grep LXC_BRIDGE= | cut -d '=' -f2)
	main_iface=$(cat "$pcheck_config" | grep iface= | cut -d '=' -f2)
fi

# Use the default value and set it in the config file
replace_default_value () {
	CONFIG_KEY=$1
	local value=$(grep "|| $CONFIG_KEY=" "$build_script" | cut -d '=' -f2)
	if grep -q $CONFIG_KEY= "$pcheck_config"
	then
		sed -i "s/$CONFIG_KEY=.*/$CONFIG_KEY=$value/" "$pcheck_config"
	else
		echo -e "$CONFIG_KEY=$value\n" >> "$pcheck_config"
	fi
	echo $value
}

# Utilise des valeurs par défaut si les variables sont vides, et génère le fichier de config
if [ -z "$PLAGE_IP" ]; then
	PLAGE_IP=$(replace_default_value PLAGE_IP)
fi
if [ -z "$DOMAIN" ]; then
	DOMAIN=$(replace_default_value DOMAIN)
fi
if [ -z "$YUNO_PWD" ]; then
	YUNO_PWD=$(replace_default_value YUNO_PWD)
fi
if [ -z "$LXC_NAME" ]; then
	LXC_NAME=$(replace_default_value LXC_NAME)
fi
if [ -z "$LXC_BRIDGE" ]; then
	LXC_BRIDGE=$(replace_default_value LXC_BRIDGE)
fi
if [ -z "$main_iface" ]; then
	# Tente de définir l'interface réseau principale
	main_iface=$(sudo ip route | grep default | awk '{print $5;}')	# Prend l'interface réseau défini par default
	if [ -z $main_iface ]; then
		echo -e "\e[91mImpossible de déterminer le nom de l'interface réseau de l'hôte.\e[0m"
		exit 1
	fi
	# Store the main iface in the config file
	if grep -q iface= "$pcheck_config"
	then
		sed -i "s/iface=.*/iface=$main_iface/"
	else
		echo -e "# Main host iface\niface=$main_iface\n" >> "$pcheck_config"
	fi
fi

STOP_CONTAINER () {
        echo "Arrêt du conteneur $LXC_NAME"
	sudo lxc-stop -n $LXC_NAME
}

START_NETWORK () {
	echo "Initialisation du réseau pour le conteneur."
	sudo ifup $LXC_BRIDGE --interfaces=/etc/network/interfaces.d/$LXC_BRIDGE
	# Activation des règles iptables
	sudo iptables -A FORWARD -i $LXC_BRIDGE -o $main_iface -j ACCEPT
	sudo iptables -A FORWARD -i $main_iface -o $LXC_BRIDGE -j ACCEPT
	sudo iptables -t nat -A POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE
}

STOP_NETWORK () {
	echo "Arrêt du réseau pour le conteneur."
        sudo iptables -D FORWARD -i $LXC_BRIDGE -o $main_iface -j ACCEPT > /dev/null 2>&1
        sudo iptables -D FORWARD -i $main_iface -o $LXC_BRIDGE -j ACCEPT > /dev/null 2>&1
	sudo iptables -t nat -D POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE > /dev/null 2>&1
	sudo ifdown --force $LXC_BRIDGE > /dev/null 2>&1
}

REBOOT_CONTENEUR () {
    echo "Redémarrage du conteneur."
    STOP_CONTAINER
    STOP_NETWORK
    START_NETWORK
    echo "Démarrage du conteneur."
    sudo lxc-start -n $LXC_NAME -d > /dev/null 2>&1	# Démarre le conteneur
    sudo lxc-wait -n $LXC_NAME -s 'RUNNING' -t 60	# Attend pendant 60s maximum que le conteneur démarre
}

CHECK_CONTAINER () {
	echo "Test de démarrage du conteneur $LXC_NAME"
	sudo lxc-start -n $LXC_NAME -d > /dev/null 2>&1	# Démarre le conteneur
	sudo lxc-wait -n $LXC_NAME -s 'RUNNING' -t 60	# Attend pendant 60s maximum que le conteneur démarre
# 	sudo lxc-ls -f
	if [ $(sudo lxc-info --name $LXC_NAME | grep -c "RUNNING") -ne 1 ]; then
		check_repair=1
		return 1	# Renvoi 1 si le démarrage du conteneur a échoué
	else
		return 0	# Renvoi 0 si le démarrage du conteneur a réussi
	fi
}

RESTORE_SNAPSHOT () {
	echo -e "\e[91mRestauration du snapshot du conteneur $LXC_NAME.\e[0m"
	check_repair=1
	sudo lxc-snapshot -r snap0 -n $LXC_NAME
	CHECK_CONTAINER
	STATUS=$?
	if [ "$STATUS" -eq 1 ]; then
		echo -e "\e[91m> Conteneur $LXC_NAME en défaut.\e[0m"
                STOP_CONTAINER
		return 1
	else
		echo -e "\e[92m> Conteneur $LXC_NAME en état de marche.\e[0m"
		return 0
	fi
}

RESTORE_ARCHIVE_SNAPSHOT () {
	if ! test -e "/var/lib/lxcsnaps/$LXC_NAME/snap1.tar.gz"; then
		echo -e "\e[91mAucune archive de snapshot pour le conteneur $LXC_NAME.\e[0m"
		return 1
	fi
	echo -e "\e[91mRestauration du snapshot archivé pour le conteneur $LXC_NAME.\e[0m"
	check_repair=1
	echo -e "\e[91mSuppression du snapshot.\e[0m"
	sudo lxc-snapshot -n $LXC_NAME -d snap0
	echo -e "\e[91mDécompression de l'archive.\e[0m"
 	sudo tar -x --acls --xattrs -f /var/lib/lxcsnaps/$LXC_NAME/snap0.tar.gz -C /
	RESTORE_SNAPSHOT
	return $?
}

RESTORE_CONTAINER () {
    # Tente des restaurations du conteneur
    # Restauration des snapshots
    STOP_CONTAINER
    if [ $START_STATUS -eq 1 ]; then
            RESTORE_SNAPSHOT
            START_STATUS=$?
    fi
    # Restauration des archives des snapshots
    if [ $START_STATUS -eq 1 ]; then
            RESTORE_ARCHIVE_SNAPSHOT
            START_STATUS=$?
    fi
    # Résultats finaux
    if [ $START_STATUS -eq 1 ]; then
        echo -e "\e[91m\n> Le conteneur $LXC_NAME1 n'a pas pu être réparé...\nIl est nécessaire de détruire et de reconstruire le conteneur.\e[0m"
		sudo rm "$script_dir/../pcheck.lock" # Retire le lock
        exit 1
    else
        echo -e "\e[92m\n> Le conteneur démarre correctement.\e[0m"
    fi
}

LXC_NETWORK_CONFIG () {
    lxc_network=0
    if ! sudo cat /var/lib/lxc/$LXC_NAME/config | grep -q "^lxc.network.type = veth"; then
	lxc_network=1   # Si la ligne de la config réseau est absente, c'est une erreur.
	check_repair=1
	if sudo cat /var/lib/lxc/$LXC_NAME/config | grep -q ".*lxc.network.type"; then # Si la ligne est incorrecte, elle est corrigée.
	    sudo sed -i "s/.*lxc.network.type.*/lxc.network.type = veth/g" /var/lib/lxc/$LXC_NAME/config
	else    # Sinon elle est ajoutée.
	    echo "lxc.network.type = veth" | sudo tee -a /var/lib/lxc/$LXC_NAME/config
	fi
    fi
    if ! sudo cat /var/lib/lxc/$LXC_NAME/config | grep -q "^lxc.network.flags = up"; then
	lxc_network=1
	check_repair=1
	if sudo cat /var/lib/lxc/$LXC_NAME/config | grep -q ".*lxc.network.flags"; then
	    sudo sed -i "s/.*lxc.network.flags.*/lxc.network.flags = up/g" /var/lib/lxc/$LXC_NAME/config
	else
	    echo "lxc.network.flags = up" | sudo tee -a /var/lib/lxc/$LXC_NAME/config
	fi
    fi
    if ! sudo cat /var/lib/lxc/$LXC_NAME/config | grep -q "^lxc.network.link = $LXC_BRIDGE"; then
	lxc_network=1
	check_repair=1
	if sudo cat /var/lib/lxc/$LXC_NAME/config | grep -q ".*lxc.network.link"; then
	    sudo sed -i "s/.*lxc.network.link.*/lxc.network.link = $LXC_BRIDGE" /var/lib/lxc/$LXC_NAME/config
	else
	    echo "lxc.network.link = $LXC_BRIDGE" | sudo tee -a /var/lib/lxc/$LXC_NAME/config
	fi
    fi
    if ! sudo cat /var/lib/lxc/$LXC_NAME/config | grep -q "^lxc.network.name = eth0"; then
	lxc_network=1
	check_repair=1
	if sudo cat /var/lib/lxc/$LXC_NAME/config | grep -q ".*lxc.network.name"; then
	    sudo sed -i "s/.*lxc.network.name.*/lxc.network.name = eth0/g" /var/lib/lxc/$LXC_NAME/config
	else
	    echo "lxc.network.name = eth0" | sudo tee -a /var/lib/lxc/$LXC_NAME/config
	fi
    fi
    if ! sudo cat /var/lib/lxc/$LXC_NAME/config | grep -q "^lxc.network.veth.pair = $LXC_NAME"; then
	lxc_network=1
	check_repair=1
	if sudo cat /var/lib/lxc/$LXC_NAME/config | grep -q ".*lxc.network.veth.pair"; then
	    sudo sed -i "s/.*lxc.network.veth.pair.*/lxc.network.veth.pair = $LXC_NAME/g" /var/lib/lxc/$LXC_NAME/config
	else
	    echo "lxc.network.veth.pair = $LXC_NAME" | sudo tee -a /var/lib/lxc/$LXC_NAME/config
	fi
    fi
    if ! sudo cat /var/lib/lxc/$LXC_NAME/config | grep -q "^lxc.network.hwaddr = 00:FF:AA:00:00:01"; then
	lxc_network=1
	check_repair=1
	if sudo cat /var/lib/lxc/$LXC_NAME/config | grep -q ".*lxc.network.hwaddr"; then
	    sudo sed -i "s/.*lxc.network.hwaddr.*/lxc.network.hwaddr = 00:FF:AA:00:00:01/g" /var/lib/lxc/$LXC_NAME/config
	else
	    echo "lxc.network.hwaddr = 00:FF:AA:00:00:01" | sudo tee -a /var/lib/lxc/$LXC_NAME/config
	fi
    fi
    if [ $lxc_network -eq 1 ]; then
	echo -e "\e[91mLa configuration réseau LXC du conteneur est incorrecte et a été corrigée.\e[0m"
    else
	echo -e "\e[92mLa configuration réseau LXC du conteneur est correcte.\e[0m"
    fi
}

touch "$script_dir/../pcheck.lock" # Met en place le lock de Package check

STOP_CONTAINER
STOP_NETWORK
check_repair=0

### Test de la configuration réseau
echo -e "\e[1m> Test de la configuration réseau du côté de l'hôte:\e[0m"
CREATE_BRIDGE () {
    echo | sudo tee /etc/network/interfaces.d/$LXC_BRIDGE <<EOF
    auto $LXC_BRIDGE
    iface $LXC_BRIDGE inet static
            address $PLAGE_IP.1/24
            bridge_ports none
            bridge_fd 0
            bridge_maxwait 0
EOF
}
# Test la présence du fichier de config du bridge lxc-pchecher
if ! test -e /etc/network/interfaces.d/$LXC_BRIDGE
then
    echo -e "\e[91mLe fichier de configuration du bridge est introuvable.\nIl va être recréé.\e[0m"
	check_repair=1
    CREATE_BRIDGE
else
    echo -e "\e[92mLe fichier de config du bridge est présent.\e[0m"
fi
# Test le démarrage du bridge
bridge=0
while test "$bridge" -ne 1
do
    sudo ifup $LXC_BRIDGE --interfaces=/etc/network/interfaces.d/$LXC_BRIDGE
    if sudo ifconfig | grep -q $LXC_BRIDGE
    then
        echo -e "\e[92mLe bridge démarre correctement.\e[0m"
        # Vérifie que le bridge obtient une adresse IP
        if LC_ALL=C sudo ifconfig | grep -A 10 $LXC_BRIDGE | grep "inet addr" | grep -q -F "$PLAGE_IP.1 "
        then
            echo -e "\e[92mLe bridge obtient correctement son adresse IP.\e[0m"
        else
            if [ "$bridge" -ne -1 ]; then
                echo -e "\e[91mLe bridge n'obtient pas la bonne adresse IP. Tentative de réparation...\e[0m"
				check_repair=1
                CREATE_BRIDGE
                sudo ifdown --force $LXC_BRIDGE
                bridge=-1   # Bridge à -1 pour indiquer que cette erreur s'est déjà présentée.
                continue    # Retourne au début de la boucle pour réessayer
            else
                sudo ifconfig
                echo -e "\e[91mLe bridge n'obtient pas la bonne adresse IP après réparation. Tenter une réinstallation complète de Package_checker...\e[0m"
				sudo rm "$script_dir/../pcheck.lock" # Retire le lock
                exit 1
            fi
        fi
    else
        if [ "$bridge" -ne -2 ]; then
            echo -e "\e[91mLe bridge ne démarre pas. Tentative de réparation...\e[0m"
			check_repair=1
            CREATE_BRIDGE
            sudo ifdown --force $LXC_BRIDGE
            bridge=-2   # Bridge à -1 pour indiquer que cette erreur s'est déjà présentée.
            continue    # Retourne au début de la boucle pour réessayer
        else
            sudo ifconfig
            echo -e "\e[91mLe bridge ne démarre pas après réparation. Tenter une réinstallation complète de Package_checker...\e[0m"
			sudo rm "$script_dir/../pcheck.lock" # Retire le lock
            exit 1
        fi
    fi
	bridge=1
done

# Test l'application des règles iptables
sudo iptables -A FORWARD -i $LXC_BRIDGE -o $main_iface -j ACCEPT
sudo iptables -A FORWARD -i $main_iface -o $LXC_BRIDGE -j ACCEPT
sudo iptables -t nat -A POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE

if sudo iptables -C FORWARD -i $LXC_BRIDGE -o $main_iface -j ACCEPT && sudo iptables -C FORWARD -i $main_iface -o $LXC_BRIDGE -j ACCEPT && sudo iptables -t nat -C POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE
then
    echo -e "\e[92mLes règles iptables sont appliquées correctement.\e[0m"
else
    echo -e "\e[91mLes règles iptables ne sont pas appliquées correctement, vérifier la configuration du système...\e[0m"
	sudo rm "$script_dir/../pcheck.lock" # Retire le lock
    exit 1
fi

# Arrête le réseau du conteneur
STOP_NETWORK


### Test du démarrage du conteneur.
echo -e "\e[1m\n> Test le démarrage du conteneur:\e[0m"
START_NETWORK
LXC_NETWORK_CONFIG
CHECK_CONTAINER
START_STATUS=$?
if [ "$START_STATUS" -eq 1 ]; then
    RESTORE_CONTAINER
else
    echo -e "\e[92mLe conteneur a démarré correctement.\e[0m"
fi


# Vérifie la connexion internet.
echo -e "\e[1m\n> Test de l'accès internet depuis l'hôte:\e[0m"
ping -q -c 2 yunohost.org > /dev/null 2>&1
if [ "$?" -ne 0 ]; then	# En cas d'échec de connexion, tente de pinger un autre domaine pour être sûr
    ping -q -c 2 framasoft.org > /dev/null 2>&1
    if [ "$?" -ne 0 ]; then	# En cas de nouvel échec de connexion. On considère que la connexion est down...
        echo -e "\e[91mL'hôte semble ne pas avoir accès à internet. La connexion internet est indispensable.\e[0m"
		sudo rm "$script_dir/../pcheck.lock" # Retire le lock
        exit 1
    fi
fi
echo -e "\e[92mL'hôte dispose d'un accès à internet.\e[0m"

### Test le réseau du conteneur
echo -e "\e[1m\n> Test de l'accès internet depuis le conteneur:\e[0m"
CHECK_LXC_NET () {
    sudo lxc-attach -n $LXC_NAME -- ping -q -c 2 yunohost.org > /dev/null 2>&1
    if [ "$?" -ne 0 ]; then	# En cas d'échec de connexion, tente de pinger un autre domaine pour être sûr
        sudo lxc-attach -n $LXC_NAME -- ping -q -c 2 framasoft.org > /dev/null 2>&1
        if [ "$?" -ne 0 ]; then	# En cas de nouvel échec de connexion. On considère que la connexion est down...
            return 1
        fi
    fi
    return 0
}
lxc_net=1
lxc_net_check=0 # Passe sur les différents tests
while test "$lxc_net" -eq 1   # Boucle tant que la connexion internet du conteneur n'est pas réparée.
do
    REBOOT_CONTENEUR
	sleep 3
    sudo lxc-ls -f
	CHECK_LXC_NET
	lxc_net=$?
    if [ "$lxc_net" -eq 1 ]; then
        if [ "$lxc_net_check" -eq 4 ]
        then
			echo -e "\e[91mImpossible de rétablir la connexion internet du conteneur.\e[0m"
			sudo rm "$script_dir/../pcheck.lock" # Retire le lock
			exit 1
		fi
        echo -e "\e[91mLe conteneur LXC n'accède pas à internet...\e[0m"
		check_repair=1
        if [ "$lxc_net_check" -eq 0 ]
        then
            # Test la présence du fichier de config du kernel
            lxc_net_check=1
            if ! test -e /etc/sysctl.d/lxc_pchecker.conf
            then
                echo -e "\e[91mLe fichier de configuration du kernel pour l'ip forwarding est introuvable.\nIl va être recréé.\e[0m"
                echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/lxc_pchecker.conf
                sudo sysctl -p /etc/sysctl.d/lxc_pchecker.conf
                continue
            else
                echo -e "\e[92mLe fichier de configuration du kernel pour l'ip forwarding est présent.\e[0m"
            fi
        fi
        if [ "$lxc_net_check" -eq 1 ]
        then
            # Test l'ip forwarding
            lxc_net_check=2
            if ! sudo sysctl -a | grep -q "net.ipv4.ip_forward = " || [ $(sudo sysctl -n net.ipv4.ip_forward) -ne 1 ]
            then
                echo -e "\e[91mL'ip forwarding n'est pas activé. Correction en cours...\e[0m"
                echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/lxc_pchecker.conf
                sudo sysctl -p /etc/sysctl.d/lxc_pchecker.conf
                continue
            else
                echo -e "\e[92mL'ip forwarding est activé.\e[0m"
            fi
        fi
        if [ "$lxc_net_check" -eq 2 ]
        then
            # Vérifie la config réseau LXC du conteneur
            lxc_net_check=3
	    LXC_NETWORK_CONFIG
        fi
        if [ "$lxc_net_check" -eq 3 ]
        then
            lxc_net_check=4
            # Vérifie la config réseau LXC à l'intérieur du conteneur
            if ! sudo test -e /var/lib/lxc/$LXC_NAME/rootfs/etc/network/interfaces
            then
                echo -e "\e[91mLe fichier network/interfaces du conteneur est introuvable.\nIl va être recréé.\e[0m"
            else
                echo -e "\e[92mLe fichier network/interfaces du conteneur est présent.\nMais il va être réécrit par précaution.\e[0m"
            fi
            echo -e "auto lo\niface lo inet loopback\nauto eth0\niface eth0 inet static\n\taddress $PLAGE_IP.2/24\n\tgateway $PLAGE_IP.1" | sudo tee /var/lib/lxc/$LXC_NAME/rootfs/etc/network/interfaces
        fi
    else
        echo -e "\e[92mLe conteneur dispose d'un accès à internet.\e[0m"
    fi
done


### Test l'accès ssh sur le conteneur
echo -e "\e[1m\n> Test de l'accès ssh:\e[0m"
# Check user
if [ "$(whoami)" != "$(cat "$script_dir/setup_user")" ] && test -e "$script_dir/setup_user"; then
	echo -e "\e[91mPour tester l'accès ssh, le script doit être exécuté avec l'utilisateur $(cat "$script_dir/setup_user") !\nL'utilisateur actuel est $(whoami).\e[0m"
	sudo rm "$script_dir/../pcheck.lock" # Retire le lock
	exit 1
fi

sudo lxc-ls -f
sleep 3
ssh $ARG_SSH $LXC_NAME "exit 0"	# Test une connexion ssh
if [ "$?" -eq 0 ]; then
    echo -e "\e[92mLa connexion ssh est fonctionnelle.\e[0m"
else
    echo -e "\e[91mÉchec de la connexion ssh. Reconfiguration de l'accès ssh.\e[0m"
	check_repair=1
	ssh $ARG_SSH $LXC_NAME -v "exit 0"	# Répète la connexion ssh pour afficher l'erreur.

    echo "Suppression de la config ssh actuelle pour le conteneur."
    rm -f $HOME/.ssh/$LXC_NAME $HOME/.ssh/$LXC_NAME.pub

    BEGIN_LINE=$(cat $HOME/.ssh/config | grep -n "# ssh $LXC_NAME" | cut -d':' -f 1)
    sed -i "$BEGIN_LINE,/^IdentityFile/d" $HOME/.ssh/config

    ssh-keygen -f "$HOME/.ssh/known_hosts" -R $PLAGE_IP.2

    echo "Création de la clé ssh."
    ssh-keygen -t dsa -f $HOME/.ssh/$LXC_NAME -P ''
    sudo cp $HOME/.ssh/$LXC_NAME.pub /var/lib/lxc/$LXC_NAME/rootfs/home/pchecker/.ssh/authorized_keys
    sudo lxc-attach -n $LXC_NAME -- chown pchecker: -R /home/pchecker/.ssh
    echo "Ajout de la config ssh."

    echo | tee -a $HOME/.ssh/config <<EOF
    # ssh $LXC_NAME
    Host $LXC_NAME
    Hostname $PLAGE_IP.2
    User pchecker
    IdentityFile $HOME/.ssh/$LXC_NAME
EOF
    ssh-keyscan -H 10.1.4.2 >> ~/.ssh/known_hosts	# Récupère la clé publique pour l'ajouter au known_hosts
    ssh $ARG_SSH $LXC_NAME -v "exit 0" > /dev/null	# Test à nouveau la connexion ssh
    if [ "$?" -eq 0 ]; then
        echo -e "\e[92mLa connexion ssh est retablie.\e[0m"
    else
        echo -e "\e[91mÉchec de la réparation de la connexion ssh.\nIl est nécessaire de détruire et de reconstruire le conteneur.\e[0m"
    fi
fi


### Vérifie que Yunohost est installé
echo -e "\e[1m\n> Vérifie que Yunohost est installé dans le conteneur:\e[0m"
sudo lxc-attach -n $LXC_NAME -- sudo yunohost -v
if [ "$?" -ne 0 ]; then	# Si la commande échoue, il y a un problème avec Yunohost
	echo -e "\e[91mYunohost semble mal installé. Il est nécessaire de détruire et de reconstruire le conteneur.\e[0m"
	sudo rm "$script_dir/../pcheck.lock" # Retire le lock
	exit 1
else
	echo -e "\e[92mYunohost est installé correctement.\e[0m"

fi

STOP_CONTAINER
STOP_NETWORK

echo -e "\e[92m\nLe conteneur ne présente aucune erreur.\e[0m"
if [ "$check_repair" -eq 1 ]; then
	echo -e "\e[91mMais des réparations ont été nécessaires. Refaire un test pour s'assurer que tout est correct...\e[0m"
fi

sudo rm "$script_dir/../pcheck.lock" # Retire le lock
