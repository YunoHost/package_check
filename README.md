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

Par défaut, Package checker utilise un conteneur LXC pour créer un environnement de test propre sans résidus d'installations précédentes. Ce comportement peut être contourné avec le paramètre --no-lxc
> ATTENTION: Si LXC n'est pas utilisé, le script devrait être utilisé uniquement dans un environnement de test dédié, jamais sur un serveur en production. Il va provoquer de nombreuses erreurs d'installation du package et pourrait donc laisser des résidus indésirables.

Usage:  
Pour une app dans un dossier: `./package_check.sh APP_ynh`  
Pour une app sur github: `./package_check.sh https://github.com/USER/APP_ynh`

Il est nécessaire de fournir, à la racine du package de l'app à tester, un fichier `check_process` pour indiquer au script les arguments attendu et les tests à effectuer.

---
## Syntaxe du fichier `check_process`
> A l'exception des espaces, la syntaxe du fichier doit être scrupuleusement respectée.
> L'ordre des lignes n'a toutefois pas d'importance.

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
- `multi_instance`: Installation de l'application 2 fois de suite, pour vérifier sa capacité à être multi-instance.
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
Le script `package_check.sh` accepte 3 arguments en plus du package à tester.
- `--bash-mode`: Rend le script autonome. Aucune intervention de l'utilisateur ne sera nécessaire.  
	La valeur de auto_remove est ignorée. (Incompatible avec --build-lxc)
- `--no-lxc`: N'utilise pas la virtualisation en conteneur LXC. Les tests seront effectué directement sur la machine hôte.
- `--build-lxc`: Installe LXC et créer le conteneur debian Yunohost si nécessaire. (Incompatible avec --bash-mode)

---
## LXC

Package checker utilise la virtualisation en conteneur pour assurer l'intégrité de l'environnement de test.  
L'usage de LXC apporte une meilleure stabilité au processus de test, un test de suppression échoué n'entraine pas l'échec des tests suivant, et permet de garder un environnement de test sans résidus de test précédents. En revanche, l'usage de LXC augmente la durée des tests, en raison des manipulations du conteneur et de la réinstallation systématique des dépendances de l'application.

Il faut prévoir également un espace suffisant sur l'hôte, au minimum 4Go pour le conteneur, son snapshot et sa copie de sauvegarde.

L'usage de LXC est facilité par 3 scripts, permettant de gérer la création, la mise à jour et la suppression.
- `lxc_build.sh`: lxc_build installe LXC et ses dépendances, puis créer le conteneur debian.  
	Il ajoute ensuite le support réseau, installe Yunohost et le configure. Et enfin configure un accès ssh.  
	L'accès ssh par défaut est `ssh -t pchecker_lxc`
- `lxc_upgrade.sh`: Effectue la mise à jour du conteneur à l'aide d'apt-get et recréer le snapshot.
- `lxc_remove.sh`: Supprime le conteneur LXC, son snapshot et sa sauvegarde. Désinstalle LXC et déconfigure le réseau associé.
