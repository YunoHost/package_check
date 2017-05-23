Package checker for YunoHost
==================

[Yunohost project](https://yunohost.org/#/)

> [Lire ce readme en francais](README-fr.md)

Set of unit tests for check Yunohost packages.  
The `package_check.sh` script perform a series of tests on a package for check its capability to install and remove in différents cases.  
The tests results are print directly in the terminal and stored in the log file Test_results.log

The script is able to perform following tests:
- Check the package with [package linter](https://github.com/YunoHost/package_linter)
- Installation in a subdir
- Installation at root of domain
- Installation without url access (For apps without web UI)
- Private installation.
- Public installation
- Upgrade on same package version
- Backup
- Restore after application uninstall
- Restore without installation before
- Multi-instances installation
- Test malformed path (path/ instead od /path)
- Test port already use
- Test of change_url script

Package_check script use an LXC container to manipulate the package in a non parasited environnement by previous installs.

Usage:  
For an app in a dir: `./package_check.sh APP_ynh`  
For an app on github: `./package_check.sh https://github.com/USER/APP_ynh`

It's necessary to provide, at the root of package to be tested, a `check_process` file for inform the script of needed arguments and tests to perform.  
If this file is not present, package_check will be used in downgraded mode. It try to retrieve domain, path and admin user arguments in the manifest for execute some tests, based on arguments found.

---
## Deploying test script

```
git clone https://github.com/YunoHost/package_check
package_check/sub_scripts/lxc_build.sh
package_check/package_check.sh APP_ynh
```

---
## Syntax `check_process` file
> Except space, this file syntax must be respected.

```
;; Test name
# Comment ignored
	; Manifest
		domain="$DOMAIN"	(DOMAIN)
		path="$PATH"	(PATH)
		admin="$USER"	(USER)
		language="en"
		is_public=1	(PUBLIC|public=1|private=0)
		password="$PASSWORD"	(PASSWORD)
		port="666"	(PORT)
	; Checks
		pkg_linter=1
		setup_sub_dir=1
		setup_root=1
		setup_nourl=0
		setup_private=1
		setup_public=1
		upgrade=1
		backup_restore=1
		multi_instance=1
		incorrect_path=1
		port_already_use=1 (XXXX)
		change_url=1
;;; Levels
	Level 1=auto
	Level 2=auto
	Level 3=auto
	Level 4=0
	Level 5=auto
	Level 6=auto
	Level 7=auto
	Level 8=0
	Level 9=0
	Level 10=0
;;; Options
Email=
Notification=none
```
### `;; Test name`
Name of tests series that will be perform.  
It's possible to create multiples tests series, all with the same syntax.  
All different tests series will be perform sequentialy.

### `; Manifest`
Set of manifest keys.  
All manifest keys need to be filled to perform installation.
> The manifest keys filled here are simply an exemple. Check the app's manifest.
Some manifest keys are necessary for the script to performs some tests. This keys must be highlighted for the script is able to find them and modify their values.  
`(DOMAIN)`, `(PATH)`, `(USER)` and `(PORT)` must be placed at the end of corresponding key. This key will be changed by the script.  
`(PUBLIC|public=1|private=0)` must, in addition to match the public key, indicate the values for public and private.

### `; Checks`
Set of tests to perform.  
Each test marked à 1 will be perform by the script.  
If a test is not in the list, it will be ignored. It's similar to marked at 0.
- `pkg_linter`: Check the package with [package linter](https://github.com/YunoHost/package_linter)
- `setup_sub_dir`: Installation in the path /check.
- `setup_root`: Installation at the root of domain.
- `setup_nourl`: Installation without http access. This test should be perform only for apps that not have web interface.
- `setup_private`: Private installation.
- `setup_public`: Public installation.
- `upgrade`: Upgrade package on same version. Only test the upgrade script.
- `backup_restore`: Backup then restore.
- `multi_instance`: Installing the application 3 times to verify its ability to be multi-instance. The 2nd and 3rd respectively installs are adding a suffix then prefix path.
- `incorrect_path`: Causes an arror with a malformed path, path/.
- `port_already_use`: Causes an error on the port by opening before.  
        The `port_already_use` test may eventually take in argument the port number.  
        The port number must be written into parentheses, it will serve to test port.  
- `change_url`: Try to change the url by 6 different way. Root to path, path to another path and path to root. And the same thing, with another domain.

### `;;; Levels`
Allow to choose how [each level](https://yunohost.org/#/packaging_apps_levels_fr) is determined  
Each level at *auto* will be determinate by the script. It's also possible to fixate the level at *1* or *0* to respectively validate or invalidate it.  
The level 4, 8, 9 and 10 shouldn't be fixed at *auto*, because they don't be tested by the script and they need a manuel check. However, it's allowed to force them at *na* to inform that a level is not applicable (example for the level 4 when a app not permit to use SSO or LDAP). A level at *na* will be ignored in the sum of final level.

For levels forced, please add a comment after the level containing a link toward a ticket explaining why this level have been forced.
Like `Level 4=1 # https://github.com/YunoHost-Apps/$app_ynh/issues/5`.

- Level 1 : The application installs and uninstalls correctly. -- Can be checked by package_check
- Level 2 : The application installs and uninstalls correctly in all standard configurations. -- Can be checked by package_check
- Level 3 : The application may upgrade from an old version. -- Can be checked by package_check
- Level 4 : The application manages LDAP and/or HTTP Auth. -- Must be validated manually
- Level 5 : No errors with package_linter. -- Can be checked by package_check
- Level 6 : The application may be saved and restored without any errors on the same server or an another. -- Can be checked by package_check
- Level 7 : No errors with package check. -- Can be checked by package_check
- Level 8 : The application respects all recommended YEP. -- Must be validated manually
- Level 9 : The application respects all optionnal YEP. -- Must be validated manually
- Level 10 : The application has judged as perfect. -- Must be validated manually

### `;;; Options`
Supplementary options available in the check_process.  
These options are facultative.  

- `Email` : Allow to specify an alternative email than this is in the manifest for notification by package check, when it's in a context of continuous integration.
- `Notification` : Grade of notification for this application. There are 3 available levels.
  - `down` : Send an email only if the level of this application has decreased.
  - `change` : Send an email if the level of this application has changed.
  - `all` : Send an email for each test on this application, whiech ever the result.

---
The `package_check.sh` script accept 6 arguments in addition of package to be checked.
- `--bash-mode`: The script will work without user intervention.  
	auto_remove value is ignored
- `--branch=branch-name`: Check a branch of the repository instead of master. Allow to check a pull request.
- `--build-lxc`: Install  LXC and create the Debian Yunohost container if necessary.
- `--force-install-ok`: Force success of installation, even if they fail. Allow to perform following tests even if installation fail.
- `--interrupt`: Force auto_remove value, break before each remove.
- `--help`: Display help.

---
## LXC

Package check use virtualization in container for ensure integrity of test environnement.  
Using LXC provides better stability to test process, a failed remove test doesn't failed the following tests and provides a test environnement without residues of previous tests. However, using LXC increases the durations of tests, because of the manipulations of container and installed app dépendancies.

There must also be enough space on the host, at least 4GB for the container, its snapshot and backup.

Using LXC is simplified by 4 scripts, allowing to manage the creation, updating, deleting and repairing of container.
- `lxc_build.sh`: lxc_build install LXC and its dependencies, then create a Debian container.  
	It add network support, install Yunohost and configure it. And then configure ssh.  
	The default ssh access is `ssh -t pchecker_lxc`
- `lxc_upgrade.sh`: Perform a upgrade of the container with apt-get and recreate the snapshot.
- `lxc_remove.sh`: Delete the LXC container, its snapshot and backup. Uninstall LXC and deconfigures the associated network.
- `lxc_check.sh`: Check the LXC container and try to fix it if necessary.
