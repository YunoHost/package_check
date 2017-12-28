#!/bin/bash

# Récupère le dossier du script
if [ "${0:0:1}" == "/" ]; then script_dir="$(dirname "$0")"; else script_dir="$(echo $PWD/$(dirname "$0" | cut -d '.' -f2) | sed 's@/$@@')"; fi

pcheck_config="$script_dir/../config"
# Tente de lire les informations depuis le fichier de config si il existe
if [ -e "$pcheck_config" ]
then
	PLAGE_IP=$(cat "$pcheck_config" | grep PLAGE_IP= | cut -d '=' -f2)
	DOMAIN=$(cat "$pcheck_config" | grep DOMAIN= | cut -d '=' -f2)
	YUNO_PWD=$(cat "$pcheck_config" | grep YUNO_PWD= | cut -d '=' -f2)
	LXC_NAME=$(cat "$pcheck_config" | grep LXC_NAME= | cut -d '=' -f2)
	LXC_BRIDGE=$(cat "$pcheck_config" | grep LXC_BRIDGE= | cut -d '=' -f2)
	dns=$(cat "$pcheck_config" | grep dns= | cut -d '=' -f2)
	dnsforce=$(cat "$pcheck_config" | grep dnsforce= | cut -d '=' -f2)
	main_iface=$(cat "$pcheck_config" | grep iface= | cut -d '=' -f2)
	DISTRIB=$(cat "$pcheck_config" | grep DISTRIB= | cut -d '=' -f2)
fi

LOG_BUILD_LXC="$script_dir/Build_lxc.log"
# Utilise des valeurs par défaut si les variables sont vides.
test -n "$PLAGE_IP" || PLAGE_IP=10.1.4
test -n "$DOMAIN" || DOMAIN=domain.tld
test -n "$YUNO_PWD" || YUNO_PWD=admin
test -n "$LXC_NAME" || LXC_NAME=pchecker_lxc
test -n "$LXC_BRIDGE" || LXC_BRIDGE=lxc-pchecker
test -n "$dnsforce" || dnsforce=1
test -n "$DISTRIB" || DISTRIB=jessie
ARG_SSH="-t"

# Tente de définir l'interface réseau principale
if [ -z $main_iface ]	# Si main_iface est vide, tente de le trouver.
then
# 	main_iface=$(sudo route | grep default.*0.0.0.0 -m1 | awk '{print $8;}')	# Prend l'interface réseau défini par default
	main_iface=$(sudo ip route | grep default | awk '{print $5;}')	# Prend l'interface réseau défini par default
	if [ -z $main_iface ]; then
		echo -e "\e[91mImpossible de déterminer le nom de l'interface réseau de l'hôte.\e[0m"
		exit 1
	fi
fi

if [ -z $dns ]	# Si l'adresse du dns est vide, tente de le déterminer à partir de la passerelle par défaut.
then
# 	dns=$(sudo route -n | grep ^0.0.0.0.*$main_iface | awk '{print $2;}')
	dns=$(sudo ip route | grep default | awk '{print $3;}')
	if [ -z $dns ]; then
		echo -e "\e[91mImpossible de déterminer l'adresse de la passerelle.\e[0m"
		exit 1
	fi
fi

touch "$script_dir/../pcheck.lock" # Met en place le lock de Package check, le temps de l'installation

# Check user
echo $(whoami) > "$script_dir/setup_user"

# Enregistre le nom de l'interface réseau de l'hôte dans un fichier de config
echo -e "# Interface réseau principale de l'hôte\niface=$main_iface\n" > "$pcheck_config"
echo -e "# Adresse du dns\ndns=$dns\n" >> "$pcheck_config"
echo -e "# Forçage du dns\ndnsforce=$dnsforce\n" >> "$pcheck_config"
# Enregistre les infos dans le fichier de config.
echo -e "# Plage IP du conteneur\nPLAGE_IP=$PLAGE_IP\n" >> "$pcheck_config"
echo -e "# Domaine de test\nDOMAIN=$DOMAIN\n" >> "$pcheck_config"
echo -e "# Mot de passe\nYUNO_PWD=$YUNO_PWD\n" >> "$pcheck_config"
echo -e "# Nom du conteneur\nLXC_NAME=$LXC_NAME\n" >> "$pcheck_config"
echo -e "# Nom du bridge\nLXC_BRIDGE=$LXC_BRIDGE\n" >> "$pcheck_config"
echo -e "# Distribution debian\nDISTRIB=$DISTRIB\n" >> "$pcheck_config"

echo -e "\e[1m> Update et install lxc lxctl\e[0m" | tee "$LOG_BUILD_LXC"
sudo apt-get update >> "$LOG_BUILD_LXC" 2>&1
sudo apt-get install -y lxc lxctl >> "$LOG_BUILD_LXC" 2>&1

echo -e "\e[1m> Install git, curl and lynx\e[0m" | tee "$LOG_BUILD_LXC"
sudo apt-get install -y git curl lynx >> "$LOG_BUILD_LXC" 2>&1

sudo mkdir -p /var/lib/lxcsnaps	# Créer le dossier lxcsnaps, pour s'assurer que lxc utilisera ce dossier, même avec lxc 2.

if sudo lxc-info -n $LXC_NAME > /dev/null 2>&1
then	# Si le conteneur existe déjà
	echo -e "\e[1m> Suppression du conteneur existant.\e[0m" | tee -a "$LOG_BUILD_LXC"
	sudo lxc-snapshot -n $LXC_NAME -d snap0 | tee -a "$LOG_BUILD_LXC"
	sudo lxc-snapshot -n $LXC_NAME -d snap1 | tee -a "$LOG_BUILD_LXC"
	sudo lxc-snapshot -n $LXC_NAME -d snap2 | tee -a "$LOG_BUILD_LXC"
	sudo rm -f /var/lib/lxcsnaps/$LXC_NAME/snap0.tar.gz | tee -a "$LOG_BUILD_LXC"
	sudo lxc-destroy -n $LXC_NAME -f | tee -a "$LOG_BUILD_LXC"
fi

echo -e "\e[1m> Création d'une machine debian $DISTRIB minimaliste.\e[0m" | tee -a "$LOG_BUILD_LXC"
sudo lxc-create -n $LXC_NAME -t debian -- -r $DISTRIB >> "$LOG_BUILD_LXC" 2>&1

echo -e "\e[1m> Autoriser l'ip forwarding, pour router vers la machine virtuelle.\e[0m" | tee -a "$LOG_BUILD_LXC"
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/lxc_pchecker.conf >> "$LOG_BUILD_LXC" 2>&1
sudo sysctl -p /etc/sysctl.d/lxc_pchecker.conf >> "$LOG_BUILD_LXC" 2>&1

echo -e "\e[1m> Ajoute un brige réseau pour la machine virtualisée\e[0m" | tee -a "$LOG_BUILD_LXC"
echo | sudo tee /etc/network/interfaces.d/$LXC_BRIDGE <<EOF >> "$LOG_BUILD_LXC" 2>&1
auto $LXC_BRIDGE
iface $LXC_BRIDGE inet static
        address $PLAGE_IP.1/24
        bridge_ports none
        bridge_fd 0
        bridge_maxwait 0
EOF

echo -e "\e[1m> Active le bridge réseau\e[0m" | tee -a "$LOG_BUILD_LXC"
sudo ifup $LXC_BRIDGE --interfaces=/etc/network/interfaces.d/$LXC_BRIDGE >> "$LOG_BUILD_LXC" 2>&1

echo -e "\e[1m> Configuration réseau du conteneur\e[0m" | tee -a "$LOG_BUILD_LXC"
sudo sed -i "s/^lxc.network.type = empty$/lxc.network.type = veth\nlxc.network.flags = up\nlxc.network.link = $LXC_BRIDGE\nlxc.network.name = eth0\nlxc.network.hwaddr = 00:FF:AA:00:00:01/" /var/lib/lxc/$LXC_NAME/config >> "$LOG_BUILD_LXC" 2>&1

echo -e "\e[1m> Configuration réseau de la machine virtualisée\e[0m" | tee -a "$LOG_BUILD_LXC"
sudo sed -i "s@iface eth0 inet dhcp@iface eth0 inet static\n\taddress $PLAGE_IP.2/24\n\tgateway $PLAGE_IP.1@" /var/lib/lxc/$LXC_NAME/rootfs/etc/network/interfaces >> "$LOG_BUILD_LXC" 2>&1

echo -e "\e[1m> Configure le parefeu\e[0m" | tee -a "$LOG_BUILD_LXC"
sudo iptables -A FORWARD -i $LXC_BRIDGE -o $main_iface -j ACCEPT >> "$LOG_BUILD_LXC" 2>&1
sudo iptables -A FORWARD -i $main_iface -o $LXC_BRIDGE -j ACCEPT >> "$LOG_BUILD_LXC" 2>&1
sudo iptables -t nat -A POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE >> "$LOG_BUILD_LXC" 2>&1

echo -e "\e[1m> Vérification du contenu du resolv.conf\e[0m" | tee -a "$LOG_BUILD_LXC"
if ! sudo cat /var/lib/lxc/$LXC_NAME/rootfs/etc/resolv.conf | grep -q nameserver; then
	dnsforce=1	# Le resolv.conf est vide, on force l'ajout d'un dns.
	sed -i "s/dnsforce=.*/dnsforce=$dnsforce/" "$pcheck_config"
fi
if [ $dnsforce -eq 1 ]; then	# Force la réécriture du resolv.conf
	echo "nameserver $dns" | sudo tee /var/lib/lxc/$LXC_NAME/rootfs/etc/resolv.conf
fi

# Fix an issue with apparmor when the container start.
echo -e "\n# Fix apparmor issues\nlxc.aa_profile = unconfined" | sudo tee -a /var/lib/lxc/$LXC_NAME/config >> "$LOG_BUILD_LXC" 2>&1

echo -e "\e[1m> Démarrage de la machine\e[0m" | tee -a "$LOG_BUILD_LXC"
sudo lxc-start -n $LXC_NAME -d --logfile "$script_dir/lxc_boot.log" >> "$LOG_BUILD_LXC" 2>&1
sleep 3
sudo lxc-ls -f >> "$LOG_BUILD_LXC" 2>&1

echo -e "\e[1m> Update et install aptitude sudo git\e[0m" | tee -a "$LOG_BUILD_LXC"
sudo lxc-attach -n $LXC_NAME -- apt-get update
sudo lxc-attach -n $LXC_NAME -- apt-get install -y aptitude sudo git ssh openssh-server
echo -e "\e[1m> Installation des paquets standard et ssh-server\e[0m" | tee -a "$LOG_BUILD_LXC"
sudo lxc-attach -n $LXC_NAME -- aptitude install -y ~pstandard ~prequired ~pimportant

echo -e "\e[1m> Renseigne /etc/hosts sur l'invité\e[0m" | tee -a "$LOG_BUILD_LXC"
echo "127.0.0.1 $LXC_NAME" | sudo tee -a /var/lib/lxc/$LXC_NAME/rootfs/etc/hosts >> "$LOG_BUILD_LXC" 2>&1

echo -e "\e[1m> Ajoute l'user pchecker\e[0m" | tee -a "$LOG_BUILD_LXC"
sudo lxc-attach -n $LXC_NAME -- useradd -m -p pchecker pchecker >> "$LOG_BUILD_LXC" 2>&1

echo -e "\e[1m> Autorise pchecker à utiliser sudo sans mot de passe\e[0m" | tee -a "$LOG_BUILD_LXC"
echo "pchecker    ALL=(ALL:ALL) NOPASSWD: ALL" | sudo tee -a /var/lib/lxc/$LXC_NAME/rootfs/etc/sudoers >> "$LOG_BUILD_LXC" 2>&1

echo -e "\e[1m> Mise en place de la connexion ssh vers l'invité.\e[0m" | tee -a "$LOG_BUILD_LXC"
if [ -e $HOME/.ssh/$LXC_NAME ]; then
	rm -f $HOME/.ssh/$LXC_NAME $HOME/.ssh/$LXC_NAME.pub
	ssh-keygen -f $HOME/.ssh/known_hosts -R $PLAGE_IP.2
fi
ssh-keygen -t rsa -f $HOME/.ssh/$LXC_NAME -P '' >> "$LOG_BUILD_LXC" 2>&1
sudo mkdir /var/lib/lxc/$LXC_NAME/rootfs/home/pchecker/.ssh >> "$LOG_BUILD_LXC" 2>&1
sudo cp $HOME/.ssh/$LXC_NAME.pub /var/lib/lxc/$LXC_NAME/rootfs/home/pchecker/.ssh/authorized_keys >> "$LOG_BUILD_LXC" 2>&1
sudo lxc-attach -n $LXC_NAME -- chown pchecker: -R /home/pchecker/.ssh >> "$LOG_BUILD_LXC" 2>&1

echo | tee -a $HOME/.ssh/config <<EOF >> "$LOG_BUILD_LXC" 2>&1
# ssh $LXC_NAME
Host $LXC_NAME
Hostname $PLAGE_IP.2
User pchecker
IdentityFile $HOME/.ssh/$LXC_NAME
EOF

ssh-keyscan -H $PLAGE_IP.2 >> ~/.ssh/known_hosts
ssh $ARG_SSH $LXC_NAME "exit 0"	# Initie une premier connexion SSH pour valider la clé.
if [ "$?" -ne 0 ]; then	# Si l'utilisateur tarde trop, la connexion sera refusée... ???
	ssh $ARG_SSH $LXC_NAME "exit 0"	# Initie une premier connexion SSH pour valider la clé.
fi

if [ "$DISTRIB" == "stretch" ]; then
	branch="--branch stretch"
else
	branch=""
fi
ssh $ARG_SSH $LXC_NAME "git clone https://github.com/YunoHost/install_script $branch /tmp/install_script" >> "$LOG_BUILD_LXC" 2>&1
echo -e "\e[1m> Installation de Yunohost...\e[0m" | tee -a "$LOG_BUILD_LXC"
ssh $ARG_SSH $LXC_NAME "cd /tmp/install_script; sudo ./install_yunohost -a" | tee -a "$LOG_BUILD_LXC" 2>&1
echo -e "\e[1m> Post install Yunohost\e[0m" | tee -a "$LOG_BUILD_LXC"
ssh $ARG_SSH $LXC_NAME "sudo yunohost tools postinstall --domain $DOMAIN --password $YUNO_PWD" | tee -a "$LOG_BUILD_LXC" 2>&1

USER_TEST=$(cat "$(dirname "$script_dir")/package_check.sh" | grep test_user= | cut -d '=' -f2)
SOUS_DOMAIN="sous.$DOMAIN"
# echo "Le mot de passe Yunohost est \'$YUNO_PWD\'"
echo -e "\e[1m> Ajout du sous domaine de test\e[0m" | tee -a "$LOG_BUILD_LXC"
ssh $ARG_SSH $LXC_NAME "sudo yunohost domain add \"$SOUS_DOMAIN\" --admin-password=\"$YUNO_PWD\""
USER_TEST_CLEAN=${USER_TEST//"_"/""}
echo -e "\e[1m> Ajout de l'utilisateur de test\e[0m" | tee -a "$LOG_BUILD_LXC"
ssh $ARG_SSH $LXC_NAME "sudo yunohost user create --firstname \"$USER_TEST_CLEAN\" --mail \"$USER_TEST_CLEAN@$DOMAIN\" --lastname \"$USER_TEST_CLEAN\" --password \"$YUNO_PWD\" \"$USER_TEST\" --admin-password=\"$YUNO_PWD\""

echo -e -e "\e[1m\n> Vérification de l'état de Yunohost\e[0m" | tee -a "$LOG_BUILD_LXC"
ssh $ARG_SSH $LXC_NAME "sudo yunohost -v" | tee -a "$LOG_BUILD_LXC" 2>&1


echo -e "\e[1m> Arrêt de la machine virtualisée\e[0m" | tee -a "$LOG_BUILD_LXC"
sudo lxc-stop -n $LXC_NAME >> "$LOG_BUILD_LXC" 2>&1

echo -e "\e[1m> Suppression des règles de parefeu\e[0m" | tee -a "$LOG_BUILD_LXC"
sudo iptables -D FORWARD -i $LXC_BRIDGE -o $main_iface -j ACCEPT >> "$LOG_BUILD_LXC" 2>&1
sudo iptables -D FORWARD -i $main_iface -o $LXC_BRIDGE -j ACCEPT >> "$LOG_BUILD_LXC" 2>&1
sudo iptables -t nat -D POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE >> "$LOG_BUILD_LXC" 2>&1
sudo ifdown --force $LXC_BRIDGE >> "$LOG_BUILD_LXC" 2>&1

echo -e "\e[1m> Création d'un snapshot\e[0m" | tee -a "$LOG_BUILD_LXC"
sudo lxc-snapshot -n $LXC_NAME >> "$LOG_BUILD_LXC" 2>&1
# Il sera nommé snap0 et stocké dans /var/lib/lxcsnaps/$LXC_NAME/snap0/

sudo rm "$script_dir/../pcheck.lock" # Retire le lock
