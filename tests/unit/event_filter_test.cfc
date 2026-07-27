/**
 * Which Slack events become customer-visible support replies, and which do not.
 *
 * evaluateEvent() is pure, so every one of these runs without a database, a
 * network or a workspace. The payloads are shaped the way Slack actually sends
 * them, including the fields it leaves out.
 */
component extends="testbox.system.BaseSpec" {

	variables.channel_id = "C0123456789";
	variables.app_id = "A0123456789";
	variables.bot_user = "U000000BOT";

	function beforeAll() {

		variables.slack = new tests.support.stub_slack_service(
			default_channel = variables.channel_id,
			bot_user_id = variables.bot_user
		);

		variables.events = new slackchat.services.slack_event_service(
			database_service = createStub(),
			slack_service = variables.slack,
			conversation_service = createStub(),
			log_service = new tests.support.null_log_service(),
			configured_channel_id = variables.channel_id,
			configured_app_id = variables.app_id
		);
	}

	/** A well formed human thread reply, which individual specs then break. */
	private struct function buildCallback( struct event_overrides = {}, struct payload_overrides = {} ) {

		var event = {
			"type" : "message",
			"user" : "U9999999999",
			"text" : "Have you tried the export again?",
			"ts" : "1700000100.000200",
			"thread_ts" : "1700000000.000100",
			"channel" : variables.channel_id,
			"channel_type" : "channel"
		};

		structAppend( event, arguments.event_overrides, true );

		for ( var key in arguments.event_overrides ) {
			if ( isNull( arguments.event_overrides[ key ] ) ) {
				structDelete( event, key );
			}
		}

		var payload = {
			"type" : "event_callback",
			"api_app_id" : variables.app_id,
			"team_id" : "T0123456789",
			"event_id" : "Ev0PV52K21",
			"event_time" : 1700000100,
			"event" : event
		};

		structAppend( payload, arguments.payload_overrides, true );

		return payload;
	}

	function run() {

		describe( "events that become support replies", function () {

			it( "accepts a human reply inside a mapped thread", function () {
				var decision = events.evaluateEvent( buildCallback() );

				expect( decision.accept ).toBeTrue();
				expect( decision.channel ).toBe( channel_id );
				expect( decision.thread_ts ).toBe( "1700000000.000100" );
				expect( decision.message_ts ).toBe( "1700000100.000200" );
				expect( decision.user_id ).toBe( "U9999999999" );
				expect( decision.text ).toBe( "Have you tried the export again?" );
			} );

			it( "falls back to a generic sender name when Slack sends no profile", function () {
				expect( events.evaluateEvent( buildCallback() ).sender_name ).toBe( "Support" );
			} );

			it( "uses the display name when Slack includes a user profile", function () {
				var payload = buildCallback( { "user_profile":{ "display_name":"Alex", "real_name":"Alex Support" } } );

				expect( events.evaluateEvent( payload ).sender_name ).toBe( "Alex" );
			} );

			it( "falls back to the real name when the display name is blank", function () {
				var payload = buildCallback( { "user_profile":{ "display_name":"", "real_name":"Alex Support" } } );

				expect( events.evaluateEvent( payload ).sender_name ).toBe( "Alex Support" );
			} );

			it( "accepts a thread_broadcast, which is a real reply that was also sent to the channel", function () {
				var payload = buildCallback( { "subtype":"thread_broadcast" } );

				expect( events.evaluateEvent( payload ).accept ).toBeTrue();
			} );
		} );

		describe( "events that must be ignored", function () {

			it( "ignores anything that is not an event_callback", function () {
				var decision = events.evaluateEvent( { "type":"url_verification", "challenge":"abc" } );

				expect( decision.accept ).toBeFalse();
				expect( decision.reason ).toBe( "not_an_event_callback" );
			} );

			it( "ignores a callback with no inner event", function () {
				var decision = events.evaluateEvent( { "type":"event_callback", "event_id":"Ev1" } );

				expect( decision.accept ).toBeFalse();
				expect( decision.reason ).toBe( "no_inner_event" );
			} );

			it( "ignores non-message events such as reactions", function () {
				var decision = events.evaluateEvent( buildCallback( { "type":"reaction_added" } ) );

				expect( decision.accept ).toBeFalse();
				expect( decision.reason ).toBe( "not_a_message_event" );
			} );

			it( "ignores messages carrying a bot_id", function () {
				var decision = events.evaluateEvent( buildCallback( { "bot_id":"B0123456789" } ) );

				expect( decision.accept ).toBeFalse();
				expect( decision.reason ).toBe( "bot_message" );
			} );

			it( "ignores this application's own bot user", function () {
				var decision = events.evaluateEvent( buildCallback( { "user":bot_user } ) );

				expect( decision.accept ).toBeFalse();
				expect( decision.reason ).toBe( "own_bot_user" );
			} );

			it( "ignores message edits", function () {
				var decision = events.evaluateEvent( buildCallback( { "subtype":"message_changed" } ) );

				expect( decision.accept ).toBeFalse();
				expect( decision.reason ).toBe( "unsupported_subtype_message_changed" );
			} );

			it( "ignores message deletions", function () {
				var decision = events.evaluateEvent( buildCallback( { "subtype":"message_deleted" } ) );

				expect( decision.accept ).toBeFalse();
				expect( decision.reason ).toBe( "unsupported_subtype_message_deleted" );
			} );

			it( "ignores channel joins", function () {
				var decision = events.evaluateEvent( buildCallback( { "subtype":"channel_join" } ) );

				expect( decision.accept ).toBeFalse();
				expect( decision.reason ).toBe( "unsupported_subtype_channel_join" );
			} );

			it( "ignores top-level channel chatter with no thread", function () {
				var payload = buildCallback();
				structDelete( payload.event, "thread_ts" );

				var decision = events.evaluateEvent( payload );

				expect( decision.accept ).toBeFalse();
				expect( decision.reason ).toBe( "not_a_thread_reply" );
			} );

			it( "ignores the thread's own root message", function () {
				var decision = events.evaluateEvent( buildCallback( { "ts":"1700000000.000100" } ) );

				expect( decision.accept ).toBeFalse();
				expect( decision.reason ).toBe( "thread_root_message" );
			} );

			it( "ignores events from a different channel", function () {
				var decision = events.evaluateEvent( buildCallback( { "channel":"C9999999999" } ) );

				expect( decision.accept ).toBeFalse();
				expect( decision.reason ).toBe( "wrong_channel" );
			} );

			it( "ignores events attributed to a different Slack app", function () {
				var decision = events.evaluateEvent( buildCallback( {}, { "api_app_id":"A9999999999" } ) );

				expect( decision.accept ).toBeFalse();
				expect( decision.reason ).toBe( "wrong_app_id" );
			} );

			it( "ignores an event with no user", function () {
				var payload = buildCallback();
				structDelete( payload.event, "user" );

				var decision = events.evaluateEvent( payload );

				expect( decision.accept ).toBeFalse();
				expect( decision.reason ).toBe( "no_user" );
			} );

			it( "ignores an empty message", function () {
				var decision = events.evaluateEvent( buildCallback( { "text":" " } ) );

				expect( decision.accept ).toBeFalse();
				expect( decision.reason ).toBe( "empty_text" );
			} );

			it( "ignores an event with no message timestamp", function () {
				var payload = buildCallback();
				structDelete( payload.event, "ts" );

				var decision = events.evaluateEvent( payload );

				expect( decision.accept ).toBeFalse();
				expect( decision.reason ).toBe( "no_message_ts" );
			} );

			it( "never leaks partial data on a rejection", function () {
				var decision = events.evaluateEvent( buildCallback( { "bot_id":"B0123456789" } ) );

				expect( decision.text ).toBe( "" );
				expect( decision.channel ).toBe( "" );
				expect( decision.thread_ts ).toBe( "" );
			} );
		} );
	}

}
