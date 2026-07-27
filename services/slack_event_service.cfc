/**
 * The inbound half of the bridge: Slack events in, support messages out.
 *
 * Split deliberately in two.
 *
 * enqueueEvent() is what the webhook calls. It writes the event down and
 * returns. Slack wants an acknowledgement within three seconds and will retry
 * anything slower, so the endpoint's only job is to make the event durable.
 *
 * processPendingEvents() is what the worker calls. It filters, resolves and
 * saves at whatever pace the database and the workload allow, and its failures
 * are its own problem rather than something Slack has to hear about.
 */
component accessors="false" {

	variables.backoff_schedule = [ 5, 20, 90, 300 ];

	public slack_event_service function init(
		required any database_service,
		required any slack_service,
		required any conversation_service,
		required any log_service,
		required string configured_channel_id,
		string configured_app_id = "",
		numeric max_attempts = 5
	) {
		variables.db = arguments.database_service;
		variables.slack = arguments.slack_service;
		variables.conversations = arguments.conversation_service;
		variables.log = arguments.log_service;
		variables.configured_channel_id = arguments.configured_channel_id;
		variables.configured_app_id = arguments.configured_app_id;
		variables.max_attempts = arguments.max_attempts;
		return this;
	}

	// ------------------------------------------------------------------ inbox

	/**
	 * Store a verified event callback. Idempotent on Slack's event_id, which is
	 * globally unique and the only reliable thing to deduplicate on.
	 *
	 * @raw_body Exact request body, retained for later diagnosis.
	 * @payload Parsed payload.
	 * @headers Request headers, for Slack's retry metadata.
	 */
	public struct function enqueueEvent( required string raw_body, required struct payload, struct headers = {} ) {

		var event_id = trim( arguments.payload.event_id ?: "" );

		if ( !len( event_id ) ) {
			throw( type = "Slack.MissingEventId", message = "The event callback did not include an event_id." );
		}

		var inner_event = isStruct( arguments.payload.event ?: "" ) ? arguments.payload.event : {};
		var retry_num = val( headerValue( arguments.headers, "X-Slack-Retry-Num" ) );
		var retry_reason = headerValue( arguments.headers, "X-Slack-Retry-Reason" );

		var stored = variables.db.insertEventIfMissing( {
			"event_id" : event_id,
			"event_type" : left( arguments.payload.type ?: "unknown", 64 ),
			"inner_event_type" : left( inner_event.type ?: "", 64 ),
			"payload" : serializeJSON( arguments.payload ),
			"raw_body" : arguments.raw_body,
			"retry_num" : retry_num,
			"retry_reason" : left( retry_reason, 64 ),
			"received_at" : variables.db.utcNow()
		} );

		variables.log.slackEvent( {
			"stage" : "queued",
			"event_id" : event_id,
			"event_type" : arguments.payload.type ?: "",
			"inner_event_type" : inner_event.type ?: "",
			"channel" : inner_event.channel ?: "",
			"thread_ts" : inner_event.thread_ts ?: "",
			"retry_num" : retry_num,
			"retry_reason" : retry_reason,
			"queue_result" : stored ? "stored" : "duplicate_ignored"
		} );

		return { "event_id":event_id, "stored":stored, "duplicate":!stored };
	}

	// ------------------------------------------------------------- processing

	/**
	 * Work through queued events that are due.
	 * Returns counts for the caller to log or display.
	 */
	public struct function processPendingEvents( numeric max_events = 25 ) {

		var summary = { "claimed":0, "processed":0, "ignored":0, "retrying":0, "failed":0 };
		var worker_id = left( createUUID(), 20 );

		var candidates = variables.db.run(
			"select event_id, attempt_count from slack_event_inbox
			 where status = 'pending' and next_attempt_at <= :now
			 order by received_at, event_id",
			{ "now":{ value:variables.db.utcNow(), cfsqltype:"cf_sql_timestamp" } },
			{ "maxrows":arguments.max_events }
		);

		for ( var row in candidates ) {

			if ( !claimEvent( row.event_id, worker_id ) ) {
				continue;
			}

			summary.claimed++;

			try {
				var outcome = processOne( row.event_id );
				summary[ outcome ]++;
			} catch ( any e ) {
				var attempt = row.attempt_count + 1;
				if ( attempt >= variables.max_attempts ) {
					summary.failed++;
					markEvent( row.event_id, "failed", e );
				} else {
					summary.retrying++;
					scheduleRetry( row.event_id, attempt, e );
				}
			}
		}

		return summary;
	}

	/**
	 * Claim one event. The conditional UPDATE is the lock; a second worker
	 * running the same query gets zero affected rows and moves on.
	 */
	private boolean function claimEvent( required string event_id, required string worker_id ) {

		var query_result = variables.db.runWithResult(
			"update slack_event_inbox
			 set status = 'processing', attempt_count = attempt_count + 1, claimed_by = :worker_id
			 where event_id = :event_id and status = 'pending'",
			{
				"worker_id" : { value:arguments.worker_id, cfsqltype:"cf_sql_varchar" },
				"event_id" : { value:arguments.event_id, cfsqltype:"cf_sql_varchar" }
			}
		);

		return ( query_result.recordCount ?: 0 ) > 0;
	}

	/** Returns "processed" or "ignored". */
	private string function processOne( required string event_id ) {

		var found = variables.db.run(
			"select payload from slack_event_inbox where event_id = :event_id",
			{ "event_id":{ value:arguments.event_id, cfsqltype:"cf_sql_varchar" } }
		);

		if ( !found.recordCount ) {
			return "ignored";
		}

		if ( !isJSON( found.payload ) ) {
			markIgnored( arguments.event_id, "stored_payload_not_json" );
			return "ignored";
		}

		var payload = deserializeJSON( found.payload );
		var decision = evaluateEvent( payload );

		if ( !decision.accept ) {
			markIgnored( arguments.event_id, decision.reason );
			variables.log.slackEvent( {
				"stage" : "processed",
				"event_id" : arguments.event_id,
				"processing_result" : "ignored",
				"reason" : decision.reason
			} );
			return "ignored";
		}

		var conversation = variables.conversations.findBySlackThread( decision.channel, decision.thread_ts );

		if ( structIsEmpty( conversation ) ) {
			markIgnored( arguments.event_id, "no_matching_conversation" );
			variables.log.slackEvent( {
				"stage" : "processed",
				"event_id" : arguments.event_id,
				"channel" : decision.channel,
				"thread_ts" : decision.thread_ts,
				"processing_result" : "ignored",
				"reason" : "no_matching_conversation"
			} );
			return "ignored";
		}

		var saved = variables.conversations.saveSupportMessage(
			conversation_id = conversation.id,
			sender_id = decision.user_id,
			sender_name = decision.sender_name,
			body = decision.text,
			slack_event_id = arguments.event_id,
			slack_message_ts = decision.message_ts
		);

		markProcessed( arguments.event_id );

		variables.log.slackEvent( {
			"stage" : "processed",
			"event_id" : arguments.event_id,
			"conversation_id" : conversation.id,
			"channel" : decision.channel,
			"thread_ts" : decision.thread_ts,
			"message_ts" : decision.message_ts,
			"processing_result" : saved.created ? "support_message_saved" : "duplicate_message_skipped",
			"message_id" : saved.message_id,
			"body" : variables.log.bodyForLog( decision.text )
		} );

		return "processed";
	}

	// -------------------------------------------------------------- filtering

	/**
	 * Decide whether an event should become a customer-visible support reply.
	 *
	 * Pure: no database, no Slack, no side effects. That is what makes it
	 * straightforward to test against the awkward event shapes Slack actually
	 * sends, rather than the tidy ones the documentation implies.
	 *
	 * Returns { accept, reason, channel, thread_ts, message_ts, user_id,
	 * sender_name, text }.
	 */
	public struct function evaluateEvent( required struct payload ) {

		if ( ( arguments.payload.type ?: "" ) != "event_callback" ) {
			return rejectEvent( "not_an_event_callback" );
		}

		// When an app ID is configured, refuse events attributed to a different
		// Slack app. Slack does not cross the streams, but nothing is free.
		if ( len( trim( variables.configured_app_id ) ) && len( trim( arguments.payload.api_app_id ?: "" ) ) ) {
			if ( arguments.payload.api_app_id != variables.configured_app_id ) {
				return rejectEvent( "wrong_app_id" );
			}
		}

		if ( !isStruct( arguments.payload.event ?: "" ) ) {
			return rejectEvent( "no_inner_event" );
		}

		var event = arguments.payload.event;

		if ( ( event.type ?: "" ) != "message" ) {
			return rejectEvent( "not_a_message_event" );
		}

		// Anything Slack posts on behalf of an application, including this one.
		if ( len( trim( event.bot_id ?: "" ) ) ) {
			return rejectEvent( "bot_message" );
		}

		var subtype = trim( event.subtype ?: "" );

		if ( len( subtype ) ) {
			// thread_broadcast is a genuine human reply that the author also
			// pushed to the channel. Slack sends it once, it carries its own ts,
			// and the unique index on (conversation_id, slack_message_ts) makes a
			// duplicate impossible, so dropping it would only lose a real reply.
			// Everything else — edits, deletions, joins, leaves — is out of scope.
			if ( subtype != "thread_broadcast" ) {
				return rejectEvent( "unsupported_subtype_" & subtype );
			}
		}

		var user_id = trim( event.user ?: "" );

		if ( !len( user_id ) ) {
			return rejectEvent( "no_user" );
		}

		if ( len( trim( variables.slack.getBotUserId() ) ) && user_id == variables.slack.getBotUserId() ) {
			return rejectEvent( "own_bot_user" );
		}

		var channel = trim( event.channel ?: "" );

		if ( !len( channel ) ) {
			return rejectEvent( "no_channel" );
		}

		if ( len( trim( variables.configured_channel_id ) ) && channel != variables.configured_channel_id ) {
			return rejectEvent( "wrong_channel" );
		}

		var thread_ts = trim( event.thread_ts ?: "" );
		var message_ts = trim( event.ts ?: "" );

		if ( !len( thread_ts ) ) {
			return rejectEvent( "not_a_thread_reply" );
		}

		if ( !len( message_ts ) ) {
			return rejectEvent( "no_message_ts" );
		}

		if ( thread_ts == message_ts ) {
			return rejectEvent( "thread_root_message" );
		}

		var text = trim( event.text ?: "" );

		if ( !len( text ) ) {
			return rejectEvent( "empty_text" );
		}

		return {
			"accept" : true,
			"reason" : "",
			"channel" : channel,
			"thread_ts" : thread_ts,
			"message_ts" : message_ts,
			"user_id" : user_id,
			"sender_name" : resolveSenderName( event ),
			"text" : text
		};
	}

	private struct function rejectEvent( required string reason ) {
		return {
			"accept" : false,
			"reason" : arguments.reason,
			"channel" : "",
			"thread_ts" : "",
			"message_ts" : "",
			"user_id" : "",
			"sender_name" : "",
			"text" : ""
		};
	}

	/**
	 * A display name without asking for the users:read scope. Slack includes a
	 * user_profile on some events; when it does not, "Support" is honest and
	 * costs nothing.
	 */
	private string function resolveSenderName( required struct event ) {

		if ( isStruct( arguments.event.user_profile ?: "" ) ) {

			var profile = arguments.event.user_profile;

			for ( var key in [ "display_name", "real_name", "name" ] ) {
				if ( len( trim( profile[ key ] ?: "" ) ) ) {
					return left( trim( profile[ key ] ), 120 );
				}
			}
		}

		if ( len( trim( arguments.event.username ?: "" ) ) ) {
			return left( trim( arguments.event.username ), 120 );
		}

		return "Support";
	}

	// ---------------------------------------------------------- state updates

	private void function markProcessed( required string event_id ) {
		variables.db.run(
			"update slack_event_inbox set status = 'processed', processed_at = :now, last_error = null
			 where event_id = :event_id",
			{
				"now" : { value:variables.db.utcNow(), cfsqltype:"cf_sql_timestamp" },
				"event_id" : { value:arguments.event_id, cfsqltype:"cf_sql_varchar" }
			}
		);
	}

	private void function markIgnored( required string event_id, required string reason ) {
		variables.db.run(
			"update slack_event_inbox set status = 'ignored', processed_at = :now, last_error = :reason
			 where event_id = :event_id",
			{
				"now" : { value:variables.db.utcNow(), cfsqltype:"cf_sql_timestamp" },
				"reason" : { value:left( arguments.reason, 1000 ), cfsqltype:"cf_sql_varchar" },
				"event_id" : { value:arguments.event_id, cfsqltype:"cf_sql_varchar" }
			}
		);
	}

	private void function markEvent( required string event_id, required string new_status, required any exception ) {

		variables.db.run(
			"update slack_event_inbox set status = :new_status, processed_at = :now, last_error = :last_error
			 where event_id = :event_id",
			{
				"new_status" : { value:arguments.new_status, cfsqltype:"cf_sql_varchar" },
				"now" : { value:variables.db.utcNow(), cfsqltype:"cf_sql_timestamp" },
				"last_error" : { value:left( ( arguments.exception.type ?: "" ) & ": " & ( arguments.exception.message ?: "" ), 1000 ), cfsqltype:"cf_sql_varchar" },
				"event_id" : { value:arguments.event_id, cfsqltype:"cf_sql_varchar" }
			}
		);

		var fields = { "stage":"processed", "event_id":arguments.event_id, "processing_result":arguments.new_status };
		structAppend( fields, variables.log.describeException( arguments.exception ) );
		variables.log.error( "slack.eventFailed", fields );
	}

	private void function scheduleRetry( required string event_id, required numeric attempt_count, required any exception ) {

		var backoff_index = min( arguments.attempt_count, arrayLen( variables.backoff_schedule ) );
		var wait_seconds = variables.backoff_schedule[ max( backoff_index, 1 ) ];

		variables.db.run(
			"update slack_event_inbox
			 set status = 'pending', next_attempt_at = :next_attempt_at, last_error = :last_error
			 where event_id = :event_id",
			{
				"next_attempt_at" : { value:dateAdd( "s", wait_seconds, variables.db.utcNow() ), cfsqltype:"cf_sql_timestamp" },
				"last_error" : { value:left( ( arguments.exception.type ?: "" ) & ": " & ( arguments.exception.message ?: "" ), 1000 ), cfsqltype:"cf_sql_varchar" },
				"event_id" : { value:arguments.event_id, cfsqltype:"cf_sql_varchar" }
			}
		);

		var fields = {
			"stage" : "processed",
			"event_id" : arguments.event_id,
			"processing_result" : "retry_scheduled",
			"attempt_count" : arguments.attempt_count,
			"retry_in_seconds" : wait_seconds
		};

		structAppend( fields, variables.log.describeException( arguments.exception ) );
		variables.log.warn( "slack.eventRetry", fields );
	}

	// --------------------------------------------------------------- reporting

	public struct function getQueueStatus() {

		var found = variables.db.run( "select status, count(*) as total from slack_event_inbox group by status" );

		var counts = { "pending":0, "processing":0, "processed":0, "ignored":0, "failed":0 };

		for ( var row in found ) {
			counts[ row.status ] = row.total;
		}

		return counts;
	}

	private string function headerValue( required struct headers, required string name ) {
		return structKeyExists( arguments.headers, arguments.name ) ? trim( arguments.headers[ arguments.name ] ) : "";
	}

}
