Package checker for YunoHost
==================

[Yunohost project](https://yunohost.org/#/)

Une ébauche d'un script pour automatiser les tests d'installation des packages Yunohost

Usage:  
Pour une app dans un dossier: `package_check.sh APP_ynh`
Pour une app sur github: `package_check.sh https://github.com/USER/APP_ynh`

Il est nécessaire de fournir dans le package de l'app un fichier `check_process` pour indiquer au script les arguments attendu et les tests à effectuer.
