#!/bin/bash

set -x

apt-get update
apt-get dist-upgrade

apt-get install -y python3-pip git snapd lynx jq

snap install core
snap refresh lxd

ln -sf /snap/bin/lxc /usr/local/bin/lxc
ln -sf /snap/bin/lxd /usr/local/bin/lxd

gpasswd -a vagrant lxd

lxd init --auto

lxc remote add yunohost https://devbaseimgs.yunohost.org --public --accept-certificate

exit 0