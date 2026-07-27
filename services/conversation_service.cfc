/**
 * The application's system of record.
 *
 * Conversations and messages are written here before Slack is involved, and they
 * stay written whether Slack cooperates or not. Slack is a participant in the
 * conversation, not the place the conversation lives.
 *
 * This component knows nothing about the Slack API. It stores the channel and
 * thread identifiers that SlackDeliveryService hands back, and reads them again
 * when SlackEventService needs to map an inbound reply to a conversation.
 */
component accessors="false" {

	variables.message_columns = "message_id, conversation_id, sender_type, sender_id, sender_name, body, source, slack_event_id, slack_message_ts, created_at";

	public conversation_service function init(
		required any database_service,
		required any log_service,
		numeric max_message_length = 4000
	) {
		variables.db = arguments.database_service;
		variables.log = arguments.log_service;
		variables.max_message_length = arguments.max_message_length;
		return this;
	}

	// ------------------------------------------------------------ conversations

	/**
	 * Create a conversation and its first customer message, and enrol that
	 * message in the outbound delivery queue. All three land in one transaction,
	 * or none of them do.
	 *
	 * Slack is deliberately not called from here. The customer's message is a
	 * fact the moment they press Send; delivering it is a separate concern that
	 * is allowed to fail and be retried.
	 */
	public struct function createConversation(
		required string visitor_name,
		required string visitor_email,
		required string body
	) {

		validateVisitor( arguments.visitor_name, arguments.visitor_email );
		validateBody( arguments.body );

		var conversation_id = variables.db.newConversationId();
		var access_token = variables.db.newAccessToken();
		var created_at = variables.db.utcNow();
		var message_id = 0;

		transaction {

			variables.db.run(
				"insert into conversation
					( conversation_id, visitor_name, visitor_email, status, access_token_hash, created_at, updated_at )
				 values
					( :conversation_id, :visitor_name, :visitor_email, 'waiting', :access_token_hash, :created_at, :created_at )",
				{
					"conversation_id" : { value:conversation_id, cfsqltype:"cf_sql_varchar" },
					"visitor_name" : { value:trim( arguments.visitor_name ), cfsqltype:"cf_sql_varchar" },
					"visitor_email" : { value:trim( arguments.visitor_email ), cfsqltype:"cf_sql_varchar" },
					"access_token_hash" : { value:variables.db.hashToken( access_token ), cfsqltype:"cf_sql_varchar" },
					"created_at" : { value:created_at, cfsqltype:"cf_sql_timestamp" }
				}
			);

			message_id = insertMessage(
				conversation_id = conversation_id,
				sender_type = "customer",
				sender_id = "",
				sender_name = trim( arguments.visitor_name ),
				body = trim( arguments.body ),
				source = "web",
				created_at = created_at
			);

			enqueueDelivery( conversation_id, message_id, created_at );
		}

		variables.log.info( "conversation.created", {
			"conversation_id" : conversation_id,
			"message_id" : message_id
		} );

		return {
			"conversation_id" : conversation_id,
			"access_token" : access_token,
			"message_id" : message_id,
			"conversation" : getConversation( conversation_id ),
			"message" : getMessage( message_id )
		};
	}

	/**
	 * Append a customer message to an existing conversation. The conversation's
	 * stored Slack thread is reused; a second root message is never created.
	 */
	public struct function addCustomerMessage(
		required string conversation_id,
		required string access_token,
		required string body
	) {

		var conversation = authorize( arguments.conversation_id, arguments.access_token );

		if ( conversation.status == "closed" ) {
			throw( type = "Conversation.Closed", message = "This conversation has been closed. Start a new one to keep testing." );
		}

		validateBody( arguments.body );

		var created_at = variables.db.utcNow();
		var message_id = 0;

		transaction {

			message_id = insertMessage(
				conversation_id = arguments.conversation_id,
				sender_type = "customer",
				sender_id = "",
				sender_name = conversation.visitorName,
				body = trim( arguments.body ),
				source = "web",
				created_at = created_at
			);

			enqueueDelivery( arguments.conversation_id, message_id, created_at );

			variables.db.run(
				"update conversation set updated_at = :updated_at, status = 'waiting' where conversation_id = :conversation_id",
				{
					"updated_at" : { value:created_at, cfsqltype:"cf_sql_timestamp" },
					"conversation_id" : { value:arguments.conversation_id, cfsqltype:"cf_sql_varchar" }
				}
			);
		}

		variables.log.info( "conversation.customerMessage", {
			"conversation_id" : arguments.conversation_id,
			"message_id" : message_id
		} );

		return {
			"message_id" : message_id,
			"message" : getMessage( message_id )
		};
	}

	public struct function getConversation( required string conversation_id ) {

		var found = variables.db.run(
			"select conversation_id, visitor_name, visitor_email, status, slack_channel_id, slack_thread_ts,
					created_at, updated_at, closed_at
			 from conversation
			 where conversation_id = :conversation_id",
			{ "conversation_id":{ value:arguments.conversation_id, cfsqltype:"cf_sql_varchar" } }
		);

		if ( !found.recordCount ) {
			throw( type = "Conversation.NotFound", message = "No conversation matches that identifier." );
		}

		return {
			"id" : found.conversation_id,
			"visitorName" : found.visitor_name,
			"visitorEmail" : found.visitor_email,
			"status" : found.status,
			"slackChannelId" : found.slack_channel_id ?: "",
			"slackThreadTs" : found.slack_thread_ts ?: "",
			"createdAt" : variables.db.toIso( found.created_at ),
			"updatedAt" : variables.db.toIso( found.updated_at ),
			"closedAt" : variables.db.toIso( found.closed_at )
		};
	}

	/**
	 * Look up a conversation from a Slack thread. Exact channel ID plus exact
	 * thread timestamp, nothing else. Matching on subject lines or email
	 * addresses is how support replies end up in a stranger's browser.
	 */
	public struct function findBySlackThread( required string slack_channel_id, required string slack_thread_ts ) {

		var found = variables.db.run(
			"select conversation_id from conversation
			 where slack_channel_id = :slack_channel_id and slack_thread_ts = :slack_thread_ts",
			{
				"slack_channel_id" : { value:arguments.slack_channel_id, cfsqltype:"cf_sql_varchar" },
				"slack_thread_ts" : { value:arguments.slack_thread_ts, cfsqltype:"cf_sql_varchar" }
			}
		);

		if ( !found.recordCount ) {
			return {};
		}

		return getConversation( found.conversation_id );
	}

	/** Store the Slack identifiers returned when the root message was posted. */
	public void function attachSlackThread(
		required string conversation_id,
		required string slack_channel_id,
		required string slack_thread_ts
	) {
		variables.db.run(
			"update conversation
			 set slack_channel_id = :slack_channel_id, slack_thread_ts = :slack_thread_ts, updated_at = :updated_at
			 where conversation_id = :conversation_id and slack_thread_ts is null",
			{
				"slack_channel_id" : { value:arguments.slack_channel_id, cfsqltype:"cf_sql_varchar" },
				"slack_thread_ts" : { value:arguments.slack_thread_ts, cfsqltype:"cf_sql_varchar" },
				"updated_at" : { value:variables.db.utcNow(), cfsqltype:"cf_sql_timestamp" },
				"conversation_id" : { value:arguments.conversation_id, cfsqltype:"cf_sql_varchar" }
			}
		);
	}

	public void function closeConversation( required string conversation_id, required string access_token ) {

		authorize( arguments.conversation_id, arguments.access_token );

		var closed_at = variables.db.utcNow();

		variables.db.run(
			"update conversation set status = 'closed', closed_at = :closed_at, updated_at = :closed_at
			 where conversation_id = :conversation_id",
			{
				"closed_at" : { value:closed_at, cfsqltype:"cf_sql_timestamp" },
				"conversation_id" : { value:arguments.conversation_id, cfsqltype:"cf_sql_varchar" }
			}
		);
	}

	// ---------------------------------------------------------- authorization

	/**
	 * A conversation ID alone is not authorization. The caller must also hold the
	 * access token issued when the conversation was created; only its SHA-256
	 * hash is stored, and the comparison is constant time.
	 *
	 * This is a test-application access model, not account authentication.
	 */
	public struct function authorize( required string conversation_id, required string access_token ) {

		if ( !len( trim( arguments.conversation_id ) ) || !len( trim( arguments.access_token ) ) ) {
			throw( type = "Conversation.AccessDenied", message = "This conversation requires a valid access token." );
		}

		var found = variables.db.run(
			"select access_token_hash from conversation where conversation_id = :conversation_id",
			{ "conversation_id":{ value:arguments.conversation_id, cfsqltype:"cf_sql_varchar" } }
		);

		if ( !found.recordCount ) {
			throw( type = "Conversation.AccessDenied", message = "This conversation requires a valid access token." );
		}

		if ( !constantTimeEquals( trim( found.access_token_hash ), variables.db.hashToken( arguments.access_token ) ) ) {
			variables.log.warn( "conversation.accessDenied", { "conversation_id":arguments.conversation_id } );
			throw( type = "Conversation.AccessDenied", message = "This conversation requires a valid access token." );
		}

		return getConversation( arguments.conversation_id );
	}

	private boolean function constantTimeEquals( required string expected, required string provided ) {

		if ( len( arguments.expected ) != len( arguments.provided ) ) {
			return false;
		}

		var difference = 0;

		for ( var index = 1; index <= len( arguments.expected ); index++ ) {
			difference = bitOr(
				difference,
				bitXor( asc( mid( arguments.expected, index, 1 ) ), asc( mid( arguments.provided, index, 1 ) ) )
			);
		}

		return difference == 0;
	}

	// --------------------------------------------------------------- messages

	/**
	 * The cursor read behind the SSE stream. Only messages belonging to this
	 * conversation, only messages after the cursor, always in message_id order.
	 */
	public array function getMessagesAfter(
		required string conversation_id,
		numeric after_message_id = 0,
		numeric max_rows = 200
	) {

		var found = variables.db.run(
			"select #variables.message_columns#
			 from conversation_message
			 where conversation_id = :conversation_id and message_id > :after_message_id
			 order by message_id",
			{
				"conversation_id" : { value:arguments.conversation_id, cfsqltype:"cf_sql_varchar" },
				"after_message_id" : { value:arguments.after_message_id, cfsqltype:"cf_sql_bigint" }
			},
			{ "maxrows":arguments.max_rows }
		);

		var messages = [];

		for ( var row in found ) {
			arrayAppend( messages, toPublicMessage( row ) );
		}

		return messages;
	}

	public struct function getMessage( required numeric message_id ) {

		var found = variables.db.run(
			"select #variables.message_columns# from conversation_message where message_id = :message_id",
			{ "message_id":{ value:arguments.message_id, cfsqltype:"cf_sql_bigint" } }
		);

		if ( !found.recordCount ) {
			throw( type = "Conversation.MessageNotFound", message = "No message matches that identifier." );
		}

		return toPublicMessage( found );
	}

	/**
	 * Save a support reply that arrived from Slack.
	 *
	 * Idempotent in two independent ways: the unique index on
	 * (conversation_id, slack_message_ts) and the unique index on
	 * slack_event_id. Slack retries; the customer should not see doubles.
	 *
	 * Returns { created:boolean, message_id:numeric }.
	 */
	public struct function saveSupportMessage(
		required string conversation_id,
		required string sender_id,
		required string sender_name,
		required string body,
		required string slack_event_id,
		required string slack_message_ts
	) {

		var existing = variables.db.run(
			"select message_id from conversation_message
			 where conversation_id = :conversation_id and slack_message_ts = :slack_message_ts",
			{
				"conversation_id" : { value:arguments.conversation_id, cfsqltype:"cf_sql_varchar" },
				"slack_message_ts" : { value:arguments.slack_message_ts, cfsqltype:"cf_sql_varchar" }
			}
		);

		if ( existing.recordCount ) {
			return { "created":false, "message_id":existing.message_id };
		}

		var created_at = variables.db.utcNow();
		var message_id = 0;

		try {
			transaction {

				message_id = insertMessage(
					conversation_id = arguments.conversation_id,
					sender_type = "support",
					sender_id = arguments.sender_id,
					sender_name = len( trim( arguments.sender_name ) ) ? arguments.sender_name : "Support",
					body = arguments.body,
					source = "slack",
					created_at = created_at,
					slack_event_id = arguments.slack_event_id,
					slack_message_ts = arguments.slack_message_ts
				);

				variables.db.run(
					"update conversation set status = 'active', updated_at = :updated_at
					 where conversation_id = :conversation_id and status <> 'closed'",
					{
						"updated_at" : { value:created_at, cfsqltype:"cf_sql_timestamp" },
						"conversation_id" : { value:arguments.conversation_id, cfsqltype:"cf_sql_varchar" }
					}
				);
			}
		} catch ( any e ) {
			// Another worker inserted the same reply between the check above and
			// this insert. The constraint did its job; treat it as a duplicate.
			if ( variables.db.isUniqueConstraintViolation( e ) ) {
				return { "created":false, "message_id":0 };
			}
			rethrow;
		}

		return { "created":true, "message_id":message_id };
	}

	// -------------------------------------------------------- delivery queue

	/** Enrol a message for outbound delivery. Called inside the caller's transaction. */
	private void function enqueueDelivery(
		required string conversation_id,
		required numeric message_id,
		required date created_at
	) {
		variables.db.run(
			"insert into slack_outbound_delivery
				( conversation_id, message_id, destination, status, attempt_count, next_attempt_at, created_at )
			 values
				( :conversation_id, :message_id, 'slack', 'pending', 0, :created_at, :created_at )",
			{
				"conversation_id" : { value:arguments.conversation_id, cfsqltype:"cf_sql_varchar" },
				"message_id" : { value:arguments.message_id, cfsqltype:"cf_sql_bigint" },
				"created_at" : { value:arguments.created_at, cfsqltype:"cf_sql_timestamp" }
			}
		);
	}

	/** The delivery state shown in the browser's diagnostics panel. */
	public struct function getDeliveryStatus( required string conversation_id ) {

		var found = variables.db.run(
			"select status, count(*) as total from slack_outbound_delivery
			 where conversation_id = :conversation_id group by status",
			{ "conversation_id":{ value:arguments.conversation_id, cfsqltype:"cf_sql_varchar" } }
		);

		var counts = { "pending":0, "processing":0, "sent":0, "failed":0, "abandoned":0 };

		for ( var row in found ) {
			counts[ row.status ] = row.total;
		}

		var summary = "sent";

		if ( counts.pending > 0 || counts.processing > 0 ) {
			summary = "pending";
		}
		if ( counts.failed > 0 ) {
			summary = "retrying";
		}
		if ( counts.abandoned > 0 ) {
			summary = "failed";
		}

		return { "summary":summary, "counts":counts };
	}

	// --------------------------------------------------------------- internals

	private numeric function insertMessage(
		required string conversation_id,
		required string sender_type,
		required string sender_id,
		required string sender_name,
		required string body,
		required string source,
		required date created_at,
		string slack_event_id = "",
		string slack_message_ts = ""
	) {
		return variables.db.insertReturningId(
			table = "conversation_message",
			id_column = "message_id",
			columns = [ "conversation_id", "sender_type", "sender_id", "sender_name", "body", "source", "slack_event_id", "slack_message_ts", "created_at" ],
			params = [
				{ value:arguments.conversation_id, cfsqltype:"cf_sql_varchar" },
				{ value:arguments.sender_type, cfsqltype:"cf_sql_varchar" },
				{ value:arguments.sender_id, cfsqltype:"cf_sql_varchar", null:!len( trim( arguments.sender_id ) ) },
				{ value:arguments.sender_name, cfsqltype:"cf_sql_varchar" },
				{ value:arguments.body, cfsqltype:"cf_sql_longvarchar" },
				{ value:arguments.source, cfsqltype:"cf_sql_varchar" },
				{ value:arguments.slack_event_id, cfsqltype:"cf_sql_varchar", null:!len( trim( arguments.slack_event_id ) ) },
				{ value:arguments.slack_message_ts, cfsqltype:"cf_sql_varchar", null:!len( trim( arguments.slack_message_ts ) ) },
				{ value:arguments.created_at, cfsqltype:"cf_sql_timestamp" }
			]
		);
	}

	/**
	 * The browser-facing shape of a message. Slack user IDs and event IDs stay on
	 * the server; the visitor has no use for them.
	 */
	private struct function toPublicMessage( required any row ) {
		return {
			"id" : arguments.row.message_id,
			"senderType" : arguments.row.sender_type,
			"senderName" : arguments.row.sender_name ?: "",
			"body" : arguments.row.body,
			"source" : arguments.row.source,
			"createdAt" : variables.db.toIso( arguments.row.created_at )
		};
	}

	private void function validateVisitor( required string visitor_name, required string visitor_email ) {

		if ( !len( trim( arguments.visitor_name ) ) ) {
			throw( type = "Conversation.ValidationFailed", message = "Enter a name so support knows who they are talking to." );
		}

		if ( len( trim( arguments.visitor_name ) ) > 120 ) {
			throw( type = "Conversation.ValidationFailed", message = "That name is longer than 120 characters." );
		}

		if ( !isValid( "email", trim( arguments.visitor_email ) ) ) {
			throw( type = "Conversation.ValidationFailed", message = "Enter a valid email address." );
		}

		if ( len( trim( arguments.visitor_email ) ) > 255 ) {
			throw( type = "Conversation.ValidationFailed", message = "That email address is longer than 255 characters." );
		}
	}

	private void function validateBody( required string body ) {

		if ( !len( trim( arguments.body ) ) ) {
			throw( type = "Conversation.ValidationFailed", message = "Enter a message before pressing Send." );
		}

		if ( len( arguments.body ) > variables.max_message_length ) {
			throw(
				type = "Conversation.ValidationFailed",
				message = "Messages are limited to #variables.max_message_length# characters. Yours was #len( arguments.body )#."
			);
		}
	}

}
