#!/bin/bash

# Ce patch détecte l'erreur "L'exécution du script ne s'est pas terminée", Bug #654 (https://dev.yunohost.org/issues/654)
# Il permet, en cas d'erreur, de relancer le test qui vient d'échouer.
# En attendant de trouver la source de cette erreur, ce patch permet de soulager les tests de CI qui virent irrémédiablement au rouge en raison de la forte fréquence de ce bug.

patchlog="$script_dir/temppatchlog654"

export lprogress=0

PATCH_654 () {
	sudo tail -n +$lprogress "$COMPLETE_LOG" > "$patchlog"	# Copie le fichier de log à partir de la dernière ligne du log préexistant
	lprogress=$(sudo wc -l "$COMPLETE_LOG" | cut -d ' ' -f 1)	# Compte le nombre de ligne du log complet
	lprogress=$(( $lprogress + 1 ))	# Ignore la première ligne, reprise de l'ancien log.

	if grep -q "L'exécution du script .* ne s'est pas terminée" "$patchlog"; then
		return 1
	elif grep -q "Script execution hasn’t terminated:" "$patchlog"; then
		return 1
	elif grep -q "La ejecución del script no ha terminado:" "$patchlog"; then
		return 1
	elif grep -q "Skriptausführung noch nicht beendet" "$patchlog"; then
		return 1
	fi
	return 0
}
