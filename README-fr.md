Package checker for YunoHost
==================

[Yunohost project](https://yunohost.org/#/)

> [Read this readme in english](README.md)

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
- Test de path mal formé (path/ au lieu de /path)
- Test de port déjà utilisé
- Test du script change_url

Package check utilise un conteneur LXC pour créer un environnement de test propre sans résidus d'installations précédentes.

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
# Commentaire ignoré
	; Manifest
		domain="domain.tld"	(DOMAIN)
		path="/path"	(PATH)
		admin="john"	(USER)
		language="fr"
		is_public=1	(PUBLIC|public=1|private=0)
		password="password"
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
### `;; Nom du test`
Nom du scénario de test qui sera effectué.  
On peut créer autant de scénario de test que voulu, tous ayant la même syntaxe.  
Les différents scénarios de test seront exécutés successivement.

### `; Manifest`
Ensemble des clés du manifest.  
Toutes les clés du manifest doivent être renseignée afin de procéder à l'installation.
> Les clés de manifest données ici ne le sont qu'à titre d'exemple. Voir le manifest de l'application.
Certaines clés de manifest sont indispensables au script pour effectuer certains test. Ces clés doivent être mises en évidence afin que le script soit capable de les retrouver et de changer leur valeur.  
`(DOMAIN)`, `(PATH)`, `(USER)` et `(PORT)` doivent être mis en bout de ligne des clés correspondantes. Ces clés seront modifiées par le script.  
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
- `incorrect_path`: Provoque une erreur avec un path malformé, path/.
- `port_already_use`: Provoque une erreur sur le port en l'ouvrant avant le script d'install.  
	Le test` port_already_use` peut éventuellement prendre en argument un numéro de port. Si celui-ci n'est pas dans le manifest.  
	Le numéro de port doit alors être noté entre parenthèse, il servira au test de port.  
- `change_url`: Test le script change_url de 6 manières différentes, Root vers un path, path vers un autre path et path vers root. Et la même chose avec un autre domaine.

### `;;; Levels`
Permet de choisir comment [chaque niveau](https://yunohost.org/#/packaging_apps_levels_fr) est déterminé.  
Chaque niveau fixé à *auto* sera déterminé par le script. Il est également possible de fixer le niveau à *1* ou à *0* pour respectivement le valider ou l'invalider.  
Il est à noter que les niveaux 4, 8, 9 et 10 ne peuvent être fixés à *auto* car ils ne peuvent être testés par le script et nécessitent une vérification manuelle. Il est toutefois possible de les fixer à *na* pour indiquer que le niveau n'est pas applicable (par exemple pour le niveau 4 quand une app ne propose pas de SSO LDAP). Un niveau *na* sera tout simplement ignoré dans le calcul du niveau final.

Pour le forçage des niveaux, merci d’ajouter, avant la déclaration du niveau, un commentaire contenant un lien vers un ticket qui explique pourquoi le niveau a été forcé.
Comme :
```
# https://github.com/YunoHost-Apps/$app_ynh/issues/5
Level 4=1
```

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

### `;;; Options`
Options supplémentaires disponible dans le check_process.  
Ces options sont facultatives.  

- `Email` : Permet d'indiquer un email alternatif à celui qui est présent dans le manifest pour les notifications de package check, lorsque celui-ci s'exécute en contexte d'intégration continue.
- `Notification` : Degré de notification souhaité pour l'application. Il y a 3 niveaux de notification disponible.
  - `down` : Envoi un mail seulement si le niveau de l'application a baissé.
  - `change` : Envoi un mail seulement si le niveau de l'application a changé.
  - `all` : Envoi un mail pour chaque test de l'application, quel que ce soit le résultat.

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

Il faut prévoir également un espace suffisant sur l'hôte, au minimum 4Go pour le conteneur, son snapshot et sa copie de sauvegarde.

L'usage de LXC est facilité par 4 scripts, permettant de gérer la création, la mise à jour, la suppression et la réparation du conteneur.
- `lxc_build.sh`: lxc_build installe LXC et ses dépendances, puis créer le conteneur debian.  
	Il ajoute ensuite le support réseau, installe Yunohost et le configure. Et enfin configure un accès ssh.  
	L'accès ssh par défaut est `ssh -t pchecker_lxc`
- `lxc_upgrade.sh`: Effectue la mise à jour du conteneur à l'aide d'apt-get et recréer le snapshot.
- `lxc_remove.sh`: Supprime le conteneur LXC, son snapshot et sa sauvegarde. Désinstalle LXC et déconfigure le réseau associé.
- `lxc_check.sh`: Vérifie le conteneur LXC et tente de le réparer si nécessaire.
