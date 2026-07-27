/**
 * Translates internal exceptions into safe HTTP responses.
 *
 * Two rules. The browser gets a stable error code and a sentence a person can
 * act on. The log gets the type, message and detail. Nothing gets a stack trace,
 * a SQL statement or a connection string.
 *
 * Kept as a component rather than a handful of if statements inside each
 * endpoint so that the mapping is in one place and can be tested without an HTTP
 * request.
 */
component accessors="false" {

	/**
	 * Exception type -> { status_code, code, use_exception_message }.
	 *
	 * use_exception_message is true only where the thrown message was written
	 * for a person to read and is known to be free of internal detail.
	 */
	variables.error_map = {
		"Conversation.ValidationFailed" : { "status_code":400, "code":"validation_failed", "use_exception_message":true },
		"Conversation.AccessDenied" : { "status_code":403, "code":"access_denied", "use_exception_message":true },
		"Conversation.NotFound" : { "status_code":404, "code":"conversation_not_found", "use_exception_message":true },
		"Conversation.MessageNotFound" : { "status_code":404, "code":"message_not_found", "use_exception_message":true },
		"Conversation.Closed" : { "status_code":409, "code":"conversation_closed", "use_exception_message":true },
		"Configuration.Invalid" : { "status_code":503, "code":"not_configured", "use_exception_message":true },
		"Database.SchemaMissing" : { "status_code":503, "code":"schema_missing", "use_exception_message":true },
		"Slack.AuthenticationFailed" : { "status_code":502, "code":"slack_auth_failed", "use_exception_message":true },
		"Slack.ApiError" : { "status_code":502, "code":"slack_error", "use_exception_message":true },
		"Slack.RateLimited" : { "status_code":502, "code":"slack_rate_limited", "use_exception_message":true },
		"Slack.RequestFailed" : { "status_code":502, "code":"slack_unreachable", "use_exception_message":true },
		"Slack.InvalidResponse" : { "status_code":502, "code":"slack_invalid_response", "use_exception_message":true },
		"Slack.PostMessageFailed" : { "status_code":502, "code":"slack_post_failed", "use_exception_message":true }
	};

	public api_service function init( required any log_service ) {
		variables.log = arguments.log_service;
		return this;
	}

	/**
	 * Returns { status_code, body } ready to be serialized. Also writes the full
	 * exception to the log, because the browser is about to be told very little.
	 */
	public struct function describeError( required any exception, string context = "" ) {

		var exception_type = arguments.exception.type ?: "";
		var mapping = structKeyExists( variables.error_map, exception_type )
			? variables.error_map[ exception_type ]
			: { "status_code":500, "code":"internal_error", "use_exception_message":false };

		var fields = { "context":arguments.context, "error_code":mapping.code, "status_code":mapping.status_code };
		structAppend( fields, variables.log.describeException( arguments.exception ) );

		if ( mapping.status_code >= 500 ) {
			variables.log.error( "api.error", fields );
		} else {
			variables.log.warn( "api.error", fields );
		}

		var message = mapping.use_exception_message
			? ( arguments.exception.message ?: "The request could not be completed." )
			: "The request could not be completed. Check logs/slack-chat.log for details.";

		return {
			"status_code" : mapping.status_code,
			"body" : {
				"ok" : false,
				"error" : { "code":mapping.code, "message":redactSecrets( message ) }
			}
		};
	}

	public struct function validationError( required string message, string field = "" ) {
		return {
			"status_code" : 400,
			"body" : {
				"ok" : false,
				"error" : { "code":"validation_failed", "message":arguments.message, "field":arguments.field }
			}
		};
	}

	public string function statusTextFor( required numeric status_code ) {

		var texts = {
			"200" : "OK",
			"201" : "Created",
			"400" : "Bad Request",
			"403" : "Forbidden",
			"404" : "Not Found",
			"405" : "Method Not Allowed",
			"409" : "Conflict",
			"500" : "Internal Server Error",
			"502" : "Bad Gateway",
			"503" : "Service Unavailable"
		};

		return texts[ toString( arguments.status_code ) ] ?: "OK";
	}

	/**
	 * Last line of defence. If a token ever reaches an error string, it does not
	 * leave the building inside one.
	 */
	public string function redactSecrets( required string text ) {

		var clean = reReplaceNoCase( arguments.text, "xox[bpears]-[A-Za-z0-9\-]+", "[redacted token]", "all" );
		clean = reReplaceNoCase( clean, "password=[^;& ]*", "password=[redacted]", "all" );

		return clean;
	}

}
