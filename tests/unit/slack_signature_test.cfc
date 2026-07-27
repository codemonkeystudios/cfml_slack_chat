/**
 * Slack request verification.
 *
 * The vector below is fixed and was cross-checked against an independent
 * HMAC-SHA256 implementation outside CFML. That is the point: a passing suite
 * means this code agrees with the algorithm Slack specifies, rather than merely
 * agreeing with itself.
 *
 * Do not "tidy" these values. The signature covers the body byte for byte.
 */
component extends="testbox.system.BaseSpec" {

	variables.example_secret = "8f742231b10e4a1cbc4a4ff5a1234567";
	variables.example_timestamp = "1531420618";
	variables.example_body = "token=xyzz0WbapA4vBCDEFasx0q6G&team_id=T1DC2JH3J&team_domain=testteamnow&channel_id=G8PSS9T3V&channel_name=foobar&user_id=U2CERLKJA&user_name=roadrunner&command=%2Fwebhook-collect&text=&response_url=https%3A%2F%2Fhooks.slack.com%2Fcommands%2FT1DC2JH3J%2F397700885554%2F96rGlfmibIGlgcZRskXaIFfN&trigger_id=398738663015.47445629121.803a0bc887a14d10d2c447fce8b6703c";
	variables.example_signature = "v0=0775f09472acd1ac46679a4f839e8e99424552fb61d7a030649efffb2968306f";

	function beforeAll() {
		variables.slack = buildSlackService();
	}

	private any function buildSlackService( string signing_secret = variables.example_secret ) {
		return new slackchat.services.slack_service(
			bot_token = "xoxb-not-used-in-these-tests",
			signing_secret = arguments.signing_secret,
			default_channel = "C0123456789",
			log_service = new tests.support.null_log_service()
		);
	}

	private string function currentTimestamp() {
		return toString( int( createObject( "java", "java.lang.System" ).currentTimeMillis() / 1000 ) );
	}

	function run() {

		describe( "buildSignature()", function () {

			it( "reproduces a known HMAC-SHA256 vector", function () {
				expect( slack.buildSignature( example_timestamp, example_body ) ).toBe( example_signature );
			} );

			it( "produces a lowercase v0 prefixed hex digest", function () {
				var signature = slack.buildSignature( currentTimestamp(), "{""hello"":""world""}" );
				expect( reFind( "^v0=[0-9a-f]{64}$", signature ) ).toBeGT( 0 );
			} );

			it( "changes when the body changes by a single character", function () {
				var timestamp = currentTimestamp();
				expect( slack.buildSignature( timestamp, "payload" ) )
					.notToBe( slack.buildSignature( timestamp, "payloaD" ) );
			} );

			it( "changes when the timestamp changes", function () {
				expect( slack.buildSignature( "1531420618", example_body ) )
					.notToBe( slack.buildSignature( "1531420619", example_body ) );
			} );
		} );

		describe( "timingSafeEquals()", function () {

			it( "accepts identical values", function () {
				expect( slack.timingSafeEquals( example_signature, example_signature ) ).toBeTrue();
			} );

			it( "rejects values differing in the last character", function () {
				var altered = left( example_signature, len( example_signature ) - 1 ) & "4";
				expect( slack.timingSafeEquals( example_signature, altered ) ).toBeFalse();
			} );

			it( "rejects values differing in the first character", function () {
				expect( slack.timingSafeEquals( "abcdef", "zbcdef" ) ).toBeFalse();
			} );

			it( "rejects values of different lengths without throwing", function () {
				expect( slack.timingSafeEquals( "short", "considerably longer value" ) ).toBeFalse();
			} );

			it( "rejects a prefix of the correct value", function () {
				expect( slack.timingSafeEquals( example_signature, left( example_signature, 10 ) ) ).toBeFalse();
			} );

			it( "accepts two empty strings", function () {
				expect( slack.timingSafeEquals( "", "" ) ).toBeTrue();
			} );
		} );

		describe( "verifyRequest()", function () {

			it( "accepts a correctly signed, current request", function () {
				var timestamp = currentTimestamp();
				var body = "{""type"":""event_callback""}";
				var result = slack.verifyRequest( body, slack.buildSignature( timestamp, body ), timestamp );

				expect( result.valid ).toBeTrue();
				expect( result.reason ).toBe( "" );
			} );

			it( "rejects a signature that does not match the body", function () {
				var timestamp = currentTimestamp();
				var result = slack.verifyRequest( "{}", slack.buildSignature( timestamp, "{""different"":true}" ), timestamp );

				expect( result.valid ).toBeFalse();
				expect( result.reason ).toBe( "signature_mismatch" );
			} );

			it( "rejects a body modified after signing", function () {
				var timestamp = currentTimestamp();
				var body = "{""text"":""approved""}";
				var signature = slack.buildSignature( timestamp, body );
				var result = slack.verifyRequest( replace( body, "approved", "APPROVED" ), signature, timestamp );

				expect( result.valid ).toBeFalse();
				expect( result.reason ).toBe( "signature_mismatch" );
			} );

			it( "rejects a missing signature header", function () {
				var result = slack.verifyRequest( "{}", "", currentTimestamp() );

				expect( result.valid ).toBeFalse();
				expect( result.reason ).toBe( "missing_signature_header" );
			} );

			it( "rejects a missing timestamp header", function () {
				var result = slack.verifyRequest( "{}", example_signature, "" );

				expect( result.valid ).toBeFalse();
				expect( result.reason ).toBe( "missing_timestamp_header" );
			} );

			it( "rejects a non-numeric timestamp", function () {
				var result = slack.verifyRequest( "{}", example_signature, "yesterday" );

				expect( result.valid ).toBeFalse();
				expect( result.reason ).toBe( "non_numeric_timestamp" );
			} );

			it( "rejects a timestamp older than the replay window", function () {
				var stale = toString( val( currentTimestamp() ) - 400 );
				var result = slack.verifyRequest( "{}", slack.buildSignature( stale, "{}" ), stale );

				expect( result.valid ).toBeFalse();
				expect( result.reason ).toBe( "stale_timestamp" );
			} );

			it( "rejects a timestamp too far in the future", function () {
				var ahead = toString( val( currentTimestamp() ) + 400 );
				var result = slack.verifyRequest( "{}", slack.buildSignature( ahead, "{}" ), ahead );

				expect( result.valid ).toBeFalse();
				expect( result.reason ).toBe( "future_timestamp" );
			} );

			it( "accepts a timestamp just inside the replay window", function () {
				var recent = toString( val( currentTimestamp() ) - 290 );
				var result = slack.verifyRequest( "{}", slack.buildSignature( recent, "{}" ), recent );

				expect( result.valid ).toBeTrue();
			} );

			it( "honours a caller supplied replay window", function () {
				var recent = toString( val( currentTimestamp() ) - 60 );
				var result = slack.verifyRequest( "{}", slack.buildSignature( recent, "{}" ), recent, 30 );

				expect( result.valid ).toBeFalse();
				expect( result.reason ).toBe( "stale_timestamp" );
			} );

			it( "refuses to verify anything when no signing secret is configured", function () {
				var unconfigured = buildSlackService( "" );
				var timestamp = currentTimestamp();
				var result = unconfigured.verifyRequest( "{}", example_signature, timestamp );

				expect( result.valid ).toBeFalse();
				expect( result.reason ).toBe( "no_signing_secret_configured" );
			} );

			it( "rejects a request signed with a different secret", function () {
				var timestamp = currentTimestamp();
				var attacker = buildSlackService( "0000000000000000000000000000dead" );
				var result = slack.verifyRequest( "{}", attacker.buildSignature( timestamp, "{}" ), timestamp );

				expect( result.valid ).toBeFalse();
				expect( result.reason ).toBe( "signature_mismatch" );
			} );
		} );

		describe( "escapeText()", function () {

			it( "escapes the characters Slack treats as markup", function () {
				expect( slack.escapeText( "a & b < c > d" ) ).toBe( "a &amp; b &lt; c &gt; d" );
			} );

			it( "defuses a channel-wide notification typed by a visitor", function () {
				expect( slack.escapeText( "<!channel> everyone look" ) ).toBe( "&lt;!channel&gt; everyone look" );
			} );

			it( "escapes ampersands before angle brackets, not after", function () {
				expect( slack.escapeText( "<" ) ).toBe( "&lt;" );
			} );
		} );
	}

}
