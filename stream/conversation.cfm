<cfsetting enablecfoutputonly="true" showdebugoutput="false">
<cfscript>
	/**
	* Server-Sent Events endpoint for one conversation.
	*
	* Authorization is the conversation ID plus its access token, taken from the
	* session where possible and from a query parameter when the browser is
	* reconnecting after a session has gone. EventSource cannot set request headers,
	* which is the entire reason the token is allowed in the query string here.
	*
	* The connection has a bounded lifetime. When it expires the endpoint closes
	* cleanly and the browser reconnects on its own, replaying Last-Event-ID so no
	* message is missed and none is delivered twice.
	*/

	// The request has to outlive the streaming loop, with headroom for the final
	// flush. Without this the engine terminates the request mid-frame.
	cfsetting( requesttimeout = 180 );

	slack_chat = application.slack_chat;

	void function streamError( required numeric status_code, required string error_code, required string message ) {
		cfheader( statuscode = arguments.status_code, statustext = arguments.error_code );
		cfcontent( type = "application/json; charset=utf-8" );
		writeOutput( serializeJSON( { "ok":false, "error":{ "code":arguments.error_code, "message":arguments.message } } ) );
		abort;
	}

	if ( ( cgi.request_method ?: "" ) != "GET" ) {
		streamError( 405, "method_not_allowed", "The event stream is opened with GET." );
	}

	if ( !( slack_chat.ready ?: false ) ) {
		streamError( 503, "not_configured", "The application is not configured yet." );
	}

	conversation_id = trim( url.conversationId ?: "" );

	// Prefer the token the session already holds. The query parameter exists for
	// reconnection after a session timeout and is checked against the same hash.
	session_token = structKeyExists( session, "conversations" ) && structKeyExists( session.conversations, conversation_id )
		? session.conversations[ conversation_id ]
		: "";

	access_token = len( session_token ) ? session_token : trim( url.accessToken ?: "" );

	try {
		conversation = slack_chat.stream.authorizeStream( conversation_id, access_token );
	} catch ( any authorization_error ) {
		streamError( 403, "access_denied", "This conversation requires a valid access token." );
	}

	// ------------------------------------------------------------------- headers

	cfheader( name = "Content-Type", value = "text/event-stream; charset=utf-8" );
	cfheader( name = "Cache-Control", value = "no-cache, no-store, no-transform, must-revalidate" );
	cfheader( name = "Connection", value = "keep-alive" );
	// Tells nginx and friends not to buffer, which would defeat the entire exercise.
	cfheader( name = "X-Accel-Buffering", value = "no" );
	cfcontent( type = "text/event-stream; charset=utf-8" );

	// ------------------------------------------------------------------ streaming

	last_event_id_header = trim( getHttpRequestData().headers[ "Last-Event-ID" ] ?: "" );
	cursor = slack_chat.stream.resolveCursor( last_event_id_header, trim( url.lastMessageId ?: "" ) );

	started_at = getTickCount();
	max_milliseconds = slack_chat.stream.getMaxSeconds() * 1000;
	poll_milliseconds = slack_chat.stream.getPollMilliseconds();
	heartbeat_interval = slack_chat.stream.getHeartbeatSeconds() * 1000;
	last_heartbeat_at = getTickCount();
	drain_counter = 0;

	// Named "ready" rather than "open" so it does not collide with the EventSource
	// object's own open event in the browser.
	writeOutput( slack_chat.stream.formatEvent( "ready", {
		"conversationId" : conversation.id,
		"cursor" : cursor,
		"status" : conversation.status,
		"maxSeconds" : slack_chat.stream.getMaxSeconds()
	} ) );
	cfflush();

	while ( ( getTickCount() - started_at ) < max_milliseconds ) {

		// Development convenience, switched off with app.auto_process_events. Drains
		// the inbound and outbound queues so the end-to-end test works without a
		// second terminal running the CommandBox task.
		drain_counter++;
		if ( drain_counter % 2 == 1 ) {
			slack_chat.stream.maybeProcessQueues();
		}

		try {
			new_messages = slack_chat.stream.getMessagesAfter( conversation.id, cursor );
		} catch ( any read_error ) {
			writeOutput( slack_chat.stream.formatEvent( "stream_error", { "message":"The message stream could not be read." } ) );
			cfflush();
			break;
		}

		for ( message in new_messages ) {
			writeOutput( slack_chat.stream.formatEvent( "message", message, message.id ) );
			cursor = message.id;
		}

		if ( arrayLen( new_messages ) ) {
			cfflush();
			last_heartbeat_at = getTickCount();
		} else if ( ( getTickCount() - last_heartbeat_at ) >= heartbeat_interval ) {
			writeOutput( slack_chat.stream.formatComment( "keepalive" ) );
			cfflush();
			last_heartbeat_at = getTickCount();
		}

		sleep( poll_milliseconds );
	}

	// A deliberate, orderly close. The browser sees this, then reconnects with
	// Last-Event-ID set to the final message it received.
	writeOutput( slack_chat.stream.formatEvent( "reconnect", { "cursor":cursor, "reason":"connection_lifetime_reached" } ) );
	cfflush();
</cfscript>
