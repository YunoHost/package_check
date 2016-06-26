OUTPUTD="debug_output"

SETUP_APP () {
	sudo yunohost app --debug install $APP_CHECK -a "$MANIFEST_ARGS" > $OUTPUTD 2>&1
}

REMOVE_APP () {
# Il faut choper le label pour savoir quoi supprimer...

}

TESTING_PROCESS () {
	# Lancement des tests
	echo "PROCESS_NAME=$PROCESS_NAME"
	echo "MANIFEST_ARGS=$MANIFEST_ARGS"

	SETUP_APP
}
