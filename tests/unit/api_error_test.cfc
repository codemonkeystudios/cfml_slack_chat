/**
 * Exception to HTTP response mapping.
 *
 * The point of these specs is what does *not* come out: no stack traces, no SQL,
 * no tokens, no connection strings.
 */
component extends="testbox.system.BaseSpec" {

	function beforeAll() {
		variables.log = new tests.support.null_log_service();
		variables.api = new slackchat.services.api_service( variables.log );
	}


	private struct function fakeException( required string type, string message = "Something happened.", string detail = "" ) {
		return { "type":arguments.type, "message":arguments.message, "detail":arguments.detail };
	}

	function run() {

		describe( "describeError()", function () {

			it( "maps a validation failure to 400 and keeps the message", function () {
				var described = api.describeError( fakeException( "Conversation.ValidationFailed", "Enter a message before pressing Send." ) );

				expect( described.status_code ).toBe( 400 );
				expect( described.body.error.code ).toBe( "validation_failed" );
				expect( described.body.error.message ).toBe( "Enter a message before pressing Send." );
			} );

			it( "maps a denied conversation to 403", function () {
				expect( api.describeError( fakeException( "Conversation.AccessDenied" ) ).status_code ).toBe( 403 );
			} );

			it( "maps a missing conversation to 404", function () {
				expect( api.describeError( fakeException( "Conversation.NotFound" ) ).status_code ).toBe( 404 );
			} );

			it( "maps a closed conversation to 409", function () {
				expect( api.describeError( fakeException( "Conversation.Closed" ) ).status_code ).toBe( 409 );
			} );

			it( "maps a missing schema to 503", function () {
				expect( api.describeError( fakeException( "Database.SchemaMissing" ) ).status_code ).toBe( 503 );
			} );

			it( "maps Slack failures to 502, because Slack is upstream", function () {
				for ( var slack_type in [ "Slack.ApiError", "Slack.AuthenticationFailed", "Slack.RateLimited", "Slack.RequestFailed", "Slack.InvalidResponse" ] ) {
					expect( api.describeError( fakeException( slack_type ) ).status_code ).toBe( 502 );
				}
			} );

			it( "maps an unrecognised exception to a generic 500", function () {
				var described = api.describeError( fakeException( "database", "ORA-00942: table or view does not exist in SELECT * FROM conversation" ) );

				expect( described.status_code ).toBe( 500 );
				expect( described.body.error.code ).toBe( "internal_error" );
				expect( described.body.error.message ).notToInclude( "ORA-00942" );
				expect( described.body.error.message ).notToInclude( "SELECT" );
			} );

			it( "always answers with ok false and a code plus message", function () {
				var described = api.describeError( fakeException( "Conversation.NotFound" ) );

				expect( described.body.ok ).toBeFalse();
				expect( described.body.error ).toHaveKey( "code" );
				expect( described.body.error ).toHaveKey( "message" );
			} );

			it( "logs server errors at error level and client errors at warn level", function () {
				log.clearEntries();

				api.describeError( fakeException( "Conversation.ValidationFailed" ) );
				api.describeError( fakeException( "some.unknown.type" ) );

				var entries = log.entriesFor( "api.error" );

				expect( arrayLen( entries ) ).toBe( 2 );
				expect( entries[ 1 ].level ).toBe( "warn" );
				expect( entries[ 2 ].level ).toBe( "error" );
			} );

			it( "records the failing context so a log reader knows where to look", function () {
				log.clearEntries();

				api.describeError( fakeException( "Conversation.NotFound" ), "message.history" );

				expect( log.entriesFor( "api.error" )[ 1 ].fields.context ).toBe( "message.history" );
			} );
		} );

		describe( "redactSecrets()", function () {

			it( "removes a bot token that reached an error string", function () {
				var clean = api.redactSecrets( "Auth failed for xoxb-1234567890-0987654321-abcdefghijkl on retry" );

				expect( clean ).notToInclude( "xoxb-1234567890" );
				expect( clean ).toInclude( "[redacted token]" );
			} );

			it( "removes a password from a JDBC connection string", function () {
				var clean = api.redactSecrets( "jdbc:postgresql://db:5432/chat?user=chatuser&password=hunter2" );

				expect( clean ).notToInclude( "hunter2" );
			} );

			it( "leaves ordinary text alone", function () {
				expect( api.redactSecrets( "The bot is not a member of channel C0123456789." ) )
					.toBe( "The bot is not a member of channel C0123456789." );
			} );

			it( "redacts a token embedded in a mapped error message", function () {
				var described = api.describeError( fakeException( "Slack.ApiError", "Rejected token xoxb-9999999999-aaaaaaaaaa-zzzz" ) );

				expect( described.body.error.message ).notToInclude( "xoxb-9999999999" );
			} );
		} );

		describe( "statusTextFor()", function () {

			it( "names the status codes the API actually returns", function () {
				expect( api.statusTextFor( 201 ) ).toBe( "Created" );
				expect( api.statusTextFor( 403 ) ).toBe( "Forbidden" );
				expect( api.statusTextFor( 502 ) ).toBe( "Bad Gateway" );
			} );
		} );
	}

}
