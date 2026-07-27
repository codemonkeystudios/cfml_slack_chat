/**
 * Identifier and token generation.
 *
 * database_service is constructed with a datasource name that is never used:
 * none of these methods touch the database.
 */
component extends="testbox.system.BaseSpec" {

	function beforeAll() {
		variables.db = new slackchat.services.database_service( "unusedDatasource", "postgresql" );
	}

	function run() {

		describe( "newConversationId()", function () {

			it( "returns a 36 character dashed UUID", function () {
				expect( reFind( "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", db.newConversationId() ) ).toBeGT( 0 );
			} );

			it( "sets the version nibble to 7", function () {
				expect( mid( db.newConversationId(), 15, 1 ) ).toBe( "7" );
			} );

			it( "sets a valid RFC 4122 variant nibble", function () {
				expect( arrayFindNoCase( [ "8", "9", "a", "b" ], mid( db.newConversationId(), 20, 1 ) ) ).toBeGT( 0 );
			} );

			it( "produces identifiers that sort in creation order", function () {
				var first = db.newConversationId();
				sleep( 5 );
				var second = db.newConversationId();

				expect( compare( second, first ) ).toBeGT( 0 );
			} );

			it( "does not repeat itself", function () {
				var seen = {};

				for ( var index = 1; index <= 200; index++ ) {
					seen[ db.newConversationId() ] = true;
				}

				expect( structCount( seen ) ).toBe( 200 );
			} );
		} );

		describe( "newAccessToken()", function () {

			it( "returns 64 hex characters, which is 256 bits", function () {
				expect( reFind( "^[0-9a-f]{64}$", db.newAccessToken() ) ).toBeGT( 0 );
			} );

			it( "does not repeat itself", function () {
				var seen = {};

				for ( var index = 1; index <= 200; index++ ) {
					seen[ db.newAccessToken() ] = true;
				}

				expect( structCount( seen ) ).toBe( 200 );
			} );
		} );

		describe( "hashToken()", function () {

			it( "produces a stable lowercase SHA-256 digest", function () {
				var token = db.newAccessToken();

				expect( db.hashToken( token ) ).toBe( db.hashToken( token ) );
				expect( reFind( "^[0-9a-f]{64}$", db.hashToken( token ) ) ).toBeGT( 0 );
			} );

			it( "does not return the token it was given", function () {
				var token = db.newAccessToken();

				expect( db.hashToken( token ) ).notToBe( token );
			} );

			it( "produces a different digest for a token differing by one character", function () {
				expect( db.hashToken( "abc" ) ).notToBe( db.hashToken( "abd" ) );
			} );
		} );

		describe( "randomHex()", function () {

			it( "returns exactly the requested number of characters", function () {
				expect( len( db.randomHex( 7 ) ) ).toBe( 7 );
				expect( len( db.randomHex( 32 ) ) ).toBe( 32 );
			} );
		} );

		describe( "platform handling", function () {

			it( "accepts each supported platform", function () {
				for ( var platform in [ "postgresql", "mysql", "sqlserver" ] ) {
					expect( new slackchat.services.database_service( "unusedDatasource", platform ).getPlatform() ).toBe( platform );
				}
			} );

			it( "refuses an unsupported platform rather than guessing", function () {
				expect( function () {
					new slackchat.services.database_service( "unusedDatasource", "oracle" );
				} ).toThrow( type = "Configuration.Invalid" );
			} );
		} );

		describe( "toIso()", function () {

			it( "formats a date as UTC ISO 8601", function () {
				expect( reFind( "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", db.toIso( createDateTime( 2026, 7, 26, 14, 30, 0 ) ) ) ).toBeGT( 0 );
			} );

			it( "returns an empty string for a null column value", function () {
				expect( db.toIso( "" ) ).toBe( "" );
			} );
		} );
	}

}
