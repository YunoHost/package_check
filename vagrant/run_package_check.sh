#!/bin/bash

if [ "$1" == "" ]; then
    echo "ERROR: Missing repro name as argument!"
    echo "e.g.:"
    echo "~$ cd package_check/vagrant/repos"
    echo "~/package_check/vagrant/repos$ git clone https://github.com/YunoHost-Apps/pyinventory_ynh.git"
    echo "~/package_check/vagrant/repos$ cd .."
    echo "~/package_check/vagrant$ ./run_package_check.sh repos/pyinventory_ynh"
    exit -1
fi

echo "Package check: '${1}'"
if [ ! -d "${1}" ]; then
    echo "ERROR: Repro '${1}' not found !"
    exit -1
fi

set -x

vagrant up
vagrant ssh -c "/home/vagrant/package_check/vagrant/scripts/run.sh ${1}"