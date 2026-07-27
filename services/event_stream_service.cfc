/**
 * Server-Sent Events support.
 *
 * The service builds correctly framed SSE payloads and answers the cursor
 * question "what has this conversation seen since message N". Writing bytes and
 * flushing them is left to stream/conversation.cfm, because a service that calls
 * writeOutput() is a service you can never call from anywhere else.
 *
 * There is no separate browser-events table. The message stream is already an
 * ordered, durable log keyed by an increasing message_id, which is exactly what
 * an SSE cursor needs. A second table would only be a copy that can disagree.
 */
component accessors="false" {

	public event_stream_service function init(
		required any conversation_service,
		required any slack_event_service,
		required any slack_delivery_service,
		required any log_service,
		numeric max_seconds = 55,
		numeric poll_milliseconds = 1500,
		numeric heartbeat_seconds = 15,
		boolean auto_process_events = true
	) {
		variables.conversations = arguments.conversation_service;
		variables.events = arguments.slack_event_service;
		variables.deliveries = arguments.slack_delivery_service;
		variables.log = arguments.log_service;
		variables.max_seconds = arguments.max_seconds;
		variables.poll_milliseconds = arguments.poll_milliseconds;
		variables.heartbeat_seconds = arguments.heartbeat_seconds;
		variables.auto_process_events = arguments.auto_process_events;
		return this;
	}

	public numeric function getMaxSeconds() {
		return variables.max_seconds;
	}

	public numeric function getPollMilliseconds() {
		return variables.poll_milliseconds;
	}

	public numeric function getHeartbeatSeconds() {
		return variables.heartbeat_seconds;
	}

	/**
	 * A stream is only opened for a caller holding the conversation's access
	 * token. Without this, changing a query-string UUID would be a working
	 * feature rather than a vulnerability.
	 */
	public struct function authorizeStream( required string conversation_id, required string access_token ) {
		return variables.conversations.authorize( arguments.conversation_id, arguments.access_token );
	}

	/**
	 * Messages this conversation has not sent to the browser yet. The
	 * conversation ID is part of the query, so one stream can never read another
	 * conversation's messages.
	 */
	public array function getMessagesAfter( required string conversation_id, numeric after_message_id = 0 ) {
		return variables.conversations.getMessagesAfter( arguments.conversation_id, arguments.after_message_id );
	}

	/**
	 * Resolve the starting cursor. Last-Event-ID is what the browser replays
	 * automatically on reconnect; the explicit parameter is what the client sends
	 * on a fresh connection.
	 */
	public numeric function resolveCursor( string last_event_id = "", string explicit_cursor = "" ) {

		if ( len( trim( arguments.last_event_id ) ) && isNumeric( trim( arguments.last_event_id ) ) ) {
			return int( val( arguments.last_event_id ) );
		}

		if ( len( trim( arguments.explicit_cursor ) ) && isNumeric( trim( arguments.explicit_cursor ) ) ) {
			return int( val( arguments.explicit_cursor ) );
		}

		return 0;
	}

	// -------------------------------------------------------------- SSE framing

	/**
	 * One SSE event. The data payload is serialized to single-line JSON; a
	 * newline inside it would otherwise end the frame early and hand the browser
	 * half a message.
	 */
	public string function formatEvent( required string event_name, required any data, string event_id = "" ) {

		var frame = "";

		if ( len( trim( arguments.event_id ) ) ) {
			frame &= "id: " & arguments.event_id & chr( 10 );
		}

		frame &= "event: " & arguments.event_name & chr( 10 );
		frame &= "data: " & toSingleLineJson( arguments.data ) & chr( 10 );
		frame &= chr( 10 );

		return frame;
	}

	/** A comment line. Keeps proxies and load balancers from closing an idle stream. */
	public string function formatComment( string text = "keepalive" ) {
		return ": " & arguments.text & chr( 10 ) & chr( 10 );
	}

	public string function toSingleLineJson( required any data ) {

		var json = serializeJSON( arguments.data );

		json = replace( json, chr( 13 ) & chr( 10 ), "", "all" );
		json = replace( json, chr( 10 ), "", "all" );
		json = replace( json, chr( 13 ), "", "all" );

		return json;
	}

	// --------------------------------------------------------- queue draining

	/**
	 * Development convenience: drain the inbound and outbound queues from inside
	 * the streaming request.
	 *
	 * This exists so the documented end-to-end test works without a second
	 * terminal window. It is guarded by a named lock so overlapping streams do
	 * not all try at once, and it can be switched off in configuration when the
	 * CommandBox task is doing the work properly.
	 */
	public struct function maybeProcessQueues() {

		var result = { "ran":false, "events":{}, "deliveries":{} };

		if ( !variables.auto_process_events ) {
			return result;
		}

		lock name="slackChatQueueDrain" type="exclusive" timeout="0" throwontimeout="false" {

			result.ran = true;

			try {
				result.events = variables.events.processPendingEvents( 25 );
				result.deliveries = variables.deliveries.processPendingDeliveries( "", 25 );
			} catch ( any e ) {
				var fields = { "trigger":"sse_stream" };
				structAppend( fields, variables.log.describeException( e ) );
				variables.log.error( "queue.drainFailed", fields );
			}
		}

		return result;
	}

}
