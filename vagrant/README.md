# "package check" via Vagrant

Run [package check](https://github.com/YunoHost/package_check) in a [VirtualBox](https://www.virtualbox.org/) VM by using [Vagrant](https://www.vagrantup.com/).

## prepare

install VirtualBox and Vagrant: 

```
sudo apt install virtualbox vagrant
```

Directory overview:
```
~$ tree package_check/ -dA
package_check/
├── lib
└── vagrant                   <<< main directory to setup/start package check via Vagrant
    ├── repos                 <<< clone your YunoHost apps here
    │   └── pyinventory_ynh   <<< just a clone example
    │       ├── conf
    │       ├── scripts
    │       └── tests
    └── scripts
```

Startup, e.g.:
```
# Clone package check:
~$ git clone https://github.com/YunoHost/package_check.git

# Clone the YunoHost app that you would like to ckec into "repos":
~$ cd package_check/vagrant/repos
~/package_check/vagrant/repos$ git clone https://github.com/YunoHost-Apps/pyinventory_ynh.git

# Start the VirtualBox VM anr run the check:
~/package_check/vagrant$ ./run_package_check.sh repos/pyinventory_ynh/
```

## update

Quick update can look like:
```
# Update package check:
~$ cd package_check
~/package_check$ git pull origin master

# quick update the VM:
~$ cd package_check/vagrant
~/package_check/vagrant$ vagrant reload --provision
```

To get everything completely fresh: destroy the VM and recreate it, e.g.:

```
~$ cd package_check/vagrant
~/package_check/vagrant$ vagrant destroy --force

# Just recreate the VM by run the check, e.g.:
~/package_check/vagrant$ ./run_package_check.sh repos/pyinventory_ynh/
```

## uninstall/cleanup

To remove the VM, just destroy it, e.g.:

```
~$ cd package_check/vagrant
~/package_check/vagrant$ vagrant destroy --force
```

## Links

* Vagrant docs: https://docs.vagrantup.com
* YunoHost "package check": https://github.com/YunoHost/package_check