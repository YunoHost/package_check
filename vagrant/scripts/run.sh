#!/bin/bash

cd /home/vagrant/package_check/vagrant/

echo "Package check: '${1}'"

if [ ! -d "${1}" ]; then
    echo "ERROR: Repro '${1}' not found!"
    exit -1
fi

set -x

lxd init --auto

/home/vagrant/package_check/package_check.sh "${1}"
