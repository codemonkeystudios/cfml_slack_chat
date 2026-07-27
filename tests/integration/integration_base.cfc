/**
 * Shared setup for specs that need a real database.
 *
 * Uses the same configuration the application uses, so these run against
 * whichever of the three supported databases you have configured. When no usable
 * database is available the suites skip rather than fail: a missing test
 * database is a missing test database, not a broken application.
 *
 * Every spec cleans up the rows it created, in foreign-key order.
 */
component extends="testbox.system.BaseSpec" {

	variables.channel_id = "C0TESTCHANNEL";

	/**
	 * True when the integration suites cannot run.
	 *
	 * Called from run(), which TestBox executes during the declaration phase —
	 * before beforeAll() — so the services are built on first use rather than in
	 * a lifecycle hook that has not happened yet.
	 */
	private boolean function integrationSkipped() {

		if ( !structKeyExists( variables, "database_available" ) ) {
			setUpServices();
		}

		return !variables.database_available;
	}

	private string function skipReason() {
		integrationSkipped();
		return variables.skip_reason;
	}

	/** Build the service graph. Returns false when no database is available. */
	private boolean function setUpServices() {

		variables.created_conversation_ids = [];
		variables.created_event_ids = [];
		variables.database_available = false;
		variables.skip_reason = "";

		try {
			variables.config_service = new slackchat.services.config_service();

			var config = variables.config_service.getConfig();

			if ( !len( trim( variables.config_service.getDatasourceName() ) ) ) {
				variables.skip_reason = "No datasource is configured.";
				return false;
			}

			variables.log = new tests.support.null_log_service();

			variables.db = new slackchat.services.database_service(
				datasource = variables.config_service.getDatasourceName(),
				platform = config.database.type
			);

			var schema = variables.db.getSchemaStatus();

			if ( !schema.reachable ) {
				variables.skip_reason = "The configured datasource is not reachable: " & schema.error;
				return false;
			}

			if ( arrayLen( schema.missing ) ) {
				variables.skip_reason = "Missing tables: " & arrayToList( schema.missing, ", " );
				return false;
			}

			variables.slack = new tests.support.stub_slack_service( default_channel = variables.channel_id );

			variables.conversations = new slackchat.services.conversation_service(
				database_service = variables.db,
				log_service = variables.log,
				max_message_length = 4000
			);

			variables.deliveries = new slackchat.services.slack_delivery_service(
				database_service = variables.db,
				slack_service = variables.slack,
				conversation_service = variables.conversations,
				log_service = variables.log
			);

			variables.events = new slackchat.services.slack_event_service(
				database_service = variables.db,
				slack_service = variables.slack,
				conversation_service = variables.conversations,
				log_service = variables.log,
				configured_channel_id = variables.channel_id,
				configured_app_id = ""
			);

			variables.database_available = true;
			return true;

		} catch ( any setup_error ) {
			variables.skip_reason = setup_error.message;
			return false;
		}
	}

	/** Create a conversation and remember it for cleanup. */
	private struct function createTestConversation(
		string visitor_name = "Test Visitor",
		string visitor_email = "test.visitor@example.com",
		string body = "The export fails at ninety percent."
	) {

		var created = variables.conversations.createConversation(
			visitor_name = arguments.visitor_name,
			visitor_email = arguments.visitor_email,
			body = arguments.body
		);

		arrayAppend( variables.created_conversation_ids, created.conversation_id );

		return created;
	}

	private void function rememberEvent( required string event_id ) {
		arrayAppend( variables.created_event_ids, arguments.event_id );
	}

	/** Build an event_callback payload for a given thread. */
	private struct function buildEventCallback(
		required string event_id,
		required string thread_ts,
		required string message_ts,
		string text = "Have you tried the export again?",
		string channel = variables.channel_id,
		string user_id = "U9999999999"
	) {
		return {
			"type" : "event_callback",
			"team_id" : "T0TESTTEAM",
			"event_id" : arguments.event_id,
			"event_time" : 1700000000,
			"event" : {
				"type" : "message",
				"user" : arguments.user_id,
				"text" : arguments.text,
				"ts" : arguments.message_ts,
				"thread_ts" : arguments.thread_ts,
				"channel" : arguments.channel
			}
		};
	}

	/**
	 * Remove everything these specs created. Deletion order matters because the
	 * foreign keys are restrict, which is the whole point of them.
	 */
	private void function tearDownData() {

		if ( !variables.database_available ) {
			return;
		}

		for ( var event_id in variables.created_event_ids ) {
			try {
				variables.db.run(
					"delete from slack_event_inbox where event_id = :event_id",
					{ "event_id":{ value:event_id, cfsqltype:"cf_sql_varchar" } }
				);
			} catch ( any ignored ) {
			}
		}

		for ( var conversation_id in variables.created_conversation_ids ) {
			try {
				var params = { "conversation_id":{ value:conversation_id, cfsqltype:"cf_sql_varchar" } };

				variables.db.run( "delete from slack_outbound_delivery where conversation_id = :conversation_id", params );
				variables.db.run( "delete from conversation_message where conversation_id = :conversation_id", params );
				variables.db.run( "delete from conversation where conversation_id = :conversation_id", params );
			} catch ( any ignored ) {
			}
		}

		variables.created_conversation_ids = [];
		variables.created_event_ids = [];
	}

}
