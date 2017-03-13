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
- Backup
- Restore après suppression de l'application
- Restore sans installation préalable
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
## Déploiement du script de test

```
git clone https://github.com/YunoHost/package_check
package_check/sub_scripts/lxc_build.sh
package_check/package_check.sh APP_ynh
```

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
		wrong_user=1
		wrong_path=1
		incorrect_path=1
		corrupt_source=0
		fail_download_source=0
		port_already_use=1 (XXXX)
		final_path_already_use=0
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
`(PUBLIC|public=1|private=0)` doit, en plus de correspondre à la clé de visibilité public, indiquer les valeurs du manifest pour public et privé.

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

### `;;; Levels`
Permet de choisir comment [chaque niveau](https://yunohost.org/#/packaging_apps_levels_fr) est déterminé.  
Chaque niveau fixé à *auto* sera déterminé par le script. Il est également possible de fixer le niveau à *1* ou à *0* pour respectivement le valider ou l'invalider.  
Il est à noter que les niveaux 4, 8, 9 et 10 ne peuvent être fixés à *auto* car ils ne peuvent être testés par le script et nécessitent une vérification manuelle. Il est toutefois possible de les fixer à *na* pour indiquer que le niveau n'est pas applicable (par exemple pour le niveau 4 quand une app ne propose pas de SSO LDAP). Un niveau *na* sera tout simplement ignoré dans le calcul du niveau final.
- Niveau 1 : L'application s'installe et se désinstalle correctement. -- Peut être vérifié par package_check
- Niveau 2 : L'application s'installe et se désinstalle dans toutes les configurations communes. -- Peut être vérifié par package_check
- Niveau 3 : L'application supporte l'upgrade depuis une ancienne version du package. -- Peut être vérifié par package_check
- Niveau 4 : L'application prend en charge de LDAP et/ou HTTP Auth. -- Doit être vérifié manuellement
- Niveau 5 : Aucune erreur dans package_linter. -- Peut être vérifié par package_check
- Niveau 6 : L'application peut-être sauvegardée et restaurée sans erreurs sur la même machine ou une autre. -- Peut être vérifié par package_check
- Niveau 7 : Aucune erreur dans package check. -- Peut être vérifié par package_check
- Niveau 8 : L'application respecte toutes les YEP recommandées. -- Doit être vérifié manuellement
- Niveau 9 : L'application respecte toutes les YEP optionnelles. -- Doit être vérifié manuellement
- Niveau 10 : L'application est jugée parfaite. -- Doit être vérifié manuellement

---
Le script `package_check.sh` accepte 6 arguments en plus du package à tester.
- `--bash-mode`: Rend le script autonome. Aucune intervention de l'utilisateur ne sera nécessaire.  
	La valeur de auto_remove est ignorée.
- `--branch=nom-de-branche`: Teste une branche du dépôt plutôt que de tester master. Permet de tester les pull request.
- `--build-lxc`: Installe LXC et créer le conteneur debian Yunohost si nécessaire.
- `--force-install-ok`: Force la réussite des installations, même si elles échouent. Permet d'effectuer les tests qui suivent même si l'installation a échouée.
- `--interrupt`: Force l'option auto_remove à 0, le script marquera une pause avant chaque suppression d'application.
- `--no-lxc`: N'utilise pas la virtualisation en conteneur LXC. Les tests seront effectué directement sur la machine hôte.
- `--help`: Affiche l'aide du script

---
## LXC

Package check utilise la virtualisation en conteneur pour assurer l'intégrité de l'environnement de test.  
L'usage de LXC apporte une meilleure stabilité au processus de test, un test de suppression échoué n'entraine pas l'échec des tests suivant, et permet de garder un environnement de test sans résidus de test précédents. En revanche, l'usage de LXC augmente la durée des tests, en raison des manipulations du conteneur et de la réinstallation systématique des dépendances de l'application.

Il faut prévoir également un espace suffisant sur l'hôte, au minimum 4Go pour le conteneur, son snapshot et sa copie de sauvegarde.

L'usage de LXC est facilité par 4 scripts, permettant de gérer la création, la mise à jour, la suppression et la réparation du conteneur.
- `lxc_build.sh`: lxc_build installe LXC et ses dépendances, puis créer le conteneur debian.  
	Il ajoute ensuite le support réseau, installe Yunohost et le configure. Et enfin configure un accès ssh.  
	L'accès ssh par défaut est `ssh -t pchecker_lxc`
- `lxc_upgrade.sh`: Effectue la mise à jour du conteneur à l'aide d'apt-get et recréer le snapshot.
- `lxc_remove.sh`: Supprime le conteneur LXC, son snapshot et sa sauvegarde. Désinstalle LXC et déconfigure le réseau associé.
- `lxc_check.sh`: Vérifie le conteneur LXC et tente de le réparer si nécessaire.

---
---
## Package checker for YunoHost

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
	auto_remove=1
# Comment ignore
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
- `wrong_user`: Causes an errror with a wrong user name.
- `wrong_path`: Causes an error with a wrong domain.
- `incorrect_path`: Causes an arror with a malformed path, path/.
- `corrupt_source`: *Not implemented yet...*
- `fail_download_source`: *Not implemented yet...*
- `port_already_use`: Causes an error on the port by opening before.  
        The `port_already_use` test may eventually take in argument the port number.  
        The port number must be written into parentheses, it will serve to test port.  
- `final_path_already_use`: *Not implemented yet...*

### `;;; Levels`
Allow to choose how [each level](https://yunohost.org/#/packaging_apps_levels_fr) is determined  
Each level at *auto* will be determinate by the script. It's also possible to fixate the level at *1* or *0* to respectively validate or invalidate it.  
The level 4, 8, 9 and 10 shouldn't be fixed at *auto*, because they don't be tested by the script and they need a manuel check. However, it's allowed to force them at *na* to inform that a level is not applicable (example for the level 4 when a app not permit to use SSO or LDAP). A level at *na* will be ignored in the sum of final level.

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

---
The `package_check.sh` script accept 6 arguments in addition of package to be checked.
- `--bash-mode`: The script will work without user intervention.  
	auto_remove value is ignored
- `--branch=branch-name`: Check a branch of the repository instead of master. Allow to check a pull request.
- `--build-lxc`: Install  LXC and create the Debian Yunohost container if necessary.
- `--force-install-ok`: Force success of installation, even if they fail. Allow to perform following tests even if installation fail.
- `--interrupt`: Force auto_remove value, break before each remove.
- `--no-lxc`: Not use virtualization with LXC container. All tests will perform directly on the hosts machine.
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
