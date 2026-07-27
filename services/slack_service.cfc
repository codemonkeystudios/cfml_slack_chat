/**
 * Everything that knows what Slack is.
 *
 * This component owns the API base URL, bearer authentication, JSON and form
 * encoding, response parsing, the "ok" check, and inbound request signature
 * verification. It knows nothing about conversations, tables or visitors, and it
 * must stay that way: the moment a table name appears in here, the next person
 * to integrate a different chat backend has to rewrite the wrong file.
 */
component accessors="false" {

	variables.api_base = "https://slack.com/api/";

	// Slack error codes that will never succeed on a retry.
	variables.permanent_errors = [
		"invalid_auth", "not_authed", "account_inactive", "token_revoked", "token_expired",
		"missing_scope", "channel_not_found", "not_in_channel", "is_archived",
		"invalid_arguments", "msg_too_long", "no_text", "restricted_action"
	];

	/**
	 * @bot_token Bot User OAuth Token (xoxb-...).
	 * @signing_secret Slack app signing secret.
	 * @default_channel Channel ID used when a caller does not name one.
	 * @log_service LogService instance.
	 * @timeout_seconds HTTP timeout for Slack calls.
	 * @signature_max_age_seconds Replay window for inbound requests.
	 * @bot_user_id This app's bot user ID, used to ignore its own messages.
	 */
	public slack_service function init(
		required string bot_token,
		required string signing_secret,
		required string default_channel,
		required any log_service,
		numeric timeout_seconds = 15,
		numeric signature_max_age_seconds = 300,
		string bot_user_id = ""
	) {
		variables.bot_token = arguments.bot_token;
		variables.signing_secret = arguments.signing_secret;
		variables.default_channel = arguments.default_channel;
		variables.log = arguments.log_service;
		variables.timeout_seconds = arguments.timeout_seconds;
		variables.signature_max_age_seconds = arguments.signature_max_age_seconds;
		variables.bot_user_id = arguments.bot_user_id;

		// Per-instance key for the double-HMAC comparison below.
		variables.compare_key = createUUID() & createUUID();

		return this;
	}

	public string function getBotUserId() {
		return variables.bot_user_id;
	}

	public void function setBotUserId( required string bot_user_id ) {
		variables.bot_user_id = arguments.bot_user_id;
	}

	public string function getDefaultChannel() {
		return variables.default_channel;
	}

	public numeric function getSignatureMaxAgeSeconds() {
		return variables.signature_max_age_seconds;
	}

	// ------------------------------------------------------------- Slack calls

	/**
	 * Post a message. With no thread_ts Slack creates a new top-level message
	 * and returns its ts, which becomes the conversation's thread identifier.
	 * With a thread_ts the message lands inside that thread.
	 */
	public struct function postMessage(
		required string text,
		string channel = "",
		string thread_ts = ""
	) {

		var target_channel = len( trim( arguments.channel ) ) ? arguments.channel : variables.default_channel;

		if ( !len( trim( target_channel ) ) ) {
			throw( type = "Slack.PostMessageFailed", message = "No Slack channel was supplied and no default channel is configured." );
		}

		var payload = {
			"channel" : target_channel,
			"text" : arguments.text
		};

		if ( len( trim( arguments.thread_ts ) ) ) {
			payload[ "thread_ts" ] = arguments.thread_ts;
		}

		return callApi( "chat.postMessage", payload );
	}

	/** Confirms the token works and tells us who this bot is. */
	public struct function authTest() {
		return callApiForm( "auth.test", {} );
	}

	/** Channel metadata, including whether the bot is actually in the room. */
	public struct function conversationsInfo( required string channel ) {
		return callApiForm( "conversations.info", { "channel":arguments.channel } );
	}

	public boolean function isPermanentError( required string slack_error ) {
		return arrayFindNoCase( variables.permanent_errors, arguments.slack_error ) > 0;
	}

	// -------------------------------------------------------- low-level client

	/** POST a JSON body. Used for methods that accept JSON, such as chat.postMessage. */
	public struct function callApi( required string method, required struct payload ) {
		return sendRequest(
			method = arguments.method,
			body = serializeJSON( arguments.payload ),
			content_type = "application/json; charset=utf-8"
		);
	}

	/** POST a form encoded body. Used for read methods, which do not accept JSON. */
	public struct function callApiForm( required string method, struct params = {} ) {

		var pairs = [];

		for ( var key in arguments.params ) {
			arrayAppend( pairs, urlEncodedFormat( key ) & "=" & urlEncodedFormat( arguments.params[ key ] ) );
		}

		return sendRequest(
			method = arguments.method,
			body = arrayToList( pairs, "&" ),
			content_type = "application/x-www-form-urlencoded; charset=utf-8"
		);
	}

	/**
	 * The single place an HTTP request leaves for Slack.
	 *
	 * Slack answers HTTP 200 for most failures and puts the real verdict in the
	 * "ok" field, so the status code on its own tells you almost nothing.
	 */
	private struct function sendRequest(
		required string method,
		required string body,
		required string content_type
	) {

		var started_at = getTickCount();
		var http_result = {};

		cfhttp(
			method = "POST",
			url = variables.api_base & arguments.method,
			charset = "utf-8",
			timeout = variables.timeout_seconds,
			throwonerror = false,
			result = "http_result"
		) {
			cfhttpparam( type = "header", name = "Authorization", value = "Bearer " & variables.bot_token );
			cfhttpparam( type = "header", name = "Content-Type", value = arguments.content_type );
			cfhttpparam( type = "header", name = "Accept", value = "application/json" );
			cfhttpparam( type = "body", value = arguments.body );
		}

		var duration_ms = getTickCount() - started_at;
		var status_text = http_result.statusCode ?: "";
		var status_code = val( status_text );
		var content = http_result.fileContent ?: "";

		content = isSimpleValue( content ) ? content : "";

		// CFML reports transport failures through the status text rather than by
		// throwing, so a timeout arrives looking like an empty response.
		if ( status_code == 0 || findNoCase( "Connection Failure", content ) || findNoCase( "Timeout", status_text ) ) {

			variables.log.slackRequest( {
				"slack_method" : arguments.method,
				"outcome" : "transport_failure",
				"http_status" : status_text,
				"duration_ms" : duration_ms
			} );

			throw(
				type = "Slack.RequestFailed",
				message = "The request to Slack method #arguments.method# did not complete.",
				detail = left( len( status_text ) ? status_text : "no status returned", 200 )
			);
		}

		if ( status_code == 429 ) {

			var retry_after = val( getResponseHeader( http_result, "Retry-After" ) );

			variables.log.slackRequest( {
				"slack_method" : arguments.method,
				"outcome" : "rate_limited",
				"http_status" : status_code,
				"retry_after" : retry_after,
				"duration_ms" : duration_ms
			} );

			throw(
				type = "Slack.RateLimited",
				message = "Slack rate limited method #arguments.method#.",
				detail = "Retry after #retry_after# seconds.",
				extendedinfo = serializeJSON( { "slack_error":"ratelimited", "retry_after":retry_after } )
			);
		}

		if ( !isJSON( content ) ) {

			variables.log.slackRequest( {
				"slack_method" : arguments.method,
				"outcome" : "invalid_response",
				"http_status" : status_code,
				"duration_ms" : duration_ms
			} );

			throw(
				type = "Slack.InvalidResponse",
				message = "Slack method #arguments.method# returned a response that was not JSON.",
				detail = "HTTP #status_code#. First 200 characters: " & left( content, 200 )
			);
		}

		var response = deserializeJSON( content );
		response[ "_http_status_code" ] = status_code;

		var slack_error = response.error ?: "";
		var is_ok = structKeyExists( response, "ok" ) && isBoolean( response.ok ) && response.ok;

		variables.log.slackRequest( {
			"slack_method" : arguments.method,
			"http_status" : status_code,
			"ok" : is_ok,
			"slack_error" : slack_error,
			"warning" : response.warning ?: "",
			"duration_ms" : duration_ms,
			"outcome" : is_ok ? "success" : "slack_error"
		} );

		if ( !is_ok ) {

			var exception_type = arrayFindNoCase( [ "invalid_auth", "not_authed", "account_inactive", "token_revoked", "token_expired" ], slack_error )
				? "Slack.AuthenticationFailed"
				: "Slack.ApiError";

			throw(
				type = exception_type,
				message = "Slack accepted the HTTP request but rejected method #arguments.method# with ""#slack_error#"".",
				detail = describeSlackError( slack_error ),
				extendedinfo = serializeJSON( {
					"slack_error" : slack_error,
					"slack_method" : arguments.method,
					"needed" : response.needed ?: "",
					"provided" : response.provided ?: ""
				} )
			);
		}

		return response;
	}

	private string function getResponseHeader( required struct http_result, required string name ) {

		var headers = arguments.http_result.responseHeader ?: {};

		if ( !structKeyExists( headers, arguments.name ) ) {
			return "";
		}

		var value = headers[ arguments.name ];
		return isArray( value ) ? value[ 1 ] : value;
	}

	/** Plain language for the Slack error codes an operator will actually hit. */
	public string function describeSlackError( required string slack_error ) {

		var explanations = {
			"invalid_auth" : "The bot token was rejected. Copy the Bot User OAuth Token again from OAuth & Permissions, and check you did not paste an app-level token by mistake.",
			"not_authed" : "No token reached Slack. The bot token is missing from the configuration.",
			"account_inactive" : "The token belongs to a deactivated account or an uninstalled app.",
			"token_revoked" : "The token has been revoked. Reinstall the app to the workspace.",
			"missing_scope" : "The app is installed but lacks a required OAuth scope. Add the scope, reinstall the app, then copy the new token.",
			"channel_not_found" : "Slack does not recognise that channel ID. Check that you used the ID from View channel details rather than the channel name.",
			"not_in_channel" : "The bot authenticated but is not a member of that channel. Invite it with /invite @your-bot-name.",
			"is_archived" : "That channel is archived. Slack will not accept new messages in it.",
			"msg_too_long" : "The message exceeded Slack's length limit.",
			"no_text" : "Slack received an empty message.",
			"ratelimited" : "Slack is rate limiting this app. Slow down and respect the Retry-After header.",
			"invalid_arguments" : "Slack rejected the request arguments. This usually means a malformed channel ID or thread timestamp."
		};

		return structKeyExists( explanations, arguments.slack_error )
			? explanations[ arguments.slack_error ]
			: "Slack returned the error code ""#arguments.slack_error#"".";
	}

	// --------------------------------------------------- request verification

	/**
	 * Verify an inbound Slack request.
	 *
	 * Returns { valid:boolean, reason:string }. The reason is for the log, not
	 * for the response body: telling an attacker precisely which check they
	 * failed is a courtesy nobody asked for.
	 */
	public struct function verifyRequest(
		required string raw_body,
		required string signature,
		required string timestamp,
		numeric max_age_seconds = 0
	) {

		var max_age = arguments.max_age_seconds > 0 ? arguments.max_age_seconds : variables.signature_max_age_seconds;

		if ( !len( trim( variables.signing_secret ) ) ) {
			return { "valid":false, "reason":"no_signing_secret_configured" };
		}

		if ( !len( trim( arguments.signature ) ) ) {
			return { "valid":false, "reason":"missing_signature_header" };
		}

		if ( !len( trim( arguments.timestamp ) ) ) {
			return { "valid":false, "reason":"missing_timestamp_header" };
		}

		if ( !reFind( "^[0-9]+$", trim( arguments.timestamp ) ) ) {
			return { "valid":false, "reason":"non_numeric_timestamp" };
		}

		var current_epoch = createObject( "java", "java.time.Instant" ).now().getEpochSecond();
		var age_seconds = current_epoch - javaCast( "long", trim( arguments.timestamp ) );

		if ( abs( age_seconds ) > max_age ) {
			return { "valid":false, "reason":age_seconds > 0 ? "stale_timestamp" : "future_timestamp" };
		}

		var expected_signature = buildSignature( arguments.timestamp, arguments.raw_body );

		if ( !timingSafeEquals( expected_signature, trim( arguments.signature ) ) ) {
			return { "valid":false, "reason":"signature_mismatch" };
		}

		return { "valid":true, "reason":"" };
	}

	/** The v0 signature Slack should have sent for this timestamp and body. */
	public string function buildSignature( required string timestamp, required string raw_body ) {

		var signature_base = "v0:" & trim( arguments.timestamp ) & ":" & arguments.raw_body;

		return "v0=" & lCase( hmac( signature_base, variables.signing_secret, "HmacSHA256", "utf-8" ) );
	}

	/**
	 * Constant-time string comparison.
	 *
	 * Both values run through a keyed HMAC first. That normalises the length, so
	 * the loop below cannot leak it, and it means an attacker cannot steer the
	 * comparison, because the key is random and per-instance.
	 */
	public boolean function timingSafeEquals( required string expected, required string provided ) {

		var expected_digest = hmac( arguments.expected, variables.compare_key, "HmacSHA256", "utf-8" );
		var provided_digest = hmac( arguments.provided, variables.compare_key, "HmacSHA256", "utf-8" );

		var difference = 0;

		for ( var index = 1; index <= len( expected_digest ); index++ ) {
			difference = bitOr(
				difference,
				bitXor( asc( mid( expected_digest, index, 1 ) ), asc( mid( provided_digest, index, 1 ) ) )
			);
		}

		return difference == 0;
	}

	// ------------------------------------------------------ message formatting

	/**
	 * The root message that opens a support thread. Enough context for whoever
	 * picks it up, and no decorative metadata for its own sake.
	 */
	public string function formatConversationOpener(
		required string visitor_name,
		required string visitor_email,
		required string conversation_id,
		required string body
	) {
		return "*New support conversation*" & chr( 10 )
		 & "Visitor: " & escapeText( arguments.visitor_name ) & " <" & escapeText( arguments.visitor_email ) & ">" & chr( 10 )
		 & "Conversation: `" & escapeText( arguments.conversation_id ) & "`" & chr( 10 )
		 & chr( 10 )
		 & escapeText( arguments.body ) & chr( 10 )
		 & chr( 10 )
		 & "_Reply in this thread and the visitor sees it in their browser._";
	}

	/** A later customer message, posted into the existing thread. */
	public string function formatCustomerReply( required string visitor_name, required string body ) {
		return "*" & escapeText( arguments.visitor_name ) & "* wrote:" & chr( 10 ) & escapeText( arguments.body );
	}

	/**
	 * Slack's minimal escaping rules for message text. This is also what stops a
	 * visitor from typing a channel-wide notification into your support room.
	 */
	public string function escapeText( required string value ) {

		var escaped = replace( arguments.value, "&", "&amp;", "all" );
		escaped = replace( escaped, "<", "&lt;", "all" );
		escaped = replace( escaped, ">", "&gt;", "all" );

		return escaped;
	}

}
