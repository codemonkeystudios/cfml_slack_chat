/**
 * SSE framing and cursor resolution.
 *
 * A frame that contains an unescaped newline ends early, and the browser
 * receives half a message. These specs exist so that stays theoretical.
 */
component extends="testbox.system.BaseSpec" {

	function beforeAll() {
		variables.stream = new slackchat.services.event_stream_service(
			conversation_service = createStub(),
			slack_event_service = createStub(),
			slack_delivery_service = createStub(),
			log_service = new tests.support.null_log_service(),
			max_seconds = 55,
			poll_milliseconds = 1500,
			auto_process_events = false
		);
	}

	function run() {

		describe( "formatEvent()", function () {

			it( "emits id, event and data lines followed by a blank line", function () {
				var frame = stream.formatEvent( "message", { "id":42 }, "42" );

				expect( frame ).toInclude( "id: 42" & chr( 10 ) );
				expect( frame ).toInclude( "event: message" & chr( 10 ) );
				expect( frame ).toInclude( "data: " );
				expect( right( frame, 2 ) ).toBe( chr( 10 ) & chr( 10 ) );
			} );

			it( "omits the id line when no event id is supplied", function () {
				expect( stream.formatEvent( "ready", { "cursor":0 } ) ).notToInclude( "id: " );
			} );

			it( "keeps a body containing newlines on a single data line", function () {
				var frame = stream.formatEvent( "message", { "body":"line one" & chr( 10 ) & "line two" }, "7" );
				var data_lines = 0;

				for ( var line in listToArray( frame, chr( 10 ) ) ) {
					if ( left( line, 6 ) == "data: " ) {
						data_lines++;
					}
				}

				expect( data_lines ).toBe( 1 );
			} );

			it( "terminates the frame with a blank line, so one frame is one event", function () {
				var frame = stream.formatEvent( "message", { "body":"hello" }, "1" );
				var lines = listToArray( frame, chr( 10 ), true );

				// id, event, data, then the empty element either side of the final
				// newline pair that closes the frame.
				expect( arrayLen( lines ) ).toBe( 5 );
				expect( lines[ 4 ] ).toBe( "" );
				expect( lines[ 5 ] ).toBe( "" );
			} );

			it( "round-trips through JSON parsing", function () {
				var body = "Carriage" & chr( 13 ) & chr( 10 ) & "return ""quoted"" and \backslash";
				var frame = stream.formatEvent( "message", { "body":body }, "9" );
				var data = mid( frame, find( "data: ", frame ) + 6, len( frame ) );
				var payload = deserializeJSON( trim( data ) );

				expect( payload.body ).toInclude( "quoted" );
			} );
		} );

		describe( "formatComment()", function () {

			it( "emits an SSE comment terminated by a blank line", function () {
				expect( stream.formatComment( "keepalive" ) ).toBe( ": keepalive" & chr( 10 ) & chr( 10 ) );
			} );
		} );

		describe( "toSingleLineJson()", function () {

			it( "strips every kind of line break", function () {
				var json = stream.toSingleLineJson( { "a":"x" & chr( 10 ) & "y", "b":"p" & chr( 13 ) & "q" } );

				expect( find( chr( 10 ), json ) ).toBe( 0 );
				expect( find( chr( 13 ), json ) ).toBe( 0 );
			} );
		} );

		describe( "resolveCursor()", function () {

			it( "prefers Last-Event-ID, which is what a reconnecting browser sends", function () {
				expect( stream.resolveCursor( "17", "3" ) ).toBe( 17 );
			} );

			it( "falls back to the explicit cursor on a fresh connection", function () {
				expect( stream.resolveCursor( "", "3" ) ).toBe( 3 );
			} );

			it( "starts at zero when neither is present", function () {
				expect( stream.resolveCursor( "", "" ) ).toBe( 0 );
			} );

			it( "ignores a non-numeric Last-Event-ID", function () {
				expect( stream.resolveCursor( "not-a-number", "5" ) ).toBe( 5 );
			} );

			it( "ignores a non-numeric cursor parameter", function () {
				expect( stream.resolveCursor( "", "'; drop table conversation; --" ) ).toBe( 0 );
			} );
		} );

		describe( "maybeProcessQueues()", function () {

			it( "does nothing when automatic draining is switched off", function () {
				expect( stream.maybeProcessQueues().ran ).toBeFalse();
			} );
		} );
	}

}
