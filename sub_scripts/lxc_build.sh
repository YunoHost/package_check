#!/bin/bash

# Check Debian Stretch or Buster
host_codename=$(grep "VERSION_CODENAME" /etc/os-release | cut -d= -f2)
if [ "$host_codename" != "stretch" ] && [ "$host_codename" != "buster" ]
then
    echo "Package_check can only be installed on Debian Stretch or Debian Buster..."
    exit 1
fi

# Load configuration
dnsforce=1

cd $(dirname $(realpath $0) | sed 's@/sub_scripts$@@g')
source "./sub_scripts/common.sh"

LXC_BUILD()
{
    # Met en place le lock de Package check, le temps de l'installation
    touch "$lock_file"
    echo $(whoami) > "./.setup_user"

    log_title "Installing dependencies..."

    DEPENDENCIES="lxc lxctl git curl lynx jq python3-pip debootstrap rsync bridge-utils"
    sudo apt-get update
    sudo apt-get install -y $DEPENDENCIES

    # Créer le dossier lxcsnaps, pour s'assurer que lxc utilisera ce dossier, même avec lxc 2.
    sudo mkdir -p /var/lib/lxcsnaps	

    # Si le conteneur existe déjà
    if sudo lxc-info -n $LXC_NAME > /dev/null 2>&1
    then	
        log_title "Suppression du conteneur existant."
        ./sub_scripts/lxc_remove.sh
    fi

    log_title "Création d'une machine debian $DISTRIB minimaliste."
    sudo lxc-create -n $LXC_NAME -t download -- -d debian -r $DISTRIB -a $(dpkg --print-architecture)

    log_title "Autoriser l'ip forwarding, pour router vers la machine virtuelle."
    echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/lxc_pchecker.conf
    sudo sysctl -p /etc/sysctl.d/lxc_pchecker.conf

    log_title "Ajoute un brige réseau pour la machine virtualisée"
    echo | sudo tee /etc/network/interfaces.d/$LXC_BRIDGE <<EOF
auto $LXC_BRIDGE
iface $LXC_BRIDGE inet static
        address $LXC_NETWORK.1/24
        bridge_ports none
        bridge_fd 0
        bridge_maxwait 0
EOF

    log_title "Active le bridge réseau"
    sudo ifup $LXC_BRIDGE --interfaces=/etc/network/interfaces.d/$LXC_BRIDGE

    log_title "Configuration réseau du conteneur"
    if [ $(lsb_release -sc) != buster ]
    then
        sudo sed -i "s/^lxc.network.type = empty$/lxc.network.type = veth\nlxc.network.flags = up\nlxc.network.link = $LXC_BRIDGE\nlxc.network.name = eth0\nlxc.network.hwaddr = 00:FF:AA:00:00:01/" /var/lib/lxc/$LXC_NAME/config
    else
        echo -e "lxc.net.0.type = veth\nlxc.net.0.flags = up\nlxc.net.0.link = $LXC_BRIDGE\nlxc.net.0.name = eth0\nlxc.net.0.hwaddr = 00:FF:AA:00:00:01" | sudo tee -a /var/lib/lxc/$LXC_NAME/config
    fi

    log_title "Configuration réseau de la machine virtualisée"
    sudo sed -i "s@iface eth0 inet dhcp@iface eth0 inet static\n\taddress $LXC_NETWORK.2/24\n\tgateway $LXC_NETWORK.1@" $LXC_ROOTFS/etc/network/interfaces

    log_title "Configure le parefeu"
    sudo iptables -A FORWARD -i $LXC_BRIDGE -o $MAIN_NETWORK_INTERFACE -j ACCEPT
    sudo iptables -A FORWARD -i $MAIN_NETWORK_INTERFACE -o $LXC_BRIDGE -j ACCEPT
    sudo iptables -t nat -A POSTROUTING -s $LXC_NETWORK.0/24 -j MASQUERADE

    log_title "Vérification du contenu du resolv.conf"
    sudo cp -a $LXC_ROOTFS/etc/resolv.conf $LXC_ROOTFS/etc/resolv.conf.origin
    if ! sudo cat $LXC_ROOTFS/etc/resolv.conf | grep -q nameserver; then
        dnsforce=1	# Le resolv.conf est vide, on force l'ajout d'un dns.
    fi
    if [ $dnsforce -eq 1 ]; then	# Force la réécriture du resolv.conf
        echo "nameserver $DNS_RESOLVER" | sudo tee $LXC_ROOTFS/etc/resolv.conf
    fi

    # Fix an issue with apparmor when the container start.
    if [ $(lsb_release -sc) != buster ]
    then
        echo -e "\n# Fix apparmor issues\nlxc.aa_profile = unconfined" | sudo tee -a /var/lib/lxc/$LXC_NAME/config
    else
        echo -e "\n# Fix apparmor issues\nlxc.apparmor.profile = unconfined" | sudo tee -a /var/lib/lxc/$LXC_NAME/config
    fi

    log_title "Démarrage de la machine"
    sudo lxc-start -n $LXC_NAME -d --logfile "./lxc_boot.log"
    sleep 3
    sudo lxc-ls -f

    log_title "Test la configuration dns"
    broken_dns=0
    while ! RUN_INSIDE_LXC getent hosts debian.org
    do
            log_info "The dns isn't working (Current dns = $(sudo cat $LXC_ROOTFS/etc/resolv.conf | grep nameserver | awk '{print $2}'))"

            if [ $broken_dns -eq 2 ]
            then
                    log_info "The dns is still broken, use FDN dns"
                    echo "nameserver 80.67.169.12" | sudo tee $LXC_ROOTFS/etc/resolv.conf
                    dnsforce=0
                    ((broken_dns++))
            elif [ $dnsforce -eq 0 ]
            then
                    log_info "Force to use the dns from the config file"
                    echo "nameserver $DNS_RESOLVER" | sudo tee $LXC_ROOTFS/etc/resolv.conf
                    new_dns="$DNS_RESOLVER"
                    dnsforce=1
                    ((broken_dns++))
            else
                    log_info "Force to use the default dns"
                    sudo cp -a $LXC_ROOTFS/etc/resolv.conf.origin $LXC_ROOTFS/etc/resolv.conf
                    new_dns="$(sudo cat $LXC_ROOTFS/etc/resolv.conf | grep nameserver | awk '{print $2}')"
                    dnsforce=0
                    ((broken_dns++))
            fi
            log_info "Try to use the dns address $new_dns"

            if [ $broken_dns -eq 3 ]; then
                    # Break the loop if all the possibilities have been tried.
                    break
            fi
    done

    log_title "Update et install aptitude sudo git"
    RUN_INSIDE_LXC apt-get update
    RUN_INSIDE_LXC apt-get install -y sudo git ssh openssh-server

    log_title "Renseigne /etc/hosts sur l'invité"
    echo "127.0.0.1 $LXC_NAME" | sudo tee -a $LXC_ROOTFS/etc/hosts

    log_title "Ajoute l'user pchecker"
    RUN_INSIDE_LXC useradd -m -p pchecker pchecker

    log_title "Autorise pchecker à utiliser sudo sans mot de passe"
    echo "pchecker    ALL=(ALL:ALL) NOPASSWD: ALL" | sudo tee -a $LXC_ROOTFS/etc/sudoers

    log_title "Mise en place de la connexion ssh vers l'invité."
    if [ -e $HOME/.ssh/$LXC_NAME ]; then
        rm -f $HOME/.ssh/$LXC_NAME $HOME/.ssh/$LXC_NAME.pub
        ssh-keygen -f $HOME/.ssh/known_hosts -R $LXC_NETWORK.2
    fi
    ssh-keygen -t rsa -f $HOME/.ssh/$LXC_NAME -P ''
    sudo mkdir $LXC_ROOTFS/home/pchecker/.ssh
    sudo cp $HOME/.ssh/$LXC_NAME.pub $LXC_ROOTFS/home/pchecker/.ssh/authorized_keys
    RUN_INSIDE_LXC chown pchecker: -R /home/pchecker/.ssh

    echo | tee -a $HOME/.ssh/config <<EOF
# ssh $LXC_NAME
Host $LXC_NAME
Hostname $LXC_NETWORK.2
User pchecker
IdentityFile $HOME/.ssh/$LXC_NAME
EOF

    ssh-keyscan -H $LXC_NETWORK.2 >> ~/.ssh/known_hosts
    # Initie une premier connexion SSH pour valider la clé.
    RUN_THROUGH_SSH "exit 0"
    # Si l'utilisateur tarde trop, la connexion sera refusée... ???
    [ "$?" -ne 0 ] && RUN_THROUGH_SSH "exit 0"

    [ -n "$YNH_INSTALL_SCRIPT_BRANCH" ] && YNH_INSTALL_SCRIPT_BRANCH="--branch $YNH_INSTALL_SCRIPT_BRANCH"

    RUN_THROUGH_SSH git clone https://github.com/YunoHost/install_script $YNH_INSTALL_SCRIPT_BRANCH /tmp/install_script
    log_title "Installation de Yunohost..."
    RUN_THROUGH_SSH bash /tmp/install_script/install_yunohost -a
    log_title "Disable apt-daily to prevent it from messing with apt/dpkg lock"
    RUN_THROUGH_SSH systemctl -q stop apt-daily.timer
    RUN_THROUGH_SSH systemctl -q stop apt-daily-upgrade.timer
    RUN_THROUGH_SSH systemctl -q stop apt-daily.service
    RUN_THROUGH_SSH systemctl -q stop apt-daily-upgrade.service 
    RUN_THROUGH_SSH systemctl -q disable apt-daily.timer 
    RUN_THROUGH_SSH systemctl -q disable apt-daily-upgrade.timer
    RUN_THROUGH_SSH systemctl -q disable apt-daily.service
    RUN_THROUGH_SSH systemctl -q disable apt-daily-upgrade.service
    RUN_THROUGH_SSH rm -f /etc/cron.daily/apt-compat 
    RUN_THROUGH_SSH cp /bin/true /usr/lib/apt/apt.systemd.daily


    log_title "Post install Yunohost"
    RUN_THROUGH_SSH yunohost tools postinstall --domain $DOMAIN --password $YUNO_PWD --force-password

    # Disable password strength check
    RUN_THROUGH_SSH yunohost settings set security.password.admin.strength -v -1
    RUN_THROUGH_SSH yunohost settings set security.password.user.strength -v -1

    # echo "Le mot de passe Yunohost est \'$YUNO_PWD\'"
    log_title "Ajout du sous domaine de test"
    RUN_THROUGH_SSH yunohost domain add $SUBDOMAIN
    TEST_USER_DISPLAY=${TEST_USER//"_"/""}
    log_title "Ajout de l'utilisateur de test"
    RUN_THROUGH_SSH yunohost user create $TEST_USER --firstname $TEST_USER_DISPLAY --mail $TEST_USER@$DOMAIN --lastname $TEST_USER_DISPLAY --password \"$YUNO_PWD\"

    log_title "Vérification de l'état de Yunohost"
    RUN_THROUGH_SSH yunohost --version

    log_title "Arrêt de la machine virtualisée"
    sudo lxc-stop -n $LXC_NAME

    log_title "Suppression des règles de parefeu"
    sudo iptables -D FORWARD -i $LXC_BRIDGE -o $MAIN_NETWORK_INTERFACE -j ACCEPT
    sudo iptables -D FORWARD -i $MAIN_NETWORK_INTERFACE -o $LXC_BRIDGE -j ACCEPT
    sudo iptables -t nat -D POSTROUTING -s $LXC_NETWORK.0/24 -j MASQUERADE
    sudo ifdown --force $LXC_BRIDGE

    log_title "Création d'un snapshot"
    sudo lxc-snapshot -n $LXC_NAME
    # Il sera nommé snap0 et stocké dans /var/lib/lxcsnaps/$LXC_NAME/snap0/

    rm "$lock_file"
}

LXC_BUILD 2>&1 | tee -a "./Build_lxc.log"
