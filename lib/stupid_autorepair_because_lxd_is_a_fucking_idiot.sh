#!/bin/bash

# To be called as a cronjob e.g. from /etc/cron.d/whatever
# */5 * * * * root "/path/to/package_check/lib/stupid_autorepair_because_lxd_is_a_fucking_idiot.sh"

lxc=/usr/local/bin/lxc
for CONTAINER in $($lxc list --format json | jq -r '.[] | select(.status == "Stopped") | .name')
do
    echo $CONTAINER
    if $lxc info $CONTAINER >/dev/null 2>/dev/null &&  [ "$(ls /var/lib/*/containers/$CONTAINER/ | wc -l)" == 1 ] && ls /var/lib/*/containers/$CONTAINER/backup.yaml >/dev/null 2>/dev/null;
    then
        rm /var/lib/*/containers/$CONTAINER/backup.yaml
        $lxc delete $CONTAINER --force 2>/dev/null
    fi
done
