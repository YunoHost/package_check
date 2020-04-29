Package checker for YunoHost
==================

[YunoHost project](https://yunohost.org/#/)

> [Lire ce readme en francais](README-fr.md)

Set of unit tests to check YunoHost packages.  
The `package_check.sh` script perform a series of tests on a package for verify its capability to be installed and removed in different situation.  
The test results are printed directly in the terminal and stored in the log file Test_results.log

The script is able to perform the following tests:
- Check the package with [package linter](https://github.com/YunoHost/package_linter)
- Installation in a subdir
- Installation at the root of a domain
- Installation without url access (For apps without web UI)
- Uninstallation
- Reinstallation after uninstallation
- Private installation
- Public installation
- Upgrade from same version of the package
- Upgrade from a previous version of the package
- Backup
- Restore the application after uninstallation
- Restoration without an previous installation
- Multi-instances installation
- Test with the port already used
- Test of change_url script
- Test of all actions and configurations available in config-panel

Package_check script uses a LXC container to manipulate the package in a clean environment without any previous installations.

Usage:  
For a package in a directory: `./package_check.sh APP_ynh`  
For a package on GitHub: `./package_check.sh https://github.com/YunoHost-Apps/APP_ynh`

You need to provide, at the root of the package, a `check_process` file to help the script to test the package with the correct arguments.  
If this file is not present, package_check will be used in downgraded mode. It will try to retrieve domain, path and admin user arguments in the manifest and execute some tests, based on the arguments it can find.

---
## Deploying package_check

Package_check can only be installed on Debian Stretch or Debian Buster.

```
git clone https://github.com/YunoHost/package_check
package_check/sub_scripts/lxc_build.sh

package_check/package_check.sh APP_ynh
```

---
## Syntax of `check_process`
> Except spaces, the syntax of this file must be respected.

```
;; Test name
# Comment ignored
	; pre-install
		echo -n "Here your commands to execute in the container"
		echo ", before each installation of the app."
	; Manifest
		domain="domain.tld"	(DOMAIN)
		path="/path"	(PATH)
		admin="john"	(USER)
		language="fr"
		is_public=1	(PUBLIC|public=1|private=0)
		password="password"
		port="666"	(PORT)
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
		setup_public=1
		upgrade=1
		upgrade=1	from_commit=65c382d138596fcb32b4c97c39398815a1dcd4e8
		backup_restore=1
		multi_instance=1
		port_already_use=1 (XXXX)
		change_url=1
		actions=1
		config_panel=1
;;; Levels
	Level 5=auto
;;; Options
Email=
Notification=none
;;; Upgrade options
	; commit=65c382d138596fcb32b4c97c39398815a1dcd4e8
		name=Name of this previous version
		manifest_arg=domain=DOMAIN&path=PATH&admin=USER&password=pass&is_public=1&
```
### `;; Test name`
A name for the series of tests to perform.  
It's possible to create multiple tests series, all with the same syntax.  
All different series will be performed sequentially.

### `; pre-install`
*Optional instruction*  
If you have to execute a command or a group of commands before the installation. You can use this instruction.  
All the commands added after the instruction `; pre-install` will be executed in the container before each installation of the app.

### `; Manifest`
List of manifest keys.  
All manifest keys need to be filled to perform the installation.
> The manifest keys already in the file here are simply examples. Check the package manifest.  

Some manifest keys are mandatory for the script to performs some tests. This keys must be highlighted, so the script is able to find them and modify their values.  
`(DOMAIN)`, `(PATH)`, `(USER)` and `(PORT)` must be placed at the end of corresponding key. These keys will be changed by the script.  
`(PUBLIC|public=1|private=0)` must, aside of marking the public key, indicate the values for public and private.

### `; Actions`
List of arguments for each action that needs an argument.  
`action_argument` is the name of the argument, as you can find at the end of [action.arguments.**action_argument**].  
`arg1|arg2` are the different arguments to use for the tests. You can have as many arguments as you want, each separated by `|`.

*Only `actions.toml` can be tested by package_check, not `actions.json`.*

### `; Config_panel`
List of arguments for each config_panel configuration.  
`main.categorie.config_example` is the complete toml entry for the argument of a configuration.  
`arg1|arg2` are the different arguments to use for the tests. You can as many arguments as you want, each separated by `|`.

*Only `config_panel.toml` can be tested by package_check, not `config_panel.json`.*

### `; Checks`
List of tests to perform.  
Each test set to 1 will be performed by the script.  
If a test is not in the list, it will be ignored. It's similar to set the test at 0.
- `pkg_linter`: Check the package with [package linter](https://github.com/YunoHost/package_linter)
- `setup_sub_dir`: Installation in a path.
- `setup_root`: Installation at the root of a domain.
- `setup_nourl`: Installation without http access. This test should be perform only for apps that does not have a web interface.
- `setup_private`: Private installation.
- `setup_public`: Public installation.
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

### `;;; Levels`
From [levels](https://yunohost.org/#/packaging_apps_levels_fr) 1 to 8, levels are determined automatically.  
Except the level 5, you can't force a value for a level anymore.  
The level 5 is determined by the results of [package linter](https://github.com/YunoHost/package_linter).  
The default value for this level is `auto`, however, if needed, you can force the value for this level by setting it at `1`, for a positive result, or at `0`, for a negative one.  
If you do so, please add a comment to justify why you force this level.

### `;;; Options`
Supplementary options available in the check_process.  
These options are facultative.  

- `Email` : Allow to specify an alternative email than the one in the manifest for notification by package check, when in a context of a continuous integration server.
- `Notification` : Level of notification for this package. There are 3 available levels.
  - `down` : Send an email only if the level of the package has decreased.
  - `change` : Send an email if the level of the package has changed.
  - `all` : Send an email for each test on this package, whatever the result.

### `;;; Upgrade options`
*Optional instruction*  
For each specified commit for an upgrade, allow to give a name for this version and the manifest parameters which will be used for the preliminary installation.  
If there's no name specified, the commit will be used.  
And if there's no manifest arguments, the default arguments of the check process will be used.  
> 3 variables have to be used for the arguments of the manifest, DOMAIN, PATH and USER.

---
The `package_check.sh` script accept 6 arguments in addition of the package to be checked.
- `--bash-mode`: The script will work without user intervention.  
	auto_remove value is ignored
- `--branch=branch-name`: Check a branch of the repository instead of master. Allow to check a pull request.
	You can use an url with a branch, https://github.com/YunoHost-Apps/APP_ynh/tree/my_branch, to implicitly use this argument.
- `--build-lxc`: Install LXC and create the Debian YunoHost container if necessary.
- `--force-install-ok`: Force success of installations, even if they fail. Allow to perform following tests even if an installation fails.
- `--interrupt`: Force auto_remove value, break before each remove.
- `--help`: Display help.

---
## LXC

Package check uses the virtualization in containers to ensure the integrity of the testing environment.  
Using LXC provides a better stability to the test process, a failed test doesn't impact the following tests and provides a testing environment without residues of previous tests. However, using LXC increases the length of tests, because of the manipulations of the container and reinstallations of dependencies.

It uses also some space on the host, at least 6GB for the container, its snapshots and backup have to available.

Using LXC is eased by 4 scripts, allowing to manage the creation, update, deletion and repair of the container.
- `lxc_build.sh`: lxc_build install LXC and its dependencies, then create a Debian container.  
	It add network support, install YunoHost and configure it. And then configure ssh.  
	The default ssh access is `ssh -t pchecker_lxc`
- `lxc_upgrade.sh`: Perform an upgrade of the container with apt-get and recreate the snapshot.
- `lxc_remove.sh`: Delete the LXC container, its snapshots and backup. Uninstall LXC and deconfigure the associated network.
- `lxc_check.sh`: Check the LXC container and try to fix it if necessary.
