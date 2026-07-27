<cfsetting enablecfoutputonly="true" showdebugoutput="false">
<cfscript>
	/**
	* Slack Events API endpoint.
	*
	* The entire job of this file:
	*
	* 1. Read the exact raw body.
	* 2. Verify the signature before trusting a single field in it.
	* 3. Answer the url_verification challenge.
	* 4. Store the event durably and idempotently.
	* 5. Return, quickly.
	*
	* Slack expects an acknowledgement within three seconds and retries anything
	* slower or unsuccessful. Filtering, conversation lookup, message insertion and
	* browser delivery all happen later, in SlackEventService.processPendingEvents().
	* An endpoint that did that work inline would still be thinking about it while
	* Slack sent the same event again.
	*/

	// -------------------------------------------------------------------- helpers

	string function statusTextFor( required numeric status_code ) {

		var texts = {
			"200" : "OK",
			"400" : "Bad Request",
			"401" : "Unauthorized",
			"405" : "Method Not Allowed",
			"500" : "Internal Server Error",
			"503" : "Service Unavailable"
		};

		return texts[ toString( arguments.status_code ) ] ?: "OK";
	}

	void function respondJson( required numeric status_code, required struct body ) {
		cfheader( statuscode = arguments.status_code, statustext = statusTextFor( arguments.status_code ) );
		cfcontent( type = "application/json; charset=utf-8", variable = charsetDecode( serializeJSON( arguments.body ), "utf-8" ) );
		abort;
	}

	// ---------------------------------------------------------------- entry point

	request_data = getHttpRequestData();
	slack_chat = application.slack_chat;

	if ( ( cgi.request_method ?: "" ) != "POST" ) {
		respondJson( 405, { "ok":false, "error":"method_not_allowed" } );
	}

	// Slack signs the exact bytes it sent. Parsing first and re-serializing would
	// produce a different string, and a signature that never matches.
	raw_body = isBinary( request_data.content )
		? charsetEncode( request_data.content, "utf-8" )
		: toString( request_data.content );

	headers = request_data.headers ?: {};
	slack_signature = structKeyExists( headers, "X-Slack-Signature" ) ? headers[ "X-Slack-Signature" ] : "";
	slack_timestamp = structKeyExists( headers, "X-Slack-Request-Timestamp" ) ? headers[ "X-Slack-Request-Timestamp" ] : "";
	retry_num = val( structKeyExists( headers, "X-Slack-Retry-Num" ) ? headers[ "X-Slack-Retry-Num" ] : 0 );

	if ( !structKeyExists( slack_chat, "slack" ) ) {
		slack_chat.log.slackEvent( {
			"stage" : "verification",
			"verification_result" : "rejected",
			"reason" : "application_not_configured"
		} );
		respondJson( 503, { "ok":false, "error":"not_configured" } );
	}

	// -------------------------------------------------------------- verification

	verification = slack_chat.slack.verifyRequest(
		raw_body = raw_body,
		signature = slack_signature,
		timestamp = slack_timestamp
	);

	if ( !verification.valid ) {

		slack_chat.log.slackEvent( {
			"stage" : "verification",
			"verification_result" : "rejected",
			"reason" : verification.reason,
			"body_length" : len( raw_body ),
			"retry_num" : retry_num
		} );

		// Deliberately generic. The log knows which check failed; the caller does not
		// need a diagnostic aid for guessing signatures.
		respondJson( 401, { "ok":false, "error":"unauthorized" } );
	}

	// ---------------------------------------------------------------- parse body

	if ( !isJSON( raw_body ) ) {
		slack_chat.log.slackEvent( {
			"stage" : "verification",
			"verification_result" : "accepted",
			"reason" : "payload_not_json"
		} );
		respondJson( 400, { "ok":false, "error":"invalid_payload" } );
	}

	payload = deserializeJSON( raw_body );
	payload_type = payload.type ?: "";

	// ----------------------------------------------------------- url verification

	// Slack sends this once, when the Request URL is saved. It wants the challenge
	// value back as plain text and nothing else.
	if ( payload_type == "url_verification" && structKeyExists( payload, "challenge" ) ) {

		slack_chat.log.slackEvent( {
			"stage" : "verification",
			"event_type" : "url_verification",
			"verification_result" : "accepted",
			"queue_result" : "challenge_answered"
		} );

		cfheader( statuscode = 200, statustext = "OK" );
		cfcontent( type = "text/plain; charset=utf-8", variable = charsetDecode( payload.challenge, "utf-8" ) );
		abort;
	}

	// ------------------------------------------------------------- event callback

	if ( payload_type != "event_callback" ) {
		slack_chat.log.slackEvent( {
			"stage" : "verification",
			"event_type" : payload_type,
			"verification_result" : "accepted",
			"queue_result" : "ignored_payload_type"
		} );
		respondJson( 200, { "ok":true } );
	}

	try {
		slack_chat.events.enqueueEvent( raw_body = raw_body, payload = payload, headers = headers );

	} catch ( Slack.MissingEventId missing_id ) {
		// Nothing to deduplicate on. Accept it so Slack stops retrying, and record
		// why it went nowhere.
		slack_chat.log.warn( "slack.eventRejected", { "reason":"missing_event_id" } );
		respondJson( 200, { "ok":true } );

	} catch ( any enqueue_error ) {
		error_fields = { "stage":"queued", "queue_result":"failed" };
		structAppend( error_fields, slack_chat.log.describeException( enqueue_error ) );
		slack_chat.log.error( "slack.enqueueFailed", error_fields );

		// A 500 tells Slack to retry, which is exactly what should happen when the
		// database was briefly unavailable.
		respondJson( 500, { "ok":false, "error":"queue_failed" } );
	}

	respondJson( 200, { "ok":true } );
</cfscript>
