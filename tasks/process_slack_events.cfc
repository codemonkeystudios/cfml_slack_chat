/**
 * CommandBox task: drain the Slack event inbox and the outbound delivery queue.
 *
 * box task run taskFile=tasks/process_slack_events
 * box task run taskFile=tasks/process_slack_events --watch
 *
 * Run it from the repository root, which is where it looks for the components
 * and the configuration file.
 *
 * This runs outside the CFML server, in CommandBox's own engine, so it cannot
 * borrow a datasource the server has defined. Instead it builds a Lucee
 * datasource struct from the same configuration the application uses. That means
 * it needs application-managed database settings; if you configured an existing
 * server datasource by name, the task says so plainly rather than failing with
 * something cryptic about a missing datasource.
 */
component {

	/**
	 * @watch Keep running, sweeping on an interval, until interrupted.
	 * @interval Seconds between sweeps in watch mode.
	 * @max_events Maximum inbox events to claim per sweep.
	 * @max_deliveries Maximum outbound deliveries to attempt per sweep.
	 * @config_file Override the configuration file location.
	 */
	function run(
		boolean watch = false,
		numeric interval = 5,
		numeric max_events = 25,
		numeric max_deliveries = 25,
		string config_file = ""
	) {

		var services = {};

		try {
			services = buildServices( arguments.config_file );
		} catch ( any startup_error ) {
			error( startup_error.message );
			return;
		}

		print.line( "Slack event processor" ).toConsole();
		print.grayLine( " database : " & services.platform ).toConsole();
		print.grayLine( " channel : " & services.channel_id ).toConsole();
		print.grayLine( " log file : " & services.log.getLogFile() ).toConsole();
		print.line().toConsole();

		if ( !arguments.watch ) {
			sweep( services, arguments.max_events, arguments.max_deliveries );
			return;
		}

		print.yellowLine( "Watching. Press Ctrl+C to stop." ).line().toConsole();

		while ( true ) {
			sweep( services, arguments.max_events, arguments.max_deliveries );
			sleep( arguments.interval * 1000 );
		}
	}

	// --------------------------------------------------------------- internals

	private void function sweep( required struct services, required numeric max_events, required numeric max_deliveries ) {

		try {
			var event_summary = arguments.services.events.processPendingEvents( arguments.max_events );

			print.line(
				"events claimed=" & event_summary.claimed
				& " processed=" & event_summary.processed
				& " ignored=" & event_summary.ignored
				& " retrying=" & event_summary.retrying
				& " failed=" & event_summary.failed
			).toConsole();

		} catch ( any event_error ) {
			print.redLine( "events failed: " & event_error.message ).toConsole();
		}

		try {
			var delivery_summary = arguments.services.deliveries.processPendingDeliveries( "", arguments.max_deliveries );

			print.line(
				"deliveries claimed=" & delivery_summary.claimed
				& " sent=" & delivery_summary.sent
				& " deferred=" & delivery_summary.deferred
				& " failed=" & delivery_summary.failed
			).toConsole();

		} catch ( any delivery_error ) {
			print.redLine( "deliveries failed: " & delivery_error.message ).toConsole();
		}
	}

	/**
	 * Wire the same services the web application uses, against a standalone
	 * datasource struct rather than a server-defined datasource name.
	 */
	private struct function buildServices( required string config_file ) {

		installMapping();

		var config_service = createObject( "component", "slackchat.services.config_service" ).init( resolveConfigFile( arguments.config_file ) );
		var config = config_service.getConfig();
		var missing = config_service.getMissingSettings();

		if ( arrayLen( missing ) ) {

			var labels = [];

			for ( var item in missing ) {
				arrayAppend( labels, item.label );
			}

			throw(
				type = "Configuration.Invalid",
				message = "Configuration is incomplete. Missing: " & arrayToList( labels, ", " )
				 & ". Open the application in a browser and finish setup, or set the environment variables."
			);
		}

		var log_service = createObject( "component", "slackchat.services.log_service" ).init(
			log_directory = getRepositoryRoot() & "logs",
			log_message_bodies = config.app.log_message_bodies
		);

		var database_service = createObject( "component", "slackchat.services.database_service" ).init(
			datasource = config_service.buildStandaloneDatasource(),
			platform = config.database.type
		);

		database_service.requireSchema();

		var slack_service = createObject( "component", "slackchat.services.slack_service" ).init(
			bot_token = config.slack.bot_token,
			signing_secret = config.slack.signing_secret,
			default_channel = config.slack.channel_id,
			log_service = log_service,
			timeout_seconds = config.app.slack_timeout_seconds,
			signature_max_age_seconds = config.app.signature_max_age_seconds,
			bot_user_id = config.slack.bot_user_id
		);

		var conversation_service = createObject( "component", "slackchat.services.conversation_service" ).init(
			database_service = database_service,
			log_service = log_service,
			max_message_length = config.app.max_message_length
		);

		var delivery_service = createObject( "component", "slackchat.services.slack_delivery_service" ).init(
			database_service = database_service,
			slack_service = slack_service,
			conversation_service = conversation_service,
			log_service = log_service
		);

		var event_service = createObject( "component", "slackchat.services.slack_event_service" ).init(
			database_service = database_service,
			slack_service = slack_service,
			conversation_service = conversation_service,
			log_service = log_service,
			configured_channel_id = config.slack.channel_id,
			configured_app_id = config.slack.app_id
		);

		return {
			"log" : log_service,
			"events" : event_service,
			"deliveries" : delivery_service,
			"platform" : config.database.type,
			"channel_id" : config.slack.channel_id
		};
	}

	/**
	 * Register a mapping to the repository root.
	 *
	 * A CommandBox task runs in CommandBox's own CFML engine, whose working
	 * directory is wherever the operator invoked box from. Rather than depend on
	 * that, the task points a mapping at its own location on disk.
	 */
	private void function installMapping() {

		var app_mappings = getApplicationSettings().mappings ?: {};

		app_mappings[ "/slackchat" ] = getRepositoryRoot();

		application action="update" mappings="#app_mappings#";
	}

	/**
	 * Decide which configuration file to read.
	 *
	 * expandPath("/") inside a CommandBox task points at CommandBox, not at this
	 * repository, so the usual default would look in the wrong place entirely.
	 * Precedence is unchanged: an explicit argument, then the environment
	 * variable, then this repository's own .config directory.
	 */
	private string function resolveConfigFile( required string config_file ) {

		if ( len( trim( arguments.config_file ) ) ) {
			return arguments.config_file;
		}

		var environment_path = server.system.environment.SLACK_CHAT_CONFIG_FILE ?: "";

		if ( len( trim( environment_path ) ) ) {
			return environment_path;
		}

		return getRepositoryRoot() & ".config/config.json";
	}

	private string function getRepositoryRoot() {

		// This file lives in <root>/tasks/, so the root is one level up.
		// getCanonicalPath resolves the "..": nesting getDirectoryFromPath does not,
		// because a path already ending in a separator has no filename left to strip.
		var root = getCanonicalPath( getDirectoryFromPath( getCurrentTemplatePath() ) & ".." );

		return right( root, 1 ) == "/" ? root : root & "/";
	}

}
