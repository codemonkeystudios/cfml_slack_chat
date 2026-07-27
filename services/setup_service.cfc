/**
 * Configuration diagnostics.
 *
 * Answers the only question that matters on the setup page: if you press Send
 * right now, which specific thing breaks?
 *
 * Every check is non-destructive. Nothing here writes a test message into the
 * support channel, because "it works" and "the channel now contains the word
 * test seventeen times" should not be the same event.
 */
component accessors="false" {

	public setup_service function init( required any config_service, required any log_service ) {
		variables.config_service = arguments.config_service;
		variables.log = arguments.log_service;
		return this;
	}

	/**
	 * Run every check and return { overall, checks, database_usable }.
	 * Each check is { id, label, status, message } where status is one of pass,
	 * fail, warn or skip.
	 */
	public struct function runDiagnostics() {

		var checks = [];
		var config = variables.config_service.getConfig();

		// -------------------------------------------------- required settings
		var missing = variables.config_service.getMissingSettings();

		if ( arrayLen( missing ) ) {

			var labels = [];

			for ( var item in missing ) {
				arrayAppend( labels, item.label );
			}

			arrayAppend( checks, buildCheck( "settings", "Required settings", "fail",
				"Still missing: " & arrayToList( labels, ", " ) & "." ) );
		} else {
			arrayAppend( checks, buildCheck( "settings", "Required settings", "pass",
				"Every required value is present." ) );
		}

		// --------------------------------------------------------- signing secret
		var signing_secret = config.slack.signing_secret;

		if ( !len( signing_secret ) ) {
			arrayAppend( checks, buildCheck( "signing_secret", "Signing secret", "fail",
				"No signing secret is configured, so every inbound Slack event will be rejected as unverifiable." ) );
		} else if ( !reFind( "^[a-fA-F0-9]{16,}$", signing_secret ) ) {
			arrayAppend( checks, buildCheck( "signing_secret", "Signing secret", "warn",
				"The signing secret is present but does not look like Slack's 32 character hexadecimal value. Verification will fail if it is wrong." ) );
		} else {
			arrayAppend( checks, buildCheck( "signing_secret", "Signing secret", "pass",
				"Present and plausibly formatted." ) );
		}

		// -------------------------------------------------------------- database
		var database_usable = false;

		try {
			var database_service = buildDatabaseService( config );
			var schema = database_service.getSchemaStatus();

			if ( !schema.reachable ) {
				arrayAppend( checks, buildCheck( "datasource", "Datasource", "fail",
					"The datasource could not be reached. " & redactSecrets( schema.error ) ) );
			} else {
				arrayAppend( checks, buildCheck( "datasource", "Datasource", "pass",
					"Connected using the " & schema.platform & " configuration." ) );

				if ( arrayLen( schema.missing ) ) {
					arrayAppend( checks, buildCheck( "schema", "Database tables", "fail",
						"The datasource is reachable, but these tables do not exist: "
						& arrayToList( schema.missing, ", " )
						& ". Run sql/" & scriptNameFor( schema.platform ) & " against your database." ) );
				} else {
					database_usable = true;
					arrayAppend( checks, buildCheck( "schema", "Database tables", "pass",
						"All four tables are present." ) );
				}
			}
		} catch ( any e ) {
			arrayAppend( checks, buildCheck( "datasource", "Datasource", "fail", safeMessage( e ) ) );
		}

		// ----------------------------------------------------------------- Slack
		var auth_result = {};

		if ( !len( config.slack.bot_token ) ) {
			arrayAppend( checks, buildCheck( "slack_auth", "Slack authentication", "skip",
				"No bot token to test yet." ) );
		} else {
			try {
				var slack_service = buildSlackService( config );
				auth_result = slack_service.authTest();

				arrayAppend( checks, buildCheck( "slack_auth", "Slack authentication", "pass",
					"Authenticated as " & ( auth_result.user ?: "the bot" )
					& " in workspace " & ( auth_result.team ?: "unknown" ) & "." ) );

				// Remember the bot user ID so the processor can recognise and
				// ignore this application's own messages.
				if ( len( trim( auth_result.user_id ?: "" ) ) ) {
					variables.config_service.saveDerived( "slack.bot_user_id", auth_result.user_id );
				}
				if ( len( trim( auth_result.team_id ?: "" ) ) && !len( trim( config.slack.team_id ) ) ) {
					variables.config_service.saveDerived( "slack.team_id", auth_result.team_id );
				}

			} catch ( any e ) {
				arrayAppend( checks, buildCheck( "slack_auth", "Slack authentication", "fail", safeMessage( e ) ) );
			}
		}

		// --------------------------------------------------------------- channel
		if ( !len( config.slack.bot_token ) || !len( config.slack.channel_id ) || structIsEmpty( auth_result ) ) {
			arrayAppend( checks, buildCheck( "slack_channel", "Slack channel", "skip",
				"Needs a working bot token and a channel ID before it can be checked." ) );
		} else {
			try {
				var channel_slack_service = buildSlackService( config );
				var channel_info = channel_slack_service.conversationsInfo( config.slack.channel_id );
				var channel = channel_info.channel ?: {};
				var channel_label = len( trim( channel.name ?: "" ) ) ? "##" & channel.name : config.slack.channel_id;

				if ( isBoolean( channel.is_archived ?: false ) && ( channel.is_archived ?: false ) ) {
					arrayAppend( checks, buildCheck( "slack_channel", "Slack channel", "fail",
						"Channel " & channel_label & " is archived. Slack will not accept new messages in it." ) );
				} else if ( structKeyExists( channel, "is_member" ) && !channel.is_member ) {
					arrayAppend( checks, buildCheck( "slack_channel", "Slack channel", "fail",
						"The bot can authenticate but is not a member of channel " & config.slack.channel_id
						& ". Invite it from inside Slack with /invite @your-bot-name." ) );
				} else {
					arrayAppend( checks, buildCheck( "slack_channel", "Slack channel", "pass",
						"The bot is a member of " & channel_label & "." ) );
				}

			} catch ( any e ) {
				arrayAppend( checks, buildCheck( "slack_channel", "Slack channel", "fail", safeMessage( e ) ) );
			}
		}

		// ------------------------------------------------------------ public URL
		var public_base_url = trim( config.app.public_base_url );

		if ( !len( public_base_url ) ) {
			arrayAppend( checks, buildCheck( "public_url", "Public Events URL", "warn",
				"No public base URL is set. Customer messages will still reach Slack, but replies cannot come back until Slack has somewhere to call." ) );
		} else if ( !reFindNoCase( "^https://", public_base_url ) && !config.app.allow_insecure_public_url ) {
			arrayAppend( checks, buildCheck( "public_url", "Public Events URL", "fail",
				"The Events API requires a publicly reachable HTTPS endpoint. Start a tunnel and use the address it prints." ) );
		} else if ( !reFindNoCase( "^https://", public_base_url ) ) {
			arrayAppend( checks, buildCheck( "public_url", "Public Events URL", "warn",
				"Local-only mode is on, so the URL check is relaxed. Slack will not be able to deliver events to this address." ) );
		} else {
			arrayAppend( checks, buildCheck( "public_url", "Public Events URL", "pass",
				"Slack should send events to " & variables.config_service.getEventsRequestUrl() ) );
		}

		var overall = "pass";

		for ( var result in checks ) {
			if ( result.status == "fail" ) {
				overall = "fail";
				break;
			}
			if ( result.status == "warn" && overall == "pass" ) {
				overall = "warn";
			}
		}

		return { "overall":overall, "checks":checks, "database_usable":database_usable };
	}

	// --------------------------------------------------------------- internals

	private any function buildDatabaseService( required struct config ) {

		var datasource_name = variables.config_service.getDatasourceName();

		if ( !len( trim( datasource_name ) ) ) {
			throw( type = "Configuration.Invalid", message = "No datasource has been configured yet." );
		}

		return new database_service( datasource_name, arguments.config.database.type );
	}

	private any function buildSlackService( required struct config ) {
		return new slack_service(
			bot_token = arguments.config.slack.bot_token,
			signing_secret = arguments.config.slack.signing_secret,
			default_channel = arguments.config.slack.channel_id,
			log_service = variables.log,
			timeout_seconds = arguments.config.app.slack_timeout_seconds,
			signature_max_age_seconds = arguments.config.app.signature_max_age_seconds,
			bot_user_id = arguments.config.slack.bot_user_id
		);
	}

	private struct function buildCheck(
		required string id,
		required string label,
		required string status,
		required string message
	) {
		return { "id":arguments.id, "label":arguments.label, "status":arguments.status, "message":arguments.message };
	}

	/**
	 * Exception text for the setup page. Slack and JDBC messages are safe to show
	 * here; the detail field is not, because JDBC drivers cheerfully put the
	 * connection URL, and sometimes the credentials, inside it.
	 */
	private string function safeMessage( required any exception ) {
		return redactSecrets( arguments.exception.message ?: "Something failed without saying what." );
	}

	private string function redactSecrets( required string text ) {

		var clean = reReplaceNoCase( arguments.text, "xox[bpears]-[A-Za-z0-9\-]+", "[redacted token]", "all" );
		clean = reReplaceNoCase( clean, "password=[^;& ]*", "password=[redacted]", "all" );

		return clean;
	}

	private string function scriptNameFor( required string platform ) {

		var script_names = { "postgresql":"postgresql.sql", "mysql":"mysql.sql", "sqlserver":"sqlserver.sql" };

		return script_names[ arguments.platform ] ?: "postgresql.sql";
	}

}
