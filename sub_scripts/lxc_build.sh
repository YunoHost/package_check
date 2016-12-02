#!/bin/bash

# Récupère le dossier du script
if [ "${0:0:1}" == "/" ]; then script_dir="$(dirname "$0")"; else script_dir="$(echo $PWD/$(dirname "$0" | cut -d '.' -f2) | sed 's@/$@@')"; fi

LOG_BUILD_LXC="$script_dir/Build_lxc.log"
PLAGE_IP="10.1.4"
ARG_SSH="-t"
DOMAIN=domain.tld
YUNO_PWD=admin
LXC_NAME=pchecker_lxc

# Check user
echo $(whoami) > "$script_dir/setup_user"

echo "> Update et install lxc lxctl" | tee "$LOG_BUILD_LXC"
sudo apt-get update >> "$LOG_BUILD_LXC" 2>&1
sudo apt-get install -y lxc lxctl >> "$LOG_BUILD_LXC" 2>&1

echo "> Création d'une machine debian jessie minimaliste" | tee -a "$LOG_BUILD_LXC"
sudo lxc-create -n $LXC_NAME -t debian -- -r jessie >> "$LOG_BUILD_LXC" 2>&1

echo "> Autoriser l'ip forwarding, pour router vers la machine virtuelle." | tee -a "$LOG_BUILD_LXC"
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/lxc_pchecker.conf >> "$LOG_BUILD_LXC" 2>&1
sudo sysctl -p /etc/sysctl.d/lxc_pchecker.conf >> "$LOG_BUILD_LXC" 2>&1

echo "> Ajoute un brige réseau pour la machine virtualisée" | tee -a "$LOG_BUILD_LXC"
echo | sudo tee /etc/network/interfaces.d/lxc-pchecker <<EOF >> "$LOG_BUILD_LXC" 2>&1
auto lxc-pchecker
iface lxc-pchecker inet static
        address $PLAGE_IP.1/24
        bridge_ports none
        bridge_fd 0
        bridge_maxwait 0
EOF

echo "> Active le bridge réseau" | tee -a "$LOG_BUILD_LXC"
sudo ifup lxc-pchecker --interfaces=/etc/network/interfaces.d/lxc-pchecker >> "$LOG_BUILD_LXC" 2>&1

echo "> Configuration réseau du conteneur" | tee -a "$LOG_BUILD_LXC"
sudo sed -i 's/^lxc.network.type = empty$/lxc.network.type = veth\nlxc.network.flags = up\nlxc.network.link = lxc-pchecker\nlxc.network.name = eth0\nlxc.network.veth.pair = $LXC_NAME\nlxc.network.hwaddr = 00:FF:AA:00:00:01/' /var/lib/lxc/$LXC_NAME/config >> "$LOG_BUILD_LXC" 2>&1

echo "> Configuration réseau de la machine virtualisée" | tee -a "$LOG_BUILD_LXC"
sudo sed -i "s@iface eth0 inet dhcp@iface eth0 inet static\n\taddress $PLAGE_IP.2/24\n\tgateway $PLAGE_IP.1@" /var/lib/lxc/$LXC_NAME/rootfs/etc/network/interfaces >> "$LOG_BUILD_LXC" 2>&1

echo "> Configure le parefeu" | tee -a "$LOG_BUILD_LXC"
sudo iptables -A FORWARD -i lxc-pchecker -o eth0 -j ACCEPT >> "$LOG_BUILD_LXC" 2>&1
sudo iptables -A FORWARD -i eth0 -o lxc-pchecker -j ACCEPT >> "$LOG_BUILD_LXC" 2>&1
sudo iptables -t nat -A POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE >> "$LOG_BUILD_LXC" 2>&1

echo "> Démarrage de la machine" | tee -a "$LOG_BUILD_LXC"
sudo lxc-start -n $LXC_NAME -d >> "$LOG_BUILD_LXC" 2>&1
sleep 3
sudo lxc-ls -f >> "$LOG_BUILD_LXC" 2>&1

echo "> Update et install tasksel sudo git" | tee -a "$LOG_BUILD_LXC"
sudo lxc-attach -n $LXC_NAME -- apt-get update
sudo lxc-attach -n $LXC_NAME -- apt-get install -y tasksel sudo git
echo "> Installation des paquets standard et ssh-server" | tee -a "$LOG_BUILD_LXC"
tasksell_exit=1
while [ "$tasksell_exit" -ne 0 ]
do
	sudo lxc-attach -n $LXC_NAME -- tasksel install standard ssh-server
	tasksell_exit=$?
done
echo "> Renseigne /etc/hosts sur l'invité" | tee -a "$LOG_BUILD_LXC"
echo "127.0.0.1 $LXC_NAME" | sudo tee -a /var/lib/lxc/$LXC_NAME/rootfs/etc/hosts >> "$LOG_BUILD_LXC" 2>&1

echo "> Ajoute l'user pchecker" | tee -a "$LOG_BUILD_LXC"
sudo lxc-attach -n $LXC_NAME -- useradd -m -p pchecker pchecker >> "$LOG_BUILD_LXC" 2>&1

echo "> Autorise pchecker à utiliser sudo sans mot de passe" | tee -a "$LOG_BUILD_LXC"
echo "pchecker    ALL=(ALL:ALL) NOPASSWD: ALL" | sudo tee -a /var/lib/lxc/$LXC_NAME/rootfs/etc/sudoers >> "$LOG_BUILD_LXC" 2>&1

echo "> Mise en place de la connexion ssh vers l'invité." | tee -a "$LOG_BUILD_LXC"
if [ -e $HOME/.ssh/$LXC_NAME ]; then
	rm -f $HOME/.ssh/$LXC_NAME $HOME/.ssh/$LXC_NAME.pub
	ssh-keygen -f $HOME/.ssh/known_hosts -R $PLAGE_IP.2
fi
ssh-keygen -t dsa -f $HOME/.ssh/$LXC_NAME -P '' >> "$LOG_BUILD_LXC" 2>&1
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

ssh $ARG_SSH $LXC_NAME "git clone https://github.com/YunoHost/install_script /tmp/install_script" >> "$LOG_BUILD_LXC" 2>&1
echo "> Installation de Yunohost..." | tee -a "$LOG_BUILD_LXC"
ssh $ARG_SSH $LXC_NAME "cd /tmp/install_script; sudo ./install_yunohost -a" | tee -a "$LOG_BUILD_LXC" 2>&1
echo "> Post install Yunohost" | tee -a "$LOG_BUILD_LXC"
ssh $ARG_SSH $LXC_NAME "sudo yunohost tools postinstall --domain $DOMAIN --password $YUNO_PWD" | tee -a "$LOG_BUILD_LXC" 2>&1

USER_TEST=$(cat "$(dirname "$script_dir")/package_check.sh" | grep USER_TEST= | cut -d '=' -f2)
PASSWORD_TEST=$(cat "$(dirname "$script_dir")/package_check.sh" | grep PASSWORD_TEST= | cut -d '=' -f2)
SOUS_DOMAIN="sous.$DOMAIN"
# echo "Le mot de passe Yunohost est \'$YUNO_PWD\'"
echo "> Ajout du sous domaine de test" | tee -a "$LOG_BUILD_LXC"
ssh $ARG_SSH $LXC_NAME "sudo yunohost domain add \"$SOUS_DOMAIN\" --admin-password=\"$YUNO_PWD\""
USER_TEST_CLEAN=${USER_TEST//"_"/""}
echo "> Ajout de l'utilisateur de test" | tee -a "$LOG_BUILD_LXC"
ssh $ARG_SSH $LXC_NAME "sudo yunohost user create --firstname \"$USER_TEST_CLEAN\" --mail \"$USER_TEST_CLEAN@$DOMAIN\" --lastname \"$USER_TEST_CLEAN\" --password \"$PASSWORD_TEST\" \"$USER_TEST\" --admin-password=\"$YUNO_PWD\""

echo -e "\n> Vérification de l'état de Yunohost" | tee -a "$LOG_BUILD_LXC"
ssh $ARG_SSH $LXC_NAME "sudo yunohost -v" | tee -a "$LOG_BUILD_LXC" 2>&1


echo "> Arrêt de la machine virtualisée" | tee -a "$LOG_BUILD_LXC"
sudo lxc-stop -n $LXC_NAME >> "$LOG_BUILD_LXC" 2>&1

echo "> Suppression des règles de parefeu" | tee -a "$LOG_BUILD_LXC"
sudo iptables -D FORWARD -i lxc-pchecker -o eth0 -j ACCEPT >> "$LOG_BUILD_LXC" 2>&1
sudo iptables -D FORWARD -i eth0 -o lxc-pchecker -j ACCEPT >> "$LOG_BUILD_LXC" 2>&1
sudo iptables -t nat -D POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE >> "$LOG_BUILD_LXC" 2>&1
sudo ifdown --force lxc-pchecker >> "$LOG_BUILD_LXC" 2>&1

echo "> Création d'un snapshot" | tee -a "$LOG_BUILD_LXC"
sudo lxc-snapshot -n $LXC_NAME >> "$LOG_BUILD_LXC" 2>&1
# Il sera nommé snap0 et stocké dans /var/lib/lxcsnaps/$LXC_NAME/snap0/
