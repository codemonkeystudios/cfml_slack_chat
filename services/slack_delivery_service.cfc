/**
 * The outbound half of the bridge: takes queued customer messages and posts them
 * into Slack.
 *
 * Nothing here runs while a database transaction is open. A Slack call can take
 * fifteen seconds, and holding row locks for the duration would turn a slow API
 * into a slow database.
 *
 * The queue is durable, so a Slack outage delays delivery rather than losing the
 * message. The API endpoints call processPendingDeliveries() for a single
 * conversation immediately after committing, which keeps the common case fast
 * while leaving the retry path available for the uncommon one.
 */
component accessors="false" {

	// Seconds to wait before attempts 2, 3, 4 and 5.
	variables.backoff_schedule = [ 5, 20, 90, 300 ];

	public slack_delivery_service function init(
		required any database_service,
		required any slack_service,
		required any conversation_service,
		required any log_service,
		numeric max_attempts = 5
	) {
		variables.db = arguments.database_service;
		variables.slack = arguments.slack_service;
		variables.conversations = arguments.conversation_service;
		variables.log = arguments.log_service;
		variables.max_attempts = arguments.max_attempts;
		return this;
	}

	/**
	 * Attempt every delivery that is due.
	 *
	 * @conversation_id Restrict to one conversation. Used by the API endpoints to
	 * deliver the message the visitor just sent.
	 * @max_deliveries Maximum deliveries to attempt in this pass.
	 */
	public struct function processPendingDeliveries( string conversation_id = "", numeric max_deliveries = 25 ) {

		var summary = { "claimed":0, "sent":0, "deferred":0, "failed":0, "abandoned":0 };
		var worker_id = left( createUUID(), 20 );

		var sql = "select delivery_id, conversation_id, message_id, attempt_count
		 from slack_outbound_delivery
		 where status in ('pending','failed') and next_attempt_at <= :now";

		var params = { "now":{ value:variables.db.utcNow(), cfsqltype:"cf_sql_timestamp" } };

		if ( len( trim( arguments.conversation_id ) ) ) {
			sql &= " and conversation_id = :conversation_id";
			params[ "conversation_id" ] = { value:arguments.conversation_id, cfsqltype:"cf_sql_varchar" };
		}

		sql &= " order by delivery_id";

		var candidates = variables.db.run( sql, params, { "maxrows":arguments.max_deliveries } );

		for ( var row in candidates ) {

			if ( !claimDelivery( row.delivery_id, worker_id ) ) {
				continue;
			}

			summary.claimed++;

			try {
				var outcome = deliverOne( row.delivery_id, row.conversation_id, row.message_id );
				summary[ outcome ]++;
			} catch ( any e ) {
				summary.failed++;
				recordFailure( row.delivery_id, row.attempt_count + 1, e );
			}
		}

		return summary;
	}

	// --------------------------------------------------------------- internals

	/**
	 * Take ownership of a delivery row. The single conditional UPDATE is the
	 * lock: whichever worker changes the row first is the one that owns it.
	 */
	private boolean function claimDelivery( required numeric delivery_id, required string worker_id ) {

		var query_result = variables.db.runWithResult(
			"update slack_outbound_delivery
			 set status = 'processing',
			 attempt_count = attempt_count + 1,
			 last_attempt_at = :now,
			 claimed_by = :worker_id
			 where delivery_id = :delivery_id and status in ('pending','failed')",
			{
				"now" : { value:variables.db.utcNow(), cfsqltype:"cf_sql_timestamp" },
				"worker_id" : { value:arguments.worker_id, cfsqltype:"cf_sql_varchar" },
				"delivery_id" : { value:arguments.delivery_id, cfsqltype:"cf_sql_bigint" }
			}
		);

		return ( query_result.recordCount ?: 0 ) > 0;
	}

	/** Deliver one queued message. Returns "sent", "deferred" or "abandoned". */
	private string function deliverOne(
		required numeric delivery_id,
		required string conversation_id,
		required numeric message_id
	) {

		var conversation = variables.conversations.getConversation( arguments.conversation_id );
		var message = variables.conversations.getMessage( arguments.message_id );
		var has_thread = len( trim( conversation.slackThreadTs ) ) > 0;

		// A conversation's root message has to exist before anything can be a
		// reply to it. If an earlier message for this conversation has not been
		// delivered yet, wait for it rather than opening a second thread.
		if ( !has_thread && !isEarliestUndeliveredMessage( arguments.conversation_id, arguments.message_id ) ) {
			deferDelivery( arguments.delivery_id, 10 );
			return "deferred";
		}

		var message_text = has_thread
			? variables.slack.formatCustomerReply( conversation.visitorName, message.body )
			: variables.slack.formatConversationOpener(
				visitor_name = conversation.visitorName,
				visitor_email = conversation.visitorEmail,
				conversation_id = conversation.id,
				body = message.body
			);

		var target_channel = has_thread ? conversation.slackChannelId : variables.slack.getDefaultChannel();
		var started_at = getTickCount();
		var response = {};

		try {
			response = variables.slack.postMessage(
				text = message_text,
				channel = target_channel,
				thread_ts = has_thread ? conversation.slackThreadTs : ""
			);
		} catch ( any e ) {
			variables.log.slackRequest( {
				"conversation_id" : arguments.conversation_id,
				"message_id" : arguments.message_id,
				"delivery_id" : arguments.delivery_id,
				"slack_channel_id" : target_channel,
				"slack_thread_ts" : conversation.slackThreadTs,
				"slack_method" : "chat.postMessage",
				"outcome" : "failed",
				"duration_ms" : getTickCount() - started_at
			} );
			rethrow;
		}

		var channel_id = response.channel ?: target_channel;
		var message_ts = response.ts ?: "";
		var thread_ts = has_thread ? conversation.slackThreadTs : message_ts;

		if ( !has_thread ) {

			if ( !len( trim( message_ts ) ) ) {
				throw(
					type = "Slack.InvalidResponse",
					message = "Slack accepted the root message but did not return a timestamp, so the thread cannot be tracked."
				);
			}

			variables.conversations.attachSlackThread( arguments.conversation_id, channel_id, message_ts );
		}

		variables.db.run(
			"update slack_outbound_delivery
			 set status = 'sent', completed_at = :completed_at, last_error = null,
			 slack_channel_id = :slack_channel_id, slack_thread_ts = :slack_thread_ts
			 where delivery_id = :delivery_id",
			{
				"completed_at" : { value:variables.db.utcNow(), cfsqltype:"cf_sql_timestamp" },
				"slack_channel_id" : { value:channel_id, cfsqltype:"cf_sql_varchar" },
				"slack_thread_ts" : { value:thread_ts, cfsqltype:"cf_sql_varchar" },
				"delivery_id" : { value:arguments.delivery_id, cfsqltype:"cf_sql_bigint" }
			}
		);

		// The Slack timestamp is recorded against the customer message too, so an
		// inbound event echoing our own post can be recognised for what it is.
		variables.db.run(
			"update conversation_message set slack_message_ts = :slack_message_ts
			 where message_id = :message_id and slack_message_ts is null",
			{
				"slack_message_ts" : { value:message_ts, cfsqltype:"cf_sql_varchar" },
				"message_id" : { value:arguments.message_id, cfsqltype:"cf_sql_bigint" }
			}
		);

		variables.log.slackRequest( {
			"conversation_id" : arguments.conversation_id,
			"message_id" : arguments.message_id,
			"delivery_id" : arguments.delivery_id,
			"slack_channel_id" : channel_id,
			"slack_thread_ts" : thread_ts,
			"slack_method" : "chat.postMessage",
			"outcome" : "sent",
			"root_message" : !has_thread,
			"duration_ms" : getTickCount() - started_at
		} );

		return "sent";
	}

	private boolean function isEarliestUndeliveredMessage( required string conversation_id, required numeric message_id ) {

		var found = variables.db.run(
			"select min(message_id) as earliest_message_id from slack_outbound_delivery
			 where conversation_id = :conversation_id and status <> 'sent' and status <> 'abandoned'",
			{ "conversation_id":{ value:arguments.conversation_id, cfsqltype:"cf_sql_varchar" } }
		);

		return !found.recordCount
			|| val( found.earliest_message_id ) == 0
			|| val( found.earliest_message_id ) == arguments.message_id;
	}

	private void function deferDelivery( required numeric delivery_id, required numeric wait_seconds ) {
		variables.db.run(
			"update slack_outbound_delivery
			 set status = 'pending', next_attempt_at = :next_attempt_at
			 where delivery_id = :delivery_id",
			{
				"next_attempt_at" : { value:dateAdd( "s", arguments.wait_seconds, variables.db.utcNow() ), cfsqltype:"cf_sql_timestamp" },
				"delivery_id" : { value:arguments.delivery_id, cfsqltype:"cf_sql_bigint" }
			}
		);
	}

	/**
	 * Record a failed attempt and decide whether it is worth trying again.
	 *
	 * Permanent Slack errors and exhausted attempt budgets are abandoned:
	 * retrying "channel_not_found" until the heat death of the universe does not
	 * eventually find the channel.
	 */
	private void function recordFailure( required numeric delivery_id, required numeric attempt_count, required any exception ) {

		var slack_error = extractSlackError( arguments.exception );
		var permanent = len( slack_error ) && variables.slack.isPermanentError( slack_error );
		var exhausted = arguments.attempt_count >= variables.max_attempts;
		var new_status = ( permanent || exhausted ) ? "abandoned" : "failed";

		var wait_seconds = extractRetryAfter( arguments.exception );

		if ( wait_seconds <= 0 ) {
			var backoff_index = min( arguments.attempt_count, arrayLen( variables.backoff_schedule ) );
			wait_seconds = variables.backoff_schedule[ max( backoff_index, 1 ) ];
		}

		variables.db.run(
			"update slack_outbound_delivery
			 set status = :new_status, last_error = :last_error, next_attempt_at = :next_attempt_at
			 where delivery_id = :delivery_id",
			{
				"new_status" : { value:new_status, cfsqltype:"cf_sql_varchar" },
				"last_error" : { value:left( ( arguments.exception.type ?: "" ) & ": " & ( arguments.exception.message ?: "" ), 1000 ), cfsqltype:"cf_sql_varchar" },
				"next_attempt_at" : { value:dateAdd( "s", wait_seconds, variables.db.utcNow() ), cfsqltype:"cf_sql_timestamp" },
				"delivery_id" : { value:arguments.delivery_id, cfsqltype:"cf_sql_bigint" }
			}
		);

		var fields = {
			"delivery_id" : arguments.delivery_id,
			"attempt_count" : arguments.attempt_count,
			"slack_error" : slack_error,
			"status" : new_status,
			"retry_in_seconds" : new_status == "abandoned" ? 0 : wait_seconds
		};

		structAppend( fields, variables.log.describeException( arguments.exception ) );
		variables.log.error( "slack.deliveryFailed", fields );
	}

	private string function extractSlackError( required any exception ) {

		var extended_info = arguments.exception.extendedinfo ?: "";

		if ( len( extended_info ) && isJSON( extended_info ) ) {
			var parsed = deserializeJSON( extended_info );
			return parsed.slack_error ?: "";
		}

		return "";
	}

	private numeric function extractRetryAfter( required any exception ) {

		var extended_info = arguments.exception.extendedinfo ?: "";

		if ( len( extended_info ) && isJSON( extended_info ) ) {
			var parsed = deserializeJSON( extended_info );
			return val( parsed.retry_after ?: 0 );
		}

		return 0;
	}

}
