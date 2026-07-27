/**
 * The inbound path: queueing Slack events and turning them into support replies.
 *
 * The interesting cases are the repeated ones. Slack retries, and a customer
 * seeing the same reply twice is a worse outcome than seeing it slightly late.
 */
component extends="tests.integration.integration_base" {

	function afterAll() {
		tearDownData();
	}

	/** A conversation with a Slack thread already attached. */
	private struct function createThreadedConversation( required string thread_ts ) {

		var created = createTestConversation();
		conversations.attachSlackThread( created.conversation_id, channel_id, arguments.thread_ts );

		return created;
	}

	function run() {

		describe( title = "enqueueEvent()", skip = integrationSkipped(), body = function () {

			it( "stores a verified event callback", function () {
				var event_id = "Ev" & replace( createUUID(), "-", "", "all" );
				rememberEvent( event_id );

				var payload = buildEventCallback( event_id, "1700000000.100100", "1700000100.100200" );
				var result = events.enqueueEvent( serializeJSON( payload ), payload );

				expect( result.stored ).toBeTrue();
				expect( result.duplicate ).toBeFalse();
				expect( result.event_id ).toBe( event_id );
			} );

			it( "treats a repeated delivery of the same event_id as a duplicate", function () {
				var event_id = "Ev" & replace( createUUID(), "-", "", "all" );
				rememberEvent( event_id );

				var payload = buildEventCallback( event_id, "1700000000.100300", "1700000100.100400" );

				events.enqueueEvent( serializeJSON( payload ), payload );
				var second = events.enqueueEvent( serializeJSON( payload ), payload, { "X-Slack-Retry-Num":"1", "X-Slack-Retry-Reason":"http_timeout" } );

				expect( second.duplicate ).toBeTrue();

				var stored = db.run(
					"select count(*) as total from slack_event_inbox where event_id = :event_id",
					{ "event_id":{ value:event_id, cfsqltype:"cf_sql_varchar" } }
				);

				expect( stored.total ).toBe( 1 );
			} );

			it( "records Slack's retry metadata", function () {
				var event_id = "Ev" & replace( createUUID(), "-", "", "all" );
				rememberEvent( event_id );

				var payload = buildEventCallback( event_id, "1700000000.100500", "1700000100.100600" );
				events.enqueueEvent( serializeJSON( payload ), payload, { "X-Slack-Retry-Num":"2", "X-Slack-Retry-Reason":"http_error" } );

				var stored = db.run(
					"select retry_num, retry_reason, raw_body from slack_event_inbox where event_id = :event_id",
					{ "event_id":{ value:event_id, cfsqltype:"cf_sql_varchar" } }
				);

				expect( stored.retry_num ).toBe( 2 );
				expect( stored.retry_reason ).toBe( "http_error" );
			} );

			it( "keeps the exact raw body it was given", function () {
				var event_id = "Ev" & replace( createUUID(), "-", "", "all" );
				rememberEvent( event_id );

				var payload = buildEventCallback( event_id, "1700000000.100700", "1700000100.100800" );
				var raw_body = serializeJSON( payload );

				events.enqueueEvent( raw_body, payload );

				var stored = db.run(
					"select raw_body from slack_event_inbox where event_id = :event_id",
					{ "event_id":{ value:event_id, cfsqltype:"cf_sql_varchar" } }
				);

				expect( stored.raw_body ).toBe( raw_body );
			} );

			it( "refuses a callback with no event_id, because there is nothing to deduplicate on", function () {
				expect( function () {
					events.enqueueEvent( "{}", { "type":"event_callback" } );
				} ).toThrow( type = "Slack.MissingEventId" );
			} );
		} );

		describe( title = "processPendingEvents()", skip = integrationSkipped(), body = function () {

			it( "turns a mapped thread reply into a support message", function () {
				var created = createThreadedConversation( "1700000000.200100" );
				var event_id = "Ev" & replace( createUUID(), "-", "", "all" );
				rememberEvent( event_id );

				var payload = buildEventCallback( event_id, "1700000000.200100", "1700000100.200200", "Can you send the export log?" );
				events.enqueueEvent( serializeJSON( payload ), payload );

				var summary = events.processPendingEvents();
				var messages = conversations.getMessagesAfter( created.conversation_id, created.message_id );

				expect( summary.processed ).toBeGTE( 1 );
				expect( arrayLen( messages ) ).toBe( 1 );
				expect( messages[ 1 ].senderType ).toBe( "support" );
				expect( messages[ 1 ].source ).toBe( "slack" );
				expect( messages[ 1 ].body ).toBe( "Can you send the export log?" );
			} );

			it( "marks the event processed", function () {
				var created = createThreadedConversation( "1700000000.200300" );
				var event_id = "Ev" & replace( createUUID(), "-", "", "all" );
				rememberEvent( event_id );

				var payload = buildEventCallback( event_id, "1700000000.200300", "1700000100.200400" );
				events.enqueueEvent( serializeJSON( payload ), payload );
				events.processPendingEvents();

				expect( eventStatus( event_id ) ).toBe( "processed" );
			} );

			it( "does not create a second message when the same event is processed again", function () {
				var created = createThreadedConversation( "1700000000.200500" );
				var event_id = "Ev" & replace( createUUID(), "-", "", "all" );
				rememberEvent( event_id );

				var payload = buildEventCallback( event_id, "1700000000.200500", "1700000100.200600" );
				events.enqueueEvent( serializeJSON( payload ), payload );
				events.processPendingEvents();

				// Push the row back to pending, the way a crashed worker would leave it.
				db.run(
					"update slack_event_inbox set status = 'pending' where event_id = :event_id",
					{ "event_id":{ value:event_id, cfsqltype:"cf_sql_varchar" } }
				);

				events.processPendingEvents();

				expect( arrayLen( conversations.getMessagesAfter( created.conversation_id, created.message_id ) ) ).toBe( 1 );
			} );

			it( "does not create a second message when Slack sends the same reply under a new event id", function () {
				var created = createThreadedConversation( "1700000000.200700" );

				for ( var index = 1; index <= 2; index++ ) {
					var event_id = "Ev" & replace( createUUID(), "-", "", "all" );
					rememberEvent( event_id );

					var payload = buildEventCallback( event_id, "1700000000.200700", "1700000100.200800", "Duplicated reply" );
					events.enqueueEvent( serializeJSON( payload ), payload );
					events.processPendingEvents();
				}

				expect( arrayLen( conversations.getMessagesAfter( created.conversation_id, created.message_id ) ) ).toBe( 1 );
			} );

			it( "ignores a reply in a thread that maps to no conversation", function () {
				var event_id = "Ev" & replace( createUUID(), "-", "", "all" );
				rememberEvent( event_id );

				var payload = buildEventCallback( event_id, "1700000000.999111", "1700000100.999222" );
				events.enqueueEvent( serializeJSON( payload ), payload );
				events.processPendingEvents();

				expect( eventStatus( event_id ) ).toBe( "ignored" );
				expect( eventError( event_id ) ).toBe( "no_matching_conversation" );
			} );

			it( "ignores a bot message without saving anything", function () {
				var created = createThreadedConversation( "1700000000.201000" );
				var event_id = "Ev" & replace( createUUID(), "-", "", "all" );
				rememberEvent( event_id );

				var payload = buildEventCallback( event_id, "1700000000.201000", "1700000100.201100" );
				payload.event[ "bot_id" ] = "B0123456789";

				events.enqueueEvent( serializeJSON( payload ), payload );
				events.processPendingEvents();

				expect( eventStatus( event_id ) ).toBe( "ignored" );
				expect( eventError( event_id ) ).toBe( "bot_message" );
				expect( arrayLen( conversations.getMessagesAfter( created.conversation_id, created.message_id ) ) ).toBe( 0 );
			} );

			it( "ignores a reply posted in a different channel", function () {
				var created = createThreadedConversation( "1700000000.201200" );
				var event_id = "Ev" & replace( createUUID(), "-", "", "all" );
				rememberEvent( event_id );

				var payload = buildEventCallback( event_id, "1700000000.201200", "1700000100.201300", "Wrong room", "C0SOMEWHEREELSE" );
				events.enqueueEvent( serializeJSON( payload ), payload );
				events.processPendingEvents();

				expect( eventStatus( event_id ) ).toBe( "ignored" );
				expect( arrayLen( conversations.getMessagesAfter( created.conversation_id, created.message_id ) ) ).toBe( 0 );
			} );

			it( "records the Slack user and message timestamp against the saved reply", function () {
				var created = createThreadedConversation( "1700000000.201400" );
				var event_id = "Ev" & replace( createUUID(), "-", "", "all" );
				rememberEvent( event_id );

				var payload = buildEventCallback( event_id, "1700000000.201400", "1700000100.201500" );
				events.enqueueEvent( serializeJSON( payload ), payload );
				events.processPendingEvents();

				var stored = db.run(
					"select sender_id, slack_message_ts, slack_event_id from conversation_message
					 where conversation_id = :conversation_id and sender_type = 'support'",
					{ "conversation_id":{ value:created.conversation_id, cfsqltype:"cf_sql_varchar" } }
				);

				expect( stored.sender_id ).toBe( "U9999999999" );
				expect( stored.slack_message_ts ).toBe( "1700000100.201500" );
				expect( stored.slack_event_id ).toBe( event_id );
			} );

			it( "leaves nothing pending after a sweep", function () {
				var created = createThreadedConversation( "1700000000.201600" );
				var event_id = "Ev" & replace( createUUID(), "-", "", "all" );
				rememberEvent( event_id );

				var payload = buildEventCallback( event_id, "1700000000.201600", "1700000100.201700" );
				events.enqueueEvent( serializeJSON( payload ), payload );
				events.processPendingEvents();

				expect( eventStatus( event_id ) ).notToBe( "pending" );
				expect( eventStatus( event_id ) ).notToBe( "processing" );
			} );
		} );

		describe( title = "the full inbound round trip", skip = integrationSkipped(), body = function () {

			it( "delivers a customer message, then a support reply, in one ordered stream", function () {
				var created = createTestConversation( body = "The export stops at ninety percent." );

				deliveries.processPendingDeliveries( created.conversation_id );

				var thread_ts = conversations.getConversation( created.conversation_id ).slackThreadTs;
				var event_id = "Ev" & replace( createUUID(), "-", "", "all" );
				rememberEvent( event_id );

				var payload = buildEventCallback( event_id, thread_ts, "1700000100.300100", "Send me the log and I will take a look." );
				events.enqueueEvent( serializeJSON( payload ), payload );
				events.processPendingEvents();

				var messages = conversations.getMessagesAfter( created.conversation_id, 0 );

				expect( arrayLen( messages ) ).toBe( 2 );
				expect( messages[ 1 ].senderType ).toBe( "customer" );
				expect( messages[ 2 ].senderType ).toBe( "support" );
				expect( messages[ 2 ].id ).toBeGT( messages[ 1 ].id );
			} );
		} );
	}

	// ------------------------------------------------------------------ helpers

	private string function eventStatus( required string event_id ) {

		var found = db.run(
			"select status from slack_event_inbox where event_id = :event_id",
			{ "event_id":{ value:arguments.event_id, cfsqltype:"cf_sql_varchar" } }
		);

		return found.recordCount ? found.status : "";
	}

	private string function eventError( required string event_id ) {

		var found = db.run(
			"select last_error from slack_event_inbox where event_id = :event_id",
			{ "event_id":{ value:arguments.event_id, cfsqltype:"cf_sql_varchar" } }
		);

		return found.recordCount ? ( found.last_error ?: "" ) : "";
	}

}
