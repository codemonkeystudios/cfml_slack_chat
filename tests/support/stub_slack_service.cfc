/**
 * A Slack service that never reaches Slack.
 *
 * Extends the real component so that message formatting, escaping, error
 * classification and signature verification are the genuine implementations.
 * Only postMessage() is replaced, because that is the one method whose real
 * behaviour depends on a workspace existing.
 *
 * Every call is recorded, which is what lets the delivery specs assert that the
 * first message opened a thread and every later message joined it.
 */
component extends="slackchat.services.slack_service" accessors="false" {

	public stub_slack_service function init(
		string default_channel = "C0123456789",
		string bot_user_id = "U000000BOT"
	) {

		super.init(
			bot_token = "xoxb-stub",
			signing_secret = "8f742231b10e4a1cbc4a4ff5a1234567",
			default_channel = arguments.default_channel,
			log_service = new tests.support.null_log_service(),
			bot_user_id = arguments.bot_user_id
		);

		variables.calls = [];
		variables.next_timestamp = 1700000000;
		variables.failure_type = "";
		variables.failure_slack_code = "";

		return this;
	}

	public array function getCalls() {
		return variables.calls;
	}

	public numeric function getCallCount() {
		return arrayLen( variables.calls );
	}

	/** Make the next and every subsequent postMessage() throw. */
	public void function failWith( required string exception_type, string slack_error = "" ) {
		variables.failure_type = arguments.exception_type;
		variables.failure_slack_code = arguments.slack_error;
	}

	public void function succeed() {
		variables.failure_type = "";
		variables.failure_slack_code = "";
	}

	public struct function postMessage(
		required string text,
		string channel = "",
		string thread_ts = ""
	) {

		var target_channel = len( trim( arguments.channel ) ) ? arguments.channel : getDefaultChannel();

		arrayAppend( variables.calls, {
			"text" : arguments.text,
			"channel" : target_channel,
			"thread_ts" : arguments.thread_ts,
			"is_root" : !len( trim( arguments.thread_ts ) )
		} );

		if ( len( variables.failure_type ) ) {
			throw(
				type = variables.failure_type,
				message = "Stubbed Slack failure: " & variables.failure_slack_code,
				extendedinfo = serializeJSON( { "slack_error":variables.failure_slack_code } )
			);
		}

		variables.next_timestamp++;

		return {
			"ok" : true,
			"channel" : target_channel,
			"ts" : toString( variables.next_timestamp ) & ".000100",
			"_http_status_code" : 200
		};
	}

}
