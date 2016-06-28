Package checker for YunoHost
==================

[Yunohost project](https://yunohost.org/#/)

Ensemble de tests unitaires pour vérifier les packages Yunohost.  
Le script `package_check.sh` effectue une succession de test sur un package afin de vérifier sa capacité à s'installer et se désinstaller dans différents cas.  
Le résultats des tests est affiché directement et stocké dans le fichier Test_results.log

Le script est capable d'effectuer les tests suivant:
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

> ATTENTION: Ce script devrait être utilisé uniquement dans un environnement de test dédié. Jamais sur un serveur en production. Il va provoquer de nombreuses erreurs d'installation du package et pourrait donc laisser des résidus indésirables.

Usage:  
Pour une app dans un dossier: `./package_check.sh APP_ynh`  
Pour une app sur github: `./package_check.sh https://github.com/USER/APP_ynh`

Il est nécessaire de fournir, à la racine du package de l'app à tester, un fichier `check_process` pour indiquer au script les arguments attendu et les tests à effectuer.

---
## Syntaxe du fichier `check_process`
> A l'exception des espaces, la syntaxe du fichier doit être scrupuleusement respectée.
> L'ordre des lignes n'a toutefois pas d'importance.

```
## Nom du test
	auto_remove=1
	# Manifest
		domain="$DOMAIN"	(DOMAIN)
		path="$PATH"	(PATH)
		admin="$USER"	(USER)
		language="fr"
		is_public="Yes"	(PUBLIC|public=Yes|private=No)
		password="$PASSWORD"	(PASSWORD)
		port="666"	(PORT)
	# Checks
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
		port_already_use=1
		final_path_already_use=0
```
### `## Nom du test`
Nom du scénario de test qui sera effectué.  
On peut créer autant de scénario de test que voulu, tous ayant la même syntaxe.  
Les différents scénarios de test seront exécutés successivement.

### `auto_remove`
Si `auto_remove` est à 0, le script marque une pause avant chaque suppression de l'app. Afin d'éffectuer des vérifications manuelles si nécessaire.  
Sinon, l'app est supprimée automatiquement et les tests continuent.

### `# Manifest`
Ensemble des clés du manifest.  
Toutes les clés du manifest doivent être renseignée afin de procéder à l'installation.
> Les clés de manifest données ici ne le sont qu'à titre d'exemple. Voir le manifest de l'application.
Certaines clés de manifest sont indispensables au script pour effectuer certains test. Ces clés doivent être mises en évidence afin que le script soit capable de les retrouver et de changer leur valeur.  
`(DOMAIN)`, `(PATH)`, `(USER)`, `(PASSWORD)` et `(PORT)` doivent être mis en bout de ligne des clés correspondantes. Ces clés seront modifiées par le script.  
`(PUBLIC|public=Yes|private=No)` doit, en plus de correspondre à la clé de visibilité public, indiquer les valeurs du manifest pour public et privé.

### `# Checks`
Ensemble des tests à effectuer.  
Chaque test marqué à 1 sera effectué par le script.  
Si un test est absent de la liste, il sera ignoré. Cela revient à le noter à 0.
