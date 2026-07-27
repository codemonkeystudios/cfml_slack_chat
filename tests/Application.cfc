/**
 * Application context for the test suite.
 *
 * Deliberately separate from the application's own Application.cfc: the specs
 * build the services they need with the arguments they want, rather than
 * inheriting whatever the running application happens to be configured with.
 */
component {

	this.name = "cfmlSlackChatTests_" & hash( getCurrentTemplatePath() );
	this.sessionManagement = false;
	this.setClientCookies = false;

	// <root>/tests/ -> <root>/. getCanonicalPath resolves the "..", which nesting
	// getDirectoryFromPath does not: given a path already ending in a separator
	// it has no filename left to strip and returns the same directory again.
	variables.repository_root = getCanonicalPath( getDirectoryFromPath( getCurrentTemplatePath() ) & ".." );

	if ( right( variables.repository_root, 1 ) != "/" ) {
		variables.repository_root &= "/";
	}

	this.mappings[ "/slackchat" ] = variables.repository_root;
	this.mappings[ "/testbox" ] = variables.repository_root & "testbox";
	this.mappings[ "/tests" ] = variables.repository_root & "tests";

	/*
	 * The integration suites need the same datasource the application uses, and
	 * a datasource declared by one Application.cfc is not visible to another.
	 * When the settings are incomplete this is skipped and those suites skip
	 * with it.
	 */
	try {
		// Resolved through the server's default root mapping rather than
		// /slackchat: mappings declared above are not active yet inside the
		// pseudo-constructor that declares them.
		variables.test_config = createObject( "component", "services.config_service" ).init();

		if ( variables.test_config.getSetting( "database.mode" ) == "application"
		 && len( trim( variables.test_config.getSetting( "database.host" ) ) )
		 && len( trim( variables.test_config.getSetting( "database.database" ) ) ) ) {
			this.datasources[ "slackSupportChat" ] = variables.test_config.buildDatasourceDefinition();
		}
	} catch ( any test_config_error ) {
		request.test_config_error = test_config_error.message;
	}

	public boolean function onRequestStart( required string target_page ) {
		cfsetting( showdebugoutput = false );
		return true;
	}

}
