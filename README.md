Package checker for YunoHost
==================

[YunoHost project](https://yunohost.org/#/)

Set of unit tests to check YunoHost packages.
The `package_check.sh` script perform a series of tests on a package for verify its capability to be installed and removed in different situation.
The test results are printed directly in the terminal and stored in the log file Test_results.log

The script is able to perform the following tests:

- [Linter](https://github.com/YunoHost/package_linter)
- Install/remove/reinstall at the root of a domain (`domain.tld/`)
- Install/remove/reinstall in a subpath (`domain.tld/foobar`)
- Install/remove/reinstall with no url (for non-webapps)
- Install with `is_public=0` (private install)
- Install multiple instances (if `multi_instance` is true)
- Upgrade from same version
- Upgrade from previous versions
- Backup/restore
- Changing the installation url (`change_url`)
- Actions and config-panel

Package_check script uses a LXC container to manipulate the package in a clean environment without any previous installations.

Usage:
For a package in a directory: `./package_check.sh APP_ynh`
For a package on GitHub: `./package_check.sh https://github.com/YunoHost-Apps/APP_ynh`

You need to provide, at the root of the package, a `check_process` file to help the script to test the package with the correct arguments.
If this file is not present, package_check will be used in downgraded mode. It will try to retrieve domain, path and admin user arguments in the manifest and execute some tests, based on the arguments it can find.

## Deploying package_check

First you need to install the system dependencies.

Package check is based on the LXD/LXC ecosystem. Be careful that
**LXD can conflict with other installed virtualization technologies such as
libvirt or vanilla LXCs**, especially because they all require a daemon based
on DNSmasq which may list on port 53.

On a Debian-based system (regular Debian, Ubuntu, Mint ...), LXD can be
installed using `snapd`. On other systems like Archlinux, you will probably also
be able to install `snapd` using the system package manager (or even
`lxd` directly).

```bash
apt install git snapd lynx jq
sudo snap install core
sudo snap install lxd

# Adding lxc/lxd to /usr/local/bin to make sure we can use them easily even
# with sudo for which the PATH is defined in /etc/sudoers and probably doesn't
# include /snap/bin
sudo ln -s /snap/bin/lxc /usr/local/bin/lxc
sudo ln -s /snap/bin/lxd /usr/local/bin/lxd
```

NB. : you should **make sure that your user is in the `lxd` group** so that it's
able to run `lxc` commands without sudo... You can check this with the command
`groups` where you should see `lxd`. Otherwise, add your user to this group
(don't forget that you may need to reload your entire graphical session for this
to propagate (sigh))

Then you shall initialize LXD which will ask you a bunch of question. Usually
answering the default (just pressing enter) to all questions is fine. Just pay
attention to :

- the storage backend driver. Possibly `zfs` is the best, but requires a kernel >= 5.x
  and corresponding kernel module loaded. You can fallback to the `dir` driver.
- the size of the default storage it'll create (the default is 5G but you may
  want 10G for heavy usage ?) (if you're using the 'dir' driver, this won't be asked)

```bash
lxd init
```

The base images for tests are centralized on `devbaseimgs.yunohost.org` and we'll download them from there to speed things up:

```bash
lxc remote add yunohost https://devbaseimgs.yunohost.org --public
```

(At the time this README is written, fingerprint is d9ae6e76c374e3c58c3c20a881cffe7435809adb3b222ec393805f5bd01bb522 )

Then you can install package check :

```
git clone https://github.com/YunoHost/package_check
cd package_check
```

Then test your packages :

```
./package_check.sh your_app_ynh
```

## Run package check in a VirtualBox VM via Vagrant

We add script to run package check in a VirtualBox. More information here:

* [vagrant/README.md](https://github.com/YunoHost/package_check/tree/master/vagrant)


## You can start a container on a different architecture with some hacks

Install the package `qemu-user-static` and `binfmt-support`, then list of all available images :

```
lxc image list images:debian/buster
```

Export the image of the architecture you want to run (for example armhf):

```
lxc image export images:debian/buster/armhf
```

This command will create two files.

- rootfs.squashfs
- lxd.tar.xz

We need to change the architecture of the metadata:

```
tar xJf lxd.tar.xz
sed -i '0,/architecture: armhf/s//architecture: amd64/' metadata.yaml
tar cJf lxd.tar.xz metadata.yaml templates
```

And reimport the image:

```
lxc image import lxd.tar.xz rootfs.squashfs --alias test-arm
```

You can now start an armhf image with:

```
lxc launch test-arm
lxc exec inspired-lamprey -- dpkg --print-architecture
```

If the `build_base_lxc.sh` script detects that you are trying a cross container architecture, it will try to perform this hack

## Syntax of `check_process`

> Except spaces, the syntax of this file must be respected.

```
;; Default test serie
# Comment ignored
	; pre-install
		set -euxo pipefail
		echo -n "Here your commands to execute in the container"
		echo ", before each installation of the app."
	; pre-upgrade
		set -euxo pipefail
		if [ "$FROM_COMMIT" == '65c382d138596fcb32b4c97c39398815a1dcd4e8' ]
		then
			resolve=127.0.0.1:443:$DOMAIN
			# Example of request using curl
			curl -X POST --data '{"some-key": "some-value"}' https://$DOMAIN/$PATH --resolve "$resolve"
		fi
	; Manifest
        # You need to provide default values for installation parameters ...
        # EXCEPT for special args: domain, path, admin, and is_public
        # which will be filled automatically during tests
		language="fr"
		password="password"
		port="666"
	; Actions
		action_argument=arg1|arg2
		is_public=1|0
	; Config_panel
		main.categorie.config_example=arg1|arg2
		main.overwrite_files.overwrite_phpfpm=1|0
		main.php_fpm_config.footprint=low|medium|high|specific
		main.php_fpm_config.free_footprint=20
		main.php_fpm_config.usage=low|medium|high
	; Checks
		pkg_linter=1
		setup_sub_dir=1
		setup_root=1
		setup_nourl=0
		setup_private=1
		upgrade=1
		upgrade=1	from_commit=65c382d138596fcb32b4c97c39398815a1dcd4e8
		backup_restore=1
		multi_instance=1
		port_already_use=1	(66)
		change_url=0
		actions=0
		config_panel=0
;;; Upgrade options
	; commit=65c382d138596fcb32b4c97c39398815a1dcd4e8
		name=Name of this previous version
		manifest_arg=domain=DOMAIN&path=PATH&admin=USER&password=pass&is_public=1&
```

### `;; Default test serie`

A name for the series of tests to perform.
It's possible to create multiple tests series, all with the same syntax.
All different series will be performed sequentially.

### `; pre-install`

_Optional instruction_
If you have to execute a command or a group of commands before the installation. You can use this instruction.
All the commands added after the instruction `; pre-install` will be executed in the container before each installation of the app.

### `; Manifest`

List of manifest keys.
All manifest keys need to be filled to perform the installation.

> The manifest keys already in the file here are simply examples. Check the package manifest.

### `; Actions`

List of arguments for each action that needs an argument.
`action_argument` is the name of the argument, as you can find at the end of [action.arguments.**action_argument**].
`arg1|arg2` are the different arguments to use for the tests. You can have as many arguments as you want, each separated by `|`.

_Only `actions.toml` can be tested by package_check, not `actions.json`._

### `; Config_panel`

List of arguments for each config_panel configuration.
`main.categorie.config_example` is the complete toml entry for the argument of a configuration.
`arg1|arg2` are the different arguments to use for the tests. You can as many arguments as you want, each separated by `|`.

_Only `config_panel.toml` can be tested by package_check, not `config_panel.json`._

### `; Checks`

List of tests to perform.
Each test set to 1 will be performed by the script.
If a test is not in the list, it will be ignored. It's similar to set the test at 0.

- `pkg_linter`: Check the package with [package linter](https://github.com/YunoHost/package_linter)
- `setup_root`: Installation at the root of a domain.
- `setup_sub_dir`: Installation in a path.
- `setup_nourl`: Installation with no domain/path. This test is meant for non-web apps
- `setup_private`: Private installation.
- `upgrade`: Upgrade the package to the same version. Only to test the upgrade script.
- `upgrade from_commit`: Upgrade the package from the specified commit to the latest version.
- `backup_restore`: Backup then restore.
- `multi_instance`: Install the application 2 times, to verify its ability to be multi-instanced.
- `port_already_use`: Provoke an error by opening the port before.
  The `port_already_use` test may eventually take as argument the port number.
  The port number must be written into parentheses.
- `change_url`: Try to change the url by 6 different ways. Root to path, path to another path and path to root. And the same thing, to another domain.
- `actions`: All actions available in actions.toml
- `config_panel`: All configurations available in config_panel.toml

### `;;; Upgrade options`

_Optional instruction_
For each specified commit for an upgrade, allow to give a name for this version and the manifest parameters which will be used for the preliminary installation.
If there's no name specified, the commit will be used.
And if there's no manifest arguments, the default arguments of the check process will be used.

> 3 variables have to be used for the arguments of the manifest, DOMAIN, PATH and USER.

---

The `package_check.sh` script accept 6 arguments in addition of the package to be checked.

- `--branch=branch-name`: Check a branch of the repository instead of master. Allow to check a pull request.
  You can use an url with a branch, https://github.com/YunoHost-Apps/APP_ynh/tree/my_branch, to implicitly use this argument.
- `--interactive`: Wait for user input between each tests
- `--help`: Display help.
