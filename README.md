Package checker for YunoHost
==================

[Yunohost project](https://yunohost.org/#/)

Ensemble de tests unitaires pour vérifier les packages Yunohost.  
Le script `package_check.sh` effectue une succession de test sur un package afin de vérifier sa capacité à s'installer et se désinstaller dans différents cas.  
Le résultats des tests est affiché directement et stocké dans le fichier Test_results.log

Le script est capable d'effectuer les tests suivant:
- Vérification du package avec [package linter](https://github.com/YunoHost/package_linter)
- Installation en sous-dossier
- Installation à la racine du domaine
- Installation sans accès par url (Pour les applications n'ayant pas d'interface web)
- Installation en privé
- Installation en public
- Upgrade sur la même version du package
- Backup puis restore
- Installation multi-instance
- Test d'utilisateur incorrect
- Test de domaine incorrect
- Test de path mal formé (path/ au lieu de /path)
- Test de port déjà utilisé

Par défaut, Package check utilise un conteneur LXC pour créer un environnement de test propre sans résidus d'installations précédentes. Ce comportement peut être contourné avec le paramètre --no-lxc
> ATTENTION: Si LXC n'est pas utilisé, le script devrait être utilisé uniquement dans un environnement de test dédié, jamais sur un serveur en production. Il va provoquer de nombreuses erreurs d'installation du package et pourrait donc laisser des résidus indésirables.

Usage:  
Pour une app dans un dossier: `./package_check.sh APP_ynh`  
Pour une app sur github: `./package_check.sh https://github.com/USER/APP_ynh`

Il est nécessaire de fournir, à la racine du package de l'app à tester, un fichier `check_process` pour indiquer au script les arguments attendu et les tests à effectuer.  
Si ce fichier n'est pas présent, package_check sera utilisé en mode dégradé. Il va tenter de repérer les arguments domain, path et admin dans le manifest pour exécuter un nombre restreint de test, en fonction des arguments trouvés.

---
## Syntaxe du fichier `check_process`
> A l'exception des espaces, la syntaxe du fichier doit être scrupuleusement respectée.

```
;; Nom du test
	auto_remove=1
# Commentaire ignoré
	; Manifest
		domain="$DOMAIN"	(DOMAIN)
		path="$PATH"	(PATH)
		admin="$USER"	(USER)
		language="fr"
		is_public="Yes"	(PUBLIC|public=Yes|private=No)
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
		wrong_user=1
		wrong_path=1
		incorrect_path=1
		corrupt_source=0
		fail_download_source=0
		port_already_use=1 (XXXX)
		final_path_already_use=0
```
### `;; Nom du test`
Nom du scénario de test qui sera effectué.  
On peut créer autant de scénario de test que voulu, tous ayant la même syntaxe.  
Les différents scénarios de test seront exécutés successivement.

### `auto_remove`
Si `auto_remove` est à 0, le script marque une pause avant chaque suppression de l'app. Afin d'éffectuer des vérifications manuelles si nécessaire.  
Sinon, l'app est supprimée automatiquement et les tests continuent.

### `; Manifest`
Ensemble des clés du manifest.  
Toutes les clés du manifest doivent être renseignée afin de procéder à l'installation.
> Les clés de manifest données ici ne le sont qu'à titre d'exemple. Voir le manifest de l'application.
Certaines clés de manifest sont indispensables au script pour effectuer certains test. Ces clés doivent être mises en évidence afin que le script soit capable de les retrouver et de changer leur valeur.  
`(DOMAIN)`, `(PATH)`, `(USER)`, `(PASSWORD)` et `(PORT)` doivent être mis en bout de ligne des clés correspondantes. Ces clés seront modifiées par le script.  
`(PUBLIC|public=Yes|private=No)` doit, en plus de correspondre à la clé de visibilité public, indiquer les valeurs du manifest pour public et privé.

### `; Checks`
Ensemble des tests à effectuer.  
Chaque test marqué à 1 sera effectué par le script.  
Si un test est absent de la liste, il sera ignoré. Cela revient à le noter à 0.
- `pkg_linter`: Vérification du package avec [package linter](https://github.com/YunoHost/package_linter)
- `setup_sub_dir`: Installation dans le path /check.
- `setup_root`: Installation à la racine du domaine.
- `setup_nourl`: Installation sans accès http. Ce test ne devrait être choisi que pour les applications ne disposant pas d'une interface web.
- `setup_private`: Installation en privé.
- `setup_public`: Installation en public.
- `upgrade`: Upgrade du package sur la même version. Test uniquement le script upgrade.
- `backup_restore`: Backup et restauration.
- `multi_instance`: Installation de l'application 3 fois de suite, pour vérifier sa capacité à être multi-instance. Les 2e et 3e installations se font respectivement en ajoutant un suffixe et un préfixe au path.
- `wrong_user`: Provoque une erreur avec un nom d'utilisateur incorrect.
- `wrong_path`: Provoque une erreur avec un domain incorrect.
- `incorrect_path`: Provoque une erreur avec un path malformé, path/.
- `corrupt_source`: *Non implémenté pour le moment...*
- `fail_download_source`: *Non implémenté pour le moment...*
- `port_already_use`: Provoque une erreur sur le port en l'ouvrant avant le script d'install.  
	Le test` port_already_use` peut éventuellement prendre en argument un numéro de port. Si celui-ci n'est pas dans le manifest.  
	Le numéro de port doit alors être noté entre parenthèse, il servira au test de port.  
- `final_path_already_use`: *Non implémenté pour le moment...*

---
Le script `package_check.sh` accepte 5 arguments en plus du package à tester.
- `--bash-mode`: Rend le script autonome. Aucune intervention de l'utilisateur ne sera nécessaire.  
	La valeur de auto_remove est ignorée. (Incompatible avec --build-lxc)
- `--no-lxc`: N'utilise pas la virtualisation en conteneur LXC. Les tests seront effectué directement sur la machine hôte.
- `--build-lxc`: Installe LXC et créer le conteneur debian Yunohost si nécessaire. (Incompatible avec --bash-mode)
- `--force-install-ok`: Force la réussite des installations, même si elles échouent. Permet d'effectuer les tests qui suivent même si l'installation a échouée.
- `--help`: Affiche l'aide du script

---
## LXC

Package check utilise la virtualisation en conteneur pour assurer l'intégrité de l'environnement de test.  
L'usage de LXC apporte une meilleure stabilité au processus de test, un test de suppression échoué n'entraine pas l'échec des tests suivant, et permet de garder un environnement de test sans résidus de test précédents. En revanche, l'usage de LXC augmente la durée des tests, en raison des manipulations du conteneur et de la réinstallation systématique des dépendances de l'application.

Il faut prévoir également un espace suffisant sur l'hôte, au minimum 4Go pour le conteneur, son snapshot et sa copie de sauvegarde.

L'usage de LXC est facilité par 3 scripts, permettant de gérer la création, la mise à jour et la suppression.
- `lxc_build.sh`: lxc_build installe LXC et ses dépendances, puis créer le conteneur debian.  
	Il ajoute ensuite le support réseau, installe Yunohost et le configure. Et enfin configure un accès ssh.  
	L'accès ssh par défaut est `ssh -t pchecker_lxc`
- `lxc_upgrade.sh`: Effectue la mise à jour du conteneur à l'aide d'apt-get et recréer le snapshot.
- `lxc_remove.sh`: Supprime le conteneur LXC, son snapshot et sa sauvegarde. Désinstalle LXC et déconfigure le réseau associé.

---
---

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
- Backup then restore
- Multi-instances installation
- Test with wrong user
- Test with wrong domain
- Test malformed path (path/ instead od /path)
- Test port already use

As default, package_check script use an LXC container to manipulate the package in a non parasited environnement by previous installs. This behavior can be overriden with --no-lxc parameter.
> BE CAREFUL, If LXC is not used, this script should be used only in a dedicated test environnement, never on a prod server. It will causes many installations errors and risk to leave residues.

Usage:  
For an app in a dir: `./package_check.sh APP_ynh`  
For an app on github: `./package_check.sh https://github.com/USER/APP_ynh`

It's necessary to provide, at the root of package to be tested, a `check_process` file for inform the script of needed arguments and tests to perform.  
If this file is not present, package_check will be used in downgraded mode. It try to retrieve domain, path and admin user arguments in the manifest for execute some tests, based on arguments found.

---
## Syntax `check_process` file
> Except space, this file syntax must be respected.

```
;; Test name
	auto_remove=1
# Comment ignore
	; Manifest
		domain="$DOMAIN"	(DOMAIN)
		path="$PATH"	(PATH)
		admin="$USER"	(USER)
		language="en"
		is_public="Yes"	(PUBLIC|public=Yes|private=No)
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
		wrong_user=1
		wrong_path=1
		incorrect_path=1
		corrupt_source=0
		fail_download_source=0
		port_already_use=1 (XXXX)
		final_path_already_use=0
```
### `;; Test name`
Name of tests series that will be perform.  
It's possible to create multiples tests series, all with the same syntax.  
All different tests series will be perform sequentialy.

### `auto_remove`
If `auto_remove` is at 0, the script pause before each deleting of app. To lets you check manually if necessary.  
Otherwise, the app is automaticaly removed and tests continue.

### `; Manifest`
Set of manifest keys.  
All manifest keys need to be filled to perform installation.
> The manifest keys filled here are simply an exemple. Check the app's manifest.
Some manifest keys are necessary for the script to performs some tests. This keys must be highlighted for the script is able to find them and modify their values.  
`(DOMAIN)`, `(PATH)`, `(USER)`, `(PASSWORD)` and `(PORT)` must be placed at the end of corresponding key. This key will be changed by the script.  
`(PUBLIC|public=Yes|private=No)` must, in addition to match the public key, indicate the values for public and private.

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
- `wrong_user`: Causes an errror with a wrong user name.
- `wrong_path`: Causes an error with a wrong domain.
- `incorrect_path`: Causes an arror with a malformed path, path/.
- `corrupt_source`: *Not implemented yet...*
- `fail_download_source`: *Not implemented yet...*
- `port_already_use`: Causes an error on the port by opening before.  
        The `port_already_use` test may eventually take in argument the port number.  
        The port number must be written into parentheses, it will serve to test port.  
- `final_path_already_use`: *Not implemented yet...*

---
The `package_check.sh` script accept 5 arguments in addition of package to be checked.
- `--bash-mode`: The script will work without user intervention.  
	auto_remove value is ignored (Not compatible with --build-lxc)
- `--no-lxc`: Not use virtualization with LXC container. All tests will perform directly on the hosts machine.
- `--build-lxc`: Install  LXC and create the Debian Yunohost container if necessary. (Not compatible with --bash-mode)
- `--force-install-ok`: Force success of installation, even if they fail. Allow to perform following tests even if installation fail.
- `--help`: Display help.

---
## LXC

Package check use virtualization in container for ensure integrity of test environnement.  
Using LXC provides better stability to test process, a failed remove test doesn't failed the following tests and provides a test environnement without residues of previous tests. However, using LXC increases the durations of tests, because of the manipulations of container and installed app dépendancies.

There must also be enough space on the host, at least 4GB for the container, its snapshot and backup.

Using LXC is simplified by 3 scripts, allowing to manage the creation, updating and deleting.
- `lxc_build.sh`: lxc_build install LXC and its dependencies, then create a Debian container.  
	It add network support, install Yunohost and configure it. And then configure ssh.  
	The default ssh access is `ssh -t pchecker_lxc`
- `lxc_upgrade.sh`: Perform a upgrade of the container with apt-get and recreate the snapshot.
- `lxc_remove.sh`: Delete the LXC container, its snapshot and backup. Uninstall LXC and deconfigures the associated network.
