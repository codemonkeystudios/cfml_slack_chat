/**
 * Line-delimited JSON logging for Slack traffic and event processing.
 *
 * One event per line, written to logs/slack-chat.log. Secrets are stripped on
 * the way in rather than trusted never to arrive: a log file is the easiest
 * place in any application to leak a bot token, and it is the one place nobody
 * checks before pasting output into an issue.
 */
component accessors="false" {

	variables.redacted_keys = [
		"token", "bot_token", "signing_secret", "authorization", "password",
		"access_token", "secret", "app_token", "verification_token", "client_secret"
	];

	/**
	 * @log_directory Where slack-chat.log is written.
	 * @log_message_bodies When false, message bodies are replaced by a length.
	 * @max_body_length Truncation limit when bodies are logged.
	 */
	public log_service function init(
		required string log_directory,
		boolean log_message_bodies = false,
		numeric max_body_length = 200
	) {
		variables.log_directory = arguments.log_directory;
		variables.log_file = arguments.log_directory & "/slack-chat.log";
		variables.log_message_bodies = arguments.log_message_bodies;
		variables.max_body_length = arguments.max_body_length;
		return this;
	}

	public void function info( required string category, struct fields = {} ) {
		writeEntry( "info", arguments.category, arguments.fields );
	}

	public void function warn( required string category, struct fields = {} ) {
		writeEntry( "warn", arguments.category, arguments.fields );
	}

	public void function error( required string category, struct fields = {} ) {
		writeEntry( "error", arguments.category, arguments.fields );
	}

	/** Record one outbound Slack API call. */
	public void function slackRequest( required struct fields ) {
		writeEntry( "info", "slack.outbound", arguments.fields );
	}

	/**
	 * Record one inbound Slack event, at any stage of its life: verification,
	 * queueing or processing.
	 */
	public void function slackEvent( required struct fields ) {
		writeEntry( "info", "slack.inbound", arguments.fields );
	}

	/**
	 * Turn a caught exception into a loggable struct without dragging the whole
	 * tag context, and whatever was in scope at the time, into the file.
	 */
	public struct function describeException( required any exception ) {
		return {
			"error_type" : arguments.exception.type ?: "unknown",
			"error_message" : left( arguments.exception.message ?: "", 500 ),
			"error_detail" : left( arguments.exception.detail ?: "", 500 )
		};
	}

	/**
	 * Apply the message-body policy. Callers pass the raw body; what comes back
	 * is whatever the operator agreed to have on disk.
	 */
	public any function bodyForLog( required string body ) {

		if ( !variables.log_message_bodies ) {
			return { "length":len( arguments.body ), "logged":false };
		}

		return left( arguments.body, variables.max_body_length );
	}

	public string function getLogFile() {
		return variables.log_file;
	}

	// --------------------------------------------------------------- internals

	private void function writeEntry( required string level, required string category, required struct fields ) {

		var entry = {
			"timestamp" : dateTimeFormat( dateConvert( "local2utc", now() ), "yyyy-mm-dd'T'HH:nn:ss'Z'" ),
			"level" : arguments.level,
			"category" : arguments.category
		};

		structAppend( entry, redact( arguments.fields ), true );

		try {
			if ( !directoryExists( variables.log_directory ) ) {
				directoryCreate( variables.log_directory, true );
			}

			lock name="slackChatLogWrite" type="exclusive" timeout="5" throwontimeout="false" {
				fileAppend( variables.log_file, serializeJSON( entry ) & chr( 10 ), "utf-8" );
			}

		} catch ( any e ) {
			// Logging must never take the request down with it.
			try {
				writeLog( type = "error", file = "slackchat", text = "Could not write to #variables.log_file#: #e.message#" );
			} catch ( any ignored ) {
			}
		}
	}

	private struct function redact( required struct fields ) {

		var clean = {};

		for ( var key in arguments.fields ) {

			var value = arguments.fields[ key ];

			if ( arrayFindNoCase( variables.redacted_keys, key ) ) {
				clean[ key ] = "[redacted]";
				continue;
			}

			if ( isStruct( value ) ) {
				clean[ key ] = redact( value );
			} else if ( isSimpleValue( value ) ) {
				clean[ key ] = left( value, 1000 );
			} else if ( isArray( value ) ) {
				clean[ key ] = value;
			} else {
				clean[ key ] = "[unloggable]";
			}
		}

		return clean;
	}

}
