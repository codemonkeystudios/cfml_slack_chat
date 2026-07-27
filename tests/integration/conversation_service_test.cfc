/**
 * Conversation persistence, authorization and the message cursor.
 *
 * Runs against the configured database. If none is available the suite skips.
 */
component extends="tests.integration.integration_base" {

	function afterAll() {
		tearDownData();
	}

	function run() {

		describe( title = "createConversation()", skip = integrationSkipped(), body = function () {

			it( "persists the conversation and its first message before Slack is involved", function () {
				var created = createTestConversation( body = "My invoice export stops at ninety percent." );

				expect( created.conversation_id ).notToBeEmpty();
				expect( created.message_id ).toBeGT( 0 );
				expect( created.message.senderType ).toBe( "customer" );
				expect( created.message.source ).toBe( "web" );
				expect( created.message.body ).toBe( "My invoice export stops at ninety percent." );

				// Slack has not been called at all at this point.
				expect( slack.getCallCount() ).toBe( 0 );
			} );

			it( "starts the conversation waiting on support, with no Slack thread yet", function () {
				var created = createTestConversation();

				expect( created.conversation.status ).toBe( "waiting" );
				expect( created.conversation.slackThreadTs ).toBe( "" );
				expect( created.conversation.slackChannelId ).toBe( "" );
			} );

			it( "issues a fresh 256 bit access token per conversation", function () {
				var first = createTestConversation();
				var second = createTestConversation();

				expect( reFind( "^[0-9a-f]{64}$", first.access_token ) ).toBeGT( 0 );
				expect( first.access_token ).notToBe( second.access_token );
			} );

			it( "enrols the first message in the outbound queue", function () {
				var created = createTestConversation();
				var status = conversations.getDeliveryStatus( created.conversation_id );

				expect( status.summary ).toBe( "pending" );
				expect( status.counts.pending ).toBe( 1 );
			} );

			it( "refuses a blank message", function () {
				expect( function () {
					conversations.createConversation( "Test Visitor", "test@example.com", " " );
				} ).toThrow( type = "Conversation.ValidationFailed" );
			} );

			it( "refuses a blank visitor name", function () {
				expect( function () {
					conversations.createConversation( "", "test@example.com", "Hello" );
				} ).toThrow( type = "Conversation.ValidationFailed" );
			} );

			it( "refuses an invalid email address", function () {
				expect( function () {
					conversations.createConversation( "Test Visitor", "not-an-address", "Hello" );
				} ).toThrow( type = "Conversation.ValidationFailed" );
			} );

			it( "refuses a message beyond the configured limit", function () {
				expect( function () {
					conversations.createConversation( "Test Visitor", "test@example.com", repeatString( "x", 4001 ) );
				} ).toThrow( type = "Conversation.ValidationFailed" );
			} );

			it( "writes nothing at all when validation fails", function () {
				var before = db.run( "select count(*) as total from conversation" ).total;

				try {
					conversations.createConversation( "Test Visitor", "test@example.com", "" );
				} catch ( any expected ) {
				}

				expect( db.run( "select count(*) as total from conversation" ).total ).toBe( before );
			} );
		} );

		describe( title = "authorize()", skip = integrationSkipped(), body = function () {

			it( "accepts the token issued with the conversation", function () {
				var created = createTestConversation();
				var conversation = conversations.authorize( created.conversation_id, created.access_token );

				expect( conversation.id ).toBe( created.conversation_id );
			} );

			it( "rejects a conversation ID on its own", function () {
				var created = createTestConversation();

				expect( function () {
					conversations.authorize( created.conversation_id, "" );
				} ).toThrow( type = "Conversation.AccessDenied" );
			} );

			it( "rejects a wrong token of the right shape", function () {
				var created = createTestConversation();

				expect( function () {
					conversations.authorize( created.conversation_id, repeatString( "a", 64 ) );
				} ).toThrow( type = "Conversation.AccessDenied" );
			} );

			it( "rejects one conversation's token used on another", function () {
				var first = createTestConversation();
				var second = createTestConversation();

				expect( function () {
					conversations.authorize( second.conversation_id, first.access_token );
				} ).toThrow( type = "Conversation.AccessDenied" );
			} );

			it( "gives the same answer for an unknown conversation as for a wrong token", function () {
				expect( function () {
					conversations.authorize( "019fa0c7-0000-7000-8000-000000000000", repeatString( "b", 64 ) );
				} ).toThrow( type = "Conversation.AccessDenied" );
			} );

			it( "stores only a hash, never the token itself", function () {
				var created = createTestConversation();

				var stored = db.run(
					"select access_token_hash from conversation where conversation_id = :conversation_id",
					{ "conversation_id":{ value:created.conversation_id, cfsqltype:"cf_sql_varchar" } }
				);

				expect( trim( stored.access_token_hash ) ).notToBe( created.access_token );
				expect( trim( stored.access_token_hash ) ).toBe( db.hashToken( created.access_token ) );
			} );
		} );

		describe( title = "addCustomerMessage()", skip = integrationSkipped(), body = function () {

			it( "appends to the existing conversation", function () {
				var created = createTestConversation();
				var added = conversations.addCustomerMessage( created.conversation_id, created.access_token, "Any update?" );

				expect( added.message_id ).toBeGT( created.message_id );
				expect( added.message.body ).toBe( "Any update?" );
				expect( added.message.senderType ).toBe( "customer" );
			} );

			it( "refuses a caller without the access token", function () {
				var created = createTestConversation();

				expect( function () {
					conversations.addCustomerMessage( created.conversation_id, repeatString( "c", 64 ), "Let me in" );
				} ).toThrow( type = "Conversation.AccessDenied" );
			} );

			it( "refuses to add to a closed conversation", function () {
				var created = createTestConversation();
				conversations.closeConversation( created.conversation_id, created.access_token );

				expect( function () {
					conversations.addCustomerMessage( created.conversation_id, created.access_token, "One more thing" );
				} ).toThrow( type = "Conversation.Closed" );
			} );
		} );

		describe( title = "getMessagesAfter()", skip = integrationSkipped(), body = function () {

			it( "returns only messages after the cursor", function () {
				var created = createTestConversation();
				conversations.addCustomerMessage( created.conversation_id, created.access_token, "Second" );
				conversations.addCustomerMessage( created.conversation_id, created.access_token, "Third" );

				var after_first = conversations.getMessagesAfter( created.conversation_id, created.message_id );

				expect( arrayLen( after_first ) ).toBe( 2 );
				expect( after_first[ 1 ].body ).toBe( "Second" );
				expect( after_first[ 2 ].body ).toBe( "Third" );
			} );

			it( "returns everything when the cursor is zero", function () {
				var created = createTestConversation();
				conversations.addCustomerMessage( created.conversation_id, created.access_token, "Second" );

				expect( arrayLen( conversations.getMessagesAfter( created.conversation_id, 0 ) ) ).toBe( 2 );
			} );

			it( "returns messages in ascending id order", function () {
				var created = createTestConversation();

				for ( var index = 1; index <= 5; index++ ) {
					conversations.addCustomerMessage( created.conversation_id, created.access_token, "Message " & index );
				}

				var messages = conversations.getMessagesAfter( created.conversation_id, 0 );
				var previous_id = 0;

				for ( var message in messages ) {
					expect( message.id ).toBeGT( previous_id );
					previous_id = message.id;
				}
			} );

			it( "never returns another conversation's messages", function () {
				var first = createTestConversation( body = "First conversation only" );
				var second = createTestConversation( body = "Second conversation only" );

				var messages = conversations.getMessagesAfter( first.conversation_id, 0 );

				expect( arrayLen( messages ) ).toBe( 1 );
				expect( messages[ 1 ].body ).toBe( "First conversation only" );
			} );

			it( "returns nothing once the cursor has caught up", function () {
				var created = createTestConversation();

				expect( arrayLen( conversations.getMessagesAfter( created.conversation_id, created.message_id ) ) ).toBe( 0 );
			} );

			it( "does not expose Slack user IDs or event IDs to the browser shape", function () {
				var created = createTestConversation();
				var messages = conversations.getMessagesAfter( created.conversation_id, 0 );

				expect( messages[ 1 ] ).notToHaveKey( "senderId" );
				expect( messages[ 1 ] ).notToHaveKey( "slackEventId" );
				expect( messages[ 1 ] ).toHaveKey( "senderType" );
				expect( messages[ 1 ] ).toHaveKey( "body" );
			} );
		} );

		describe( title = "saveSupportMessage()", skip = integrationSkipped(), body = function () {

			it( "saves a support reply once", function () {
				var created = createTestConversation();

				var saved = conversations.saveSupportMessage(
					conversation_id = created.conversation_id,
					sender_id = "U9999999999",
					sender_name = "Alex Support",
					body = "Looking into it now.",
					slack_event_id = "Ev" & createUUID(),
					slack_message_ts = "1700000100.000200"
				);

				expect( saved.created ).toBeTrue();
				expect( saved.message_id ).toBeGT( 0 );
			} );

			it( "refuses to save the same Slack message twice", function () {
				var created = createTestConversation();
				var event_id = "Ev" & createUUID();

				var first = conversations.saveSupportMessage(
					created.conversation_id, "U9999999999", "Alex Support", "Looking into it.", event_id, "1700000100.000300"
				);

				var second = conversations.saveSupportMessage(
					created.conversation_id, "U9999999999", "Alex Support", "Looking into it.", event_id, "1700000100.000300"
				);

				expect( first.created ).toBeTrue();
				expect( second.created ).toBeFalse();
				expect( arrayLen( conversations.getMessagesAfter( created.conversation_id, created.message_id ) ) ).toBe( 1 );
			} );

			it( "moves the conversation back to active when support replies", function () {
				var created = createTestConversation();

				expect( conversations.getConversation( created.conversation_id ).status ).toBe( "waiting" );

				conversations.saveSupportMessage(
					created.conversation_id, "U9999999999", "Alex", "On it.", "Ev" & createUUID(), "1700000100.000400"
				);

				expect( conversations.getConversation( created.conversation_id ).status ).toBe( "active" );
			} );

			it( "falls back to a generic sender name when Slack gave none", function () {
				var created = createTestConversation();

				var saved = conversations.saveSupportMessage(
					created.conversation_id, "U9999999999", "", "Anonymous help.", "Ev" & createUUID(), "1700000100.000500"
				);

				expect( conversations.getMessage( saved.message_id ).senderName ).toBe( "Support" );
			} );
		} );

		describe( title = "findBySlackThread()", skip = integrationSkipped(), body = function () {

			it( "finds a conversation by exact channel and thread timestamp", function () {
				var created = createTestConversation();
				conversations.attachSlackThread( created.conversation_id, channel_id, "1700000000.000900" );

				var found = conversations.findBySlackThread( channel_id, "1700000000.000900" );

				expect( found.id ).toBe( created.conversation_id );
			} );

			it( "returns nothing for a thread in a different channel", function () {
				var created = createTestConversation();
				conversations.attachSlackThread( created.conversation_id, channel_id, "1700000000.001000" );

				expect( conversations.findBySlackThread( "C0OTHERCHANNEL", "1700000000.001000" ) ).toBeEmpty();
			} );

			it( "returns nothing for an unknown thread timestamp", function () {
				expect( conversations.findBySlackThread( channel_id, "1700000000.999999" ) ).toBeEmpty();
			} );

			it( "does not overwrite a thread that is already attached", function () {
				var created = createTestConversation();
				conversations.attachSlackThread( created.conversation_id, channel_id, "1700000000.001100" );
				conversations.attachSlackThread( created.conversation_id, channel_id, "1700000000.001200" );

				expect( conversations.getConversation( created.conversation_id ).slackThreadTs ).toBe( "1700000000.001100" );
			} );
		} );

		describe( title = "when no database is configured", skip = !integrationSkipped(), body = function () {

			it( "reports why the integration suites were skipped", function () {
				debug( "Integration specs skipped: " & skipReason() );
				expect( skipReason() ).notToBeEmpty();
			} );
		} );
	}

}
