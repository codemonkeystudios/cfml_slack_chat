/**
 * Application lifecycle for the Slack-backed support chat.
 *
 * Services are stateless and live in the application scope. Visitor state does
 * not: a conversation belongs to a session and to the database, never to a scope
 * shared by every browser that happens to be connected.
 *
 * The configuration file's modification time is checked on each request. When it
 * changes, services are rebuilt. That is the reload mechanism, and it is why
 * saving the setup form takes effect without restarting the server.
 */
component {

	this.name = "cfmlSlackChat_" & hash( getCurrentTemplatePath() );
	this.applicationTimeout = createTimeSpan( 0, 6, 0, 0 );
	this.sessionManagement = true;
	this.sessionTimeout = createTimeSpan( 0, 1, 0, 0 );
	this.setClientCookies = true;
	this.clientManagement = false;
	this.scriptProtect = "none";

	this.mappings[ "/slackchat" ] = getDirectoryFromPath( getCurrentTemplatePath() );

	// HttpOnly always; Secure only when the request actually arrived over TLS,
	// because a Secure cookie on plain http is a cookie the browser discards.
	this.sessionCookie = {
		"httponly" : true,
		"samesite" : "Lax",
		"secure" : ( cgi.https ?: "off" ) == "on" || ( cgi.server_port_secure ?: "0" ) == "1"
	};

	/*
	 * The datasource is declared here rather than in the CFML administrator so
	 * that a clone-and-run test does not require a trip through a server admin
	 * console. When the operator prefers their own server-defined datasource this
	 * block is skipped and that name is used instead.
	 */
	// No var scope here: this block is the pseudo-constructor, not a function.
	try {
		variables.boot_config = new services.config_service();

		if ( variables.boot_config.getSetting( "database.mode" ) == "application"
		 && len( trim( variables.boot_config.getSetting( "database.host" ) ) )
		 && len( trim( variables.boot_config.getSetting( "database.database" ) ) ) ) {
			this.datasources[ "slackSupportChat" ] = variables.boot_config.buildDatasourceDefinition();
		}
	} catch ( any boot_error ) {
		// A broken configuration file must not make every page unreachable; the
		// setup page is how the operator fixes it.
		request.bootstrap_error = boot_error.message;
	}

	// ----------------------------------------------------------------- lifecycle

	public boolean function onApplicationStart() {
		bootstrapServices();
		return true;
	}

	public void function onSessionStart() {
		session.csrf_token = createUUID();
		session.conversations = {};
	}

	public boolean function onRequestStart( required string target_page ) {

		// CFML debugging output would corrupt the SSE stream, and every JSON
		// response on the way past.
		cfsetting( showdebugoutput = false );

		if ( isBlockedPath( arguments.target_page ) ) {
			cfheader( statuscode = 404, statustext = "Not Found" );
			writeOutput( "Not found." );
			return false;
		}

		if ( !structKeyExists( application, "slack_chat" ) || configurationChanged() ) {
			bootstrapServices();
		}

		if ( !structKeyExists( session, "csrf_token" ) ) {
			session.csrf_token = createUUID();
		}

		if ( !structKeyExists( session, "conversations" ) ) {
			session.conversations = {};
		}

		return true;
	}

	public void function onError( required any exception, string event_name = "" ) {

		var script_path = cgi.script_name ?: "";

		try {
			if ( structKeyExists( application, "slack_chat" ) && structKeyExists( application.slack_chat, "log" ) ) {
				var fields = { "path":script_path, "event_name":arguments.event_name };
				structAppend( fields, application.slack_chat.log.describeException( arguments.exception ) );
				application.slack_chat.log.error( "application.unhandled", fields );
			}
		} catch ( any ignored ) {
		}

		if ( left( script_path, 5 ) == "/api/" || left( script_path, 7 ) == "/slack/" || left( script_path, 8 ) == "/stream/" ) {
			cfheader( statuscode = 500, statustext = "Internal Server Error" );
			cfcontent( type = "application/json; charset=utf-8" );
			writeOutput( serializeJSON( {
				"ok" : false,
				"error" : {
					"code" : "internal_error",
					"message" : "The request could not be completed. Check logs/slack-chat.log for details."
				}
			} ) );
			return;
		}

		cfheader( statuscode = 500, statustext = "Internal Server Error" );
		writeOutput(
			"<!doctype html><html lang=""en""><head><meta charset=""utf-8""><title>Application error</title>"
			& "<link rel=""stylesheet"" href=""https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/css/bootstrap.min.css"" crossorigin=""anonymous""></head>"
			& "<body class=""container py-5""><div class=""alert alert-danger""><h1 class=""h4"">Something went wrong</h1>"
			& "<p class=""mb-0"">The details were written to <code>logs/slack-chat.log</code>. They are deliberately not printed here, "
			& "because exception dumps have a habit of containing exactly the thing you did not want on screen.</p></div>"
			& "<a class=""btn btn-primary"" href=""/"">Back to the application</a></body></html>"
		);
	}

	public boolean function onMissingTemplate( required string target_page ) {
		cfheader( statuscode = 404, statustext = "Not Found" );
		writeOutput( "Not found." );
		return true;
	}

	// ----------------------------------------------------------------- wiring

	/**
	 * Build every service that the current configuration allows.
	 *
	 * When the database or Slack settings are incomplete the application still
	 * starts; it reports itself as not ready and shows the setup page.
	 */
	private void function bootstrapServices() {

		lock name="#this.name#_bootstrap" type="exclusive" timeout="20" {

			var application_root = getDirectoryFromPath( getCurrentTemplatePath() );

			var slack_chat = {
				"ready" : false,
				"ready_reason" : "",
				"config_stamp" : "",
				"root" : application_root
			};

			var config_service = new services.config_service();

			slack_chat.config_service = config_service;
			slack_chat.config_stamp = buildConfigStamp( config_service );

			var config = config_service.getConfig();

			slack_chat.log = new services.log_service(
				log_directory = application_root & "logs",
				log_message_bodies = config.app.log_message_bodies
			);

			// Available even when configuration is incomplete: the endpoints still
			// have to be able to answer with a well formed error.
			slack_chat.api = new services.api_service( slack_chat.log );
			slack_chat.setup = new services.setup_service( config_service, slack_chat.log );

			if ( arrayLen( config_service.getMissingSettings() ) ) {
				slack_chat.ready_reason = "Configuration is incomplete.";
				application.slack_chat = slack_chat;
				return;
			}

			try {
				slack_chat.db = new services.database_service(
					datasource = config_service.getDatasourceName(),
					platform = config.database.type
				);

				slack_chat.slack = new services.slack_service(
					bot_token = config.slack.bot_token,
					signing_secret = config.slack.signing_secret,
					default_channel = config.slack.channel_id,
					log_service = slack_chat.log,
					timeout_seconds = config.app.slack_timeout_seconds,
					signature_max_age_seconds = config.app.signature_max_age_seconds,
					bot_user_id = config.slack.bot_user_id
				);

				slack_chat.conversations = new services.conversation_service(
					database_service = slack_chat.db,
					log_service = slack_chat.log,
					max_message_length = config.app.max_message_length
				);

				slack_chat.deliveries = new services.slack_delivery_service(
					database_service = slack_chat.db,
					slack_service = slack_chat.slack,
					conversation_service = slack_chat.conversations,
					log_service = slack_chat.log
				);

				slack_chat.events = new services.slack_event_service(
					database_service = slack_chat.db,
					slack_service = slack_chat.slack,
					conversation_service = slack_chat.conversations,
					log_service = slack_chat.log,
					configured_channel_id = config.slack.channel_id,
					configured_app_id = config.slack.app_id
				);

				slack_chat.stream = new services.event_stream_service(
					conversation_service = slack_chat.conversations,
					slack_event_service = slack_chat.events,
					slack_delivery_service = slack_chat.deliveries,
					log_service = slack_chat.log,
					max_seconds = config.app.sse_max_seconds,
					poll_milliseconds = config.app.sse_poll_milliseconds,
					auto_process_events = config.app.auto_process_events
				);

				var schema = slack_chat.db.getSchemaStatus();

				if ( !schema.reachable ) {
					slack_chat.ready_reason = "The configured datasource is not reachable.";
				} else if ( arrayLen( schema.missing ) ) {
					slack_chat.ready_reason = "These tables are missing: " & arrayToList( schema.missing, ", " ) & ".";
				} else {
					slack_chat.ready = true;
				}

			} catch ( any e ) {
				slack_chat.ready_reason = e.message;
			}

			application.slack_chat = slack_chat;
		}
	}

	private boolean function configurationChanged() {

		try {
			return application.slack_chat.config_stamp != buildConfigStamp( application.slack_chat.config_service );
		} catch ( any e ) {
			return true;
		}
	}

	private string function buildConfigStamp( required any config_service ) {

		var config_path = arguments.config_service.getConfigFilePath();

		if ( !fileExists( config_path ) ) {
			return "absent";
		}

		var file_info = getFileInfo( config_path );

		return file_info.lastmodified & "|" & file_info.size;
	}

	/**
	 * Belt and braces alongside the server.json rules: service components, SQL
	 * scripts, logs and the configuration directory are not web resources and
	 * should never be served, whichever web server happens to be in front.
	 */
	private boolean function isBlockedPath( required string target_page ) {

		var normalised_path = lCase( replace( arguments.target_page, "\", "/", "all" ) );

		for ( var prefix in [ "/services/", "/tasks/", "/config/", "/sql/", "/logs/", "/.config/" ] ) {
			if ( find( prefix, normalised_path ) == 1 ) {
				return true;
			}
		}

		// Direct component invocation is not part of this application's surface.
		if ( right( normalised_path, 4 ) == ".cfc" && normalised_path != "/application.cfc" ) {
			return true;
		}

		return false;
	}

}
