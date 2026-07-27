/**
 * Outbound delivery: opening a thread, replying into it, and surviving failure.
 *
 * The Slack service is stubbed at the HTTP boundary only. Formatting, escaping
 * and error classification are the real implementations, so what these specs
 * assert about thread_ts is what the application really does.
 */
component extends="tests.integration.integration_base" {

	function afterAll() {
		tearDownData();
	}

	function run() {

		describe( title = "the first message of a conversation", skip = integrationSkipped(), body = function () {

			it( "posts a root message with no thread timestamp", function () {
				var created = createTestConversation();

				deliveries.processPendingDeliveries( created.conversation_id );

				var calls = slack.getCalls();
				var last = calls[ arrayLen( calls ) ];

				expect( last.is_root ).toBeTrue();
				expect( last.thread_ts ).toBe( "" );
				expect( last.channel ).toBe( channel_id );
			} );

			it( "stores the channel and timestamp Slack returned", function () {
				var created = createTestConversation();

				deliveries.processPendingDeliveries( created.conversation_id );

				var conversation = conversations.getConversation( created.conversation_id );

				expect( conversation.slackChannelId ).toBe( channel_id );
				expect( conversation.slackThreadTs ).notToBeEmpty();
			} );

			it( "includes the visitor and conversation context support will need", function () {
				var created = createTestConversation(
					visitor_name = "Dana Visitor",
					visitor_email = "dana@example.com",
					body = "The export stops at ninety percent."
				);

				deliveries.processPendingDeliveries( created.conversation_id );

				var calls = slack.getCalls();
				var text = calls[ arrayLen( calls ) ].text;

				expect( text ).toInclude( "Dana Visitor" );
				expect( text ).toInclude( "dana@example.com" );
				expect( text ).toInclude( created.conversation_id );
				expect( text ).toInclude( "The export stops at ninety percent." );
				expect( text ).toInclude( "thread" );
			} );

			it( "escapes visitor content on the way into Slack", function () {
				var created = createTestConversation( body = "<!channel> please look & fix this <now>" );

				deliveries.processPendingDeliveries( created.conversation_id );

				var calls = slack.getCalls();
				var text = calls[ arrayLen( calls ) ].text;

				expect( text ).notToInclude( "<!channel>" );
				expect( text ).toInclude( "&lt;!channel&gt;" );
			} );

			it( "marks the delivery sent", function () {
				var created = createTestConversation();

				deliveries.processPendingDeliveries( created.conversation_id );

				expect( conversations.getDeliveryStatus( created.conversation_id ).summary ).toBe( "sent" );
			} );
		} );

		describe( title = "later messages in the same conversation", skip = integrationSkipped(), body = function () {

			it( "post into the stored thread rather than opening a new one", function () {
				var created = createTestConversation();
				deliveries.processPendingDeliveries( created.conversation_id );

				var thread_ts = conversations.getConversation( created.conversation_id ).slackThreadTs;

				conversations.addCustomerMessage( created.conversation_id, created.access_token, "Any update?" );
				deliveries.processPendingDeliveries( created.conversation_id );

				var calls = slack.getCalls();
				var last = calls[ arrayLen( calls ) ];

				expect( last.is_root ).toBeFalse();
				expect( last.thread_ts ).toBe( thread_ts );
			} );

			it( "never create a second root message", function () {
				var created = createTestConversation();
				deliveries.processPendingDeliveries( created.conversation_id );

				var root_calls_before = countRootCalls();

				for ( var index = 1; index <= 3; index++ ) {
					conversations.addCustomerMessage( created.conversation_id, created.access_token, "Follow up " & index );
					deliveries.processPendingDeliveries( created.conversation_id );
				}

				expect( countRootCalls() ).toBe( root_calls_before );
			} );

			it( "keep the conversation's thread timestamp unchanged", function () {
				var created = createTestConversation();
				deliveries.processPendingDeliveries( created.conversation_id );

				var original_thread_ts = conversations.getConversation( created.conversation_id ).slackThreadTs;

				conversations.addCustomerMessage( created.conversation_id, created.access_token, "Still here" );
				deliveries.processPendingDeliveries( created.conversation_id );

				expect( conversations.getConversation( created.conversation_id ).slackThreadTs ).toBe( original_thread_ts );
			} );

			it( "wait for the root message rather than racing ahead of it", function () {
				var created = createTestConversation();

				// Queue a second message while the first is still undelivered.
				conversations.addCustomerMessage( created.conversation_id, created.access_token, "Actually, one more thing" );

				var summary = deliveries.processPendingDeliveries( created.conversation_id );

				// The first opened the thread; the second was deferred because it
				// was claimed before the thread existed.
				expect( summary.sent + summary.deferred ).toBe( 2 );
				expect( countRootCallsFor( created.conversation_id ) ).toBeLTE( 1 );
			} );
		} );

		describe( title = "when Slack refuses the message", skip = integrationSkipped(), body = function () {

			it( "keeps the customer's message exactly where it was", function () {
				var created = createTestConversation( body = "This one will not reach Slack." );

				slack.failWith( "Slack.ApiError", "not_in_channel" );
				deliveries.processPendingDeliveries( created.conversation_id );
				slack.succeed();

				var messages = conversations.getMessagesAfter( created.conversation_id, 0 );

				expect( arrayLen( messages ) ).toBe( 1 );
				expect( messages[ 1 ].body ).toBe( "This one will not reach Slack." );
			} );

			it( "reports the failure honestly instead of claiming success", function () {
				var created = createTestConversation();

				slack.failWith( "Slack.ApiError", "not_in_channel" );
				deliveries.processPendingDeliveries( created.conversation_id );
				slack.succeed();

				expect( conversations.getDeliveryStatus( created.conversation_id ).summary ).notToBe( "sent" );
			} );

			it( "gives up on a permanent error rather than retrying forever", function () {
				var created = createTestConversation();

				slack.failWith( "Slack.ApiError", "channel_not_found" );
				deliveries.processPendingDeliveries( created.conversation_id );
				slack.succeed();

				expect( conversations.getDeliveryStatus( created.conversation_id ).counts.abandoned ).toBe( 1 );
			} );

			it( "keeps a transient failure queued for another attempt", function () {
				var created = createTestConversation();

				slack.failWith( "Slack.RequestFailed", "" );
				deliveries.processPendingDeliveries( created.conversation_id );
				slack.succeed();

				var counts = conversations.getDeliveryStatus( created.conversation_id ).counts;

				expect( counts.failed ).toBe( 1 );
				expect( counts.abandoned ).toBe( 0 );
			} );

			it( "leaves the conversation without a Slack thread, so a retry still opens one", function () {
				var created = createTestConversation();

				slack.failWith( "Slack.RequestFailed", "" );
				deliveries.processPendingDeliveries( created.conversation_id );
				slack.succeed();

				expect( conversations.getConversation( created.conversation_id ).slackThreadTs ).toBe( "" );
			} );

			it( "delivers successfully once Slack recovers, without duplicating the conversation", function () {
				var created = createTestConversation();

				slack.failWith( "Slack.RequestFailed", "" );
				deliveries.processPendingDeliveries( created.conversation_id );
				slack.succeed();

				// Clear the backoff the way a later sweep would find it.
				db.run(
					"update slack_outbound_delivery set next_attempt_at = :now where conversation_id = :conversation_id",
					{
						"now" : { value:db.utcNow(), cfsqltype:"cf_sql_timestamp" },
						"conversation_id" : { value:created.conversation_id, cfsqltype:"cf_sql_varchar" }
					}
				);

				deliveries.processPendingDeliveries( created.conversation_id );

				expect( conversations.getConversation( created.conversation_id ).slackThreadTs ).notToBeEmpty();
				expect( conversations.getDeliveryStatus( created.conversation_id ).summary ).toBe( "sent" );
				expect( arrayLen( conversations.getMessagesAfter( created.conversation_id, 0 ) ) ).toBe( 1 );
			} );
		} );

		describe( title = "claiming work", skip = integrationSkipped(), body = function () {

			it( "does not deliver the same message twice across sweeps", function () {
				var created = createTestConversation();

				deliveries.processPendingDeliveries( created.conversation_id );
				var calls_after_first = slack.getCallCount();

				deliveries.processPendingDeliveries( created.conversation_id );

				expect( slack.getCallCount() ).toBe( calls_after_first );
			} );

			it( "reports nothing claimed when the queue is empty", function () {
				var created = createTestConversation();
				deliveries.processPendingDeliveries( created.conversation_id );

				expect( deliveries.processPendingDeliveries( created.conversation_id ).claimed ).toBe( 0 );
			} );
		} );
	}

	// ------------------------------------------------------------------ helpers

	private numeric function countRootCalls() {

		var total = 0;

		for ( var call in slack.getCalls() ) {
			if ( call.is_root ) {
				total++;
			}
		}

		return total;
	}

	private numeric function countRootCallsFor( required string conversation_id ) {

		var total = 0;

		for ( var call in slack.getCalls() ) {
			if ( call.is_root && findNoCase( arguments.conversation_id, call.text ) ) {
				total++;
			}
		}

		return total;
	}

}
