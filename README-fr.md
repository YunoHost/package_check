Package checker pour YunoHost
==================

[Projet YunoHost](https://yunohost.org/#/)

> [Read this readme in english](README.md)

Ensemble de tests unitaires pour vérifier les packages Yunohost.  
Le script `package_check.sh` effectue une succession de test sur un package afin de vérifier sa capacité à s'installer et se désinstaller dans différents cas.  
Le résultats des tests est affiché directement et stocké dans le fichier Test_results.log

Le script est capable d'effectuer les tests suivant:
- Vérification du package avec [package linter](https://github.com/YunoHost/package_linter)
- Installation en sous-dossier
- Installation à la racine du domaine
- Installation sans accès par url (Pour les applications n'ayant pas d'interface web)
- Désinstallation
- Réinstallation après désinstallation
- Installation en privé
- Installation en public
- Upgrade depuis la même version du package
- Upgrade depuis une précédente version du package
- Backup
- Restore après suppression de l'application
- Restore sans installation préalable
- Installation multi-instance
- Test de port déjà utilisé
- Test du script change_url
- Test des actions et configurations disponible dans le config-panel

Package check utilise un conteneur LXC pour créer un environnement de test propre sans résidus d'installations précédentes.

Usage:  
Pour une app dans un dossier: `./package_check.sh APP_ynh`  
Pour une app sur github: `./package_check.sh https://github.com/USER/APP_ynh`

Il est nécessaire de fournir, à la racine du package de l'app à tester, un fichier `check_process` pour indiquer au script les arguments attendu et les tests à effectuer.  
Si ce fichier n'est pas présent, package_check sera utilisé en mode dégradé. Il va tenter de repérer les arguments domain, path et admin dans le manifest pour exécuter un nombre restreint de test, en fonction des arguments trouvés.

---
## Déploiement de package_check

Package_check ne peut être installer que sur Debian Stretch ou Debian Buster.

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
# Commentaire ignoré
	; pre-install
		echo -n "Placez ici vos commandes a exéxuter dans le conteneur, "
		echo "avant chaque installation de l'application."
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
### `;; Nom du test`
Nom du scénario de test qui sera effectué.  
On peut créer autant de scénario de test que voulu, tous ayant la même syntaxe.  
Les différents scénarios de test seront exécutés successivement.

### `; pre-install`
*Instruction optionnelle*  
Si vous devez exécuter une commande ou un groupe de commandes avant l'installation, vous pouvez utiliser cette instruction.  
Toutes les commandes ajoutées après l'instruction `; pre-install` seront exécutées dans le conteneur avant chaque installation de l'application.

### `; Manifest`
Ensemble des clés du manifest.  
Toutes les clés du manifest doivent être renseignée afin de procéder à l'installation.
> Les clés de manifest données ici ne le sont qu'à titre d'exemple. Voir le manifest de l'application.

Certaines clés de manifest sont indispensables au script pour effectuer certains test. Ces clés doivent être mises en évidence afin que le script soit capable de les retrouver et de changer leur valeur.  
`(DOMAIN)`, `(PATH)`, `(USER)` et `(PORT)` doivent être mis en bout de ligne des clés correspondantes. Ces clés seront modifiées par le script.  
`(PUBLIC|public=1|private=0)` doit, en plus de correspondre à la clé de visibilité public, indiquer les valeurs du manifest pour public et privé.

### `; Actions`
List des arguments pour chaque action nécessitant un argument.  
`action_argument` est le nom de l'argument, ainsi que vous pouvez le trouver à la fin de [action.arguments.**action_argument**].  
`arg1|arg2` sont les différents arguments à utiliser pour les test. Vous pouvez mettre autant d'arguments que désiré, séparé par `|`.

*Seul `actions.toml` peut être testé par package_check, pas `actions.json`.*

### `; Config_panel`
List des arguments pour chaque configuration de config_panel.  
`main.categorie.config_example` est l'entrée toml complète pour l'argument de cette configuration.  
`arg1|arg2` sont les différents arguments à utiliser pour les test. Vous pouvez mettre autant d'arguments que désiré, séparé par `|`.

*Seul `config_panel.toml` peut être testé par package_check, pas `config_panel.json`.*

### `; Checks`
Ensemble des tests à effectuer.  
Chaque test marqué à 1 sera effectué par le script.  
Si un test est absent de la liste, il sera ignoré. Cela revient à le noter à 0.
- `pkg_linter`: Vérification du package avec [package linter](https://github.com/YunoHost/package_linter)
- `setup_sub_dir`: Installation dans un path.
- `setup_root`: Installation à la racine du domaine.
- `setup_nourl`: Installation sans accès http. Ce test ne devrait être choisi que pour les applications ne disposant pas d'une interface web.
- `setup_private`: Installation en privé.
- `setup_public`: Installation en public.
- `upgrade`: Upgrade du package sur la même version. Test uniquement le script upgrade.
- `upgrade from_commit`: Upgrade du package à partir du commit spécifié vers la dernière version.
- `backup_restore`: Backup et restauration.
- `multi_instance`: Installation de l'application 2 fois de suite, pour vérifier sa capacité à être multi-instance.
- `port_already_use`: Provoque une erreur sur le port en l'ouvrant avant le script d'install.  
	Le test` port_already_use` peut éventuellement prendre en argument un numéro de port. Si celui-ci n'est pas dans le manifest.  
	Le numéro de port doit alors être noté entre parenthèse, il servira au test de port.  
- `change_url`: Test le script change_url de 6 manières différentes, Root vers un path, path vers un autre path et path vers root. Et la même chose avec un autre domaine.
- `actions`: Toutes les actions disponible dans actions.toml
- `config_panel`: Toutes les configurations disponible dans config_panel.toml

### `;;; Levels`
Les [niveaux](https://yunohost.org/#/packaging_apps_levels_fr) 1 à 8 sont déterminés automatiquement.  
A l'exception du niveau 5, vous ne pouvez plus forcer une valeur pour un niveau.  
Le niveau 5 est déterminé par les résultats de [package linter](https://github.com/YunoHost/package_linter).  
La valeur par défaut pour ce niveau est `auto`, cependant, si nécessaire, vous pouvez forcer la valeur pour ce niveau en la fixant à `1`, pour un résultat positif, ou à `0`, pour un résultat négatif.  
Si vous le faites, veuillez ajouter un commentaire pour justifier pourquoi vous forcez ce niveau.

### `;;; Options`
Options supplémentaires disponible dans le check_process.  
Ces options sont facultatives.  

- `Email` : Permet d'indiquer un email alternatif à celui qui est présent dans le manifest pour les notifications de package check, lorsque celui-ci s'exécute en contexte d'intégration continue.
- `Notification` : Degré de notification souhaité pour l'application. Il y a 3 niveaux de notification disponible.
  - `down` : Envoi un mail seulement si le niveau de l'application a baissé.
  - `change` : Envoi un mail seulement si le niveau de l'application a changé.
  - `all` : Envoi un mail pour chaque test de l'application, quel que ce soit le résultat.

### `;;; Upgrade options`
*Instruction optionnelle*  
Pour chaque commit indiqué pour un upgrade, permet d'indiquer un nom pour cette version et les paramètres du manifest à utiliser lors de l'installation préliminaire.  
En cas d'absence de nom, le commit sera utilisé.  
De même en cas d'absence d'arguments pour le manifest, les arguments du check_process seront utilisés.  
> 3 variables doivent être utilisées pour les arguments du manifest, DOMAIN, PATH et USER.

---
Le script `package_check.sh` accepte 6 arguments en plus du package à tester.
- `--bash-mode`: Rend le script autonome. Aucune intervention de l'utilisateur ne sera nécessaire.  
	La valeur de auto_remove est ignorée.
- `--branch=nom-de-branche`: Teste une branche du dépôt plutôt que de tester master. Permet de tester les pull request.
- `--build-lxc`: Installe LXC et créer le conteneur debian Yunohost si nécessaire.
- `--force-install-ok`: Force la réussite des installations, même si elles échouent. Permet d'effectuer les tests qui suivent même si l'installation a échouée.
- `--interrupt`: Force l'option auto_remove à 0, le script marquera une pause avant chaque suppression d'application.
- `--help`: Affiche l'aide du script

---
## LXC

Package check utilise la virtualisation en conteneur pour assurer l'intégrité de l'environnement de test.  
L'usage de LXC apporte une meilleure stabilité au processus de test, un test de suppression échoué n'entraine pas l'échec des tests suivant, et permet de garder un environnement de test sans résidus de test précédents. En revanche, l'usage de LXC augmente la durée des tests, en raison des manipulations du conteneur et de la réinstallation systématique des dépendances de l'application.

Il faut prévoir également un espace suffisant sur l'hôte, au minimum 6Go pour le conteneur, ses snapshots et sa copie de sauvegarde.

L'usage de LXC est facilité par 4 scripts, permettant de gérer la création, la mise à jour, la suppression et la réparation du conteneur.
- `lxc_build.sh`: lxc_build installe LXC et ses dépendances, puis créer le conteneur debian.  
	Il ajoute ensuite le support réseau, installe YunoHost et le configure. Et enfin configure un accès ssh.  
	L'accès ssh par défaut est `ssh -t pchecker_lxc`
- `lxc_upgrade.sh`: Effectue la mise à jour du conteneur à l'aide d'apt-get et recréer le snapshot.
- `lxc_remove.sh`: Supprime le conteneur LXC, son snapshot et sa sauvegarde. Désinstalle LXC et déconfigure le réseau associé.
- `lxc_check.sh`: Vérifie le conteneur LXC et tente de le réparer si nécessaire.
