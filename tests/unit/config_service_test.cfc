/**
 * Configuration precedence, secret handling and setup form validation.
 *
 * Each spec gets its own throwaway configuration file, so nothing here can read
 * or damage the configuration of a running application.
 */
component extends="testbox.system.BaseSpec" {

	function beforeAll() {
		variables.temporary_directory = getTempDirectory() & "cfml-slack-chat-tests/";

		if ( !directoryExists( variables.temporary_directory ) ) {
			directoryCreate( variables.temporary_directory, true );
		}
	}

	function afterAll() {
		if ( directoryExists( variables.temporary_directory ) ) {
			directoryDelete( variables.temporary_directory, true );
		}
	}

	private string function newConfigPath() {
		return variables.temporary_directory & createUUID() & ".json";
	}

	private any function buildConfigService( struct stored = {} ) {

		var config_path = newConfigPath();

		if ( !structIsEmpty( arguments.stored ) ) {
			fileWrite( config_path, serializeJSON( arguments.stored ), "utf-8" );
		}

		return new slackchat.services.config_service( config_path );
	}

	function run() {

		describe( "defaults", function () {

			it( "reports itself unconfigured when nothing has been set", function () {
				var config_service = buildConfigService();

				expect( config_service.isConfigured() ).toBeFalse();
				expect( arrayLen( config_service.getMissingSettings() ) ).toBeGT( 0 );
			} );

			it( "names every missing setting with a reason a person can act on", function () {
				var missing = buildConfigService().getMissingSettings();

				for ( var item in missing ) {
					expect( item ).toHaveKey( "path" );
					expect( item ).toHaveKey( "label" );
					expect( len( item.reason ) ).toBeGT( 10 );
				}
			} );

			it( "supplies a sensible default replay window", function () {
				expect( buildConfigService().getSetting( "app.signature_max_age_seconds" ) ).toBe( 300 );
			} );
		} );

		describe( "reading a stored file", function () {

			it( "merges stored values over the defaults", function () {
				var config_service = buildConfigService( { "slack":{ "channel_id":"C0123456789" } } );

				expect( config_service.getSetting( "slack.channel_id" ) ).toBe( "C0123456789" );
				expect( config_service.getSetting( "database.type" ) ).toBe( "postgresql" );
			} );

			it( "reports itself configured once every required value is present", function () {
				var config_service = buildConfigService( {
					"slack" : { "bot_token":"xoxb-x", "signing_secret":"8f742231b10e4a1cbc4a4ff5a1234567", "channel_id":"C0123456789" },
					"database" : { "mode":"application", "type":"postgresql", "host":"localhost", "port":"5432", "database":"slackchat", "username":"chatuser" }
				} );

				expect( config_service.isConfigured() ).toBeTrue();
			} );

			it( "rejects a configuration file that is not JSON", function () {
				var config_path = newConfigPath();
				fileWrite( config_path, "this is not json at all", "utf-8" );

				expect( function () {
					new slackchat.services.config_service( config_path );
				} ).toThrow( type = "Configuration.Invalid" );
			} );
		} );

		describe( "getPublicConfig()", function () {

			it( "never includes a secret value", function () {
				var public_config = buildConfigService( {
					"slack" : { "bot_token":"xoxb-super-secret", "signing_secret":"8f742231b10e4a1cbc4a4ff5a1234567" },
					"database" : { "password":"hunter2" }
				} ).getPublicConfig();

				expect( public_config.slack ).notToHaveKey( "bot_token" );
				expect( public_config.slack ).notToHaveKey( "signing_secret" );
				expect( public_config.database ).notToHaveKey( "password" );

				expect( serializeJSON( public_config ) ).notToInclude( "xoxb-super-secret" );
				expect( serializeJSON( public_config ) ).notToInclude( "hunter2" );
			} );

			it( "reports whether each secret is set without revealing it", function () {
				var public_config = buildConfigService( { "slack":{ "bot_token":"xoxb-present" } } ).getPublicConfig();

				expect( public_config.slack.bot_token_is_set ).toBeTrue();
				expect( public_config.slack.signing_secret_is_set ).toBeFalse();
			} );

			it( "still exposes non-secret values the setup form needs", function () {
				var public_config = buildConfigService( { "slack":{ "channel_id":"C0123456789" } } ).getPublicConfig();

				expect( public_config.slack.channel_id ).toBe( "C0123456789" );
			} );
		} );

		describe( "save()", function () {

			it( "writes values and reads them back", function () {
				var config_service = buildConfigService();

				config_service.save( { "slack_channel_id":"C0123456789", "database_host":"db.internal" } );

				expect( config_service.getSetting( "slack.channel_id" ) ).toBe( "C0123456789" );
				expect( config_service.getSetting( "database.host" ) ).toBe( "db.internal" );
			} );

			it( "keeps a stored secret when the form posts an empty field", function () {
				var config_service = buildConfigService( { "slack":{ "bot_token":"xoxb-keep-me" } } );

				config_service.save( { "slack_bot_token":"", "slack_channel_id":"C0123456789" } );

				expect( config_service.getSetting( "slack.bot_token" ) ).toBe( "xoxb-keep-me" );
			} );

			it( "replaces a stored secret when a new one is supplied", function () {
				var config_service = buildConfigService( { "slack":{ "bot_token":"xoxb-old" } } );

				config_service.save( { "slack_bot_token":"xoxb-new" } );

				expect( config_service.getSetting( "slack.bot_token" ) ).toBe( "xoxb-new" );
			} );

			it( "ignores keys that are not part of the configuration shape", function () {
				var config_service = buildConfigService();

				config_service.save( { "slack_channel_id":"C0123456789", "database_drop_everything":"true" } );

				expect( config_service.getConfig().database ).notToHaveKey( "drop_everything" );
			} );
		} );

		describe( "getEventsRequestUrl()", function () {

			it( "appends the endpoint path to the public base URL", function () {
				var config_service = buildConfigService( { "app":{ "public_base_url":"https://demo.trycloudflare.com" } } );

				expect( config_service.getEventsRequestUrl() ).toBe( "https://demo.trycloudflare.com/slack/events.cfm" );
			} );

			it( "does not produce a double slash when the base URL has a trailing one", function () {
				var config_service = buildConfigService( { "app":{ "public_base_url":"https://demo.trycloudflare.com/" } } );

				expect( config_service.getEventsRequestUrl() ).toBe( "https://demo.trycloudflare.com/slack/events.cfm" );
			} );

			it( "returns nothing when no public base URL is set", function () {
				expect( buildConfigService().getEventsRequestUrl() ).toBe( "" );
			} );
		} );

		describe( "validateInput()", function () {

			it( "accepts a well formed set of values", function () {
				var errors = buildConfigService().validateInput( {
					"slack_bot_token" : "xoxb-0000-0000-abcdef",
					"slack_signing_secret" : "8f742231b10e4a1cbc4a4ff5a1234567",
					"slack_channel_id" : "C0123456789",
					"app_public_base_url" : "https://demo.trycloudflare.com",
					"database_mode" : "application",
					"database_type" : "postgresql",
					"database_port" : "5432"
				} );

				expect( arrayLen( errors ) ).toBe( 0 );
			} );

			it( "rejects a channel name where an ID belongs", function () {
				var errors = buildConfigService().validateInput( { "slack_channel_id":"##support" } );

				expect( arrayLen( errors ) ).toBe( 1 );
				expect( errors[ 1 ].field ).toBe( "slack_channel_id" );
			} );

			it( "rejects a token that is not a bot token", function () {
				var errors = buildConfigService().validateInput( { "slack_bot_token":"not-a-slack-token" } );

				expect( arrayLen( errors ) ).toBe( 1 );
			} );

			it( "rejects a localhost public base URL", function () {
				var errors = buildConfigService().validateInput( { "app_public_base_url":"http://localhost:8080" } );

				expect( arrayLen( errors ) ).toBe( 1 );
				expect( errors[ 1 ].message ).toInclude( "localhost" );
			} );

			it( "rejects a plain http public base URL", function () {
				var errors = buildConfigService().validateInput( { "app_public_base_url":"http://demo.example.com" } );

				expect( arrayLen( errors ) ).toBe( 1 );
			} );

			it( "allows a plain http base URL in local-only mode", function () {
				var errors = buildConfigService().validateInput( {
					"app_public_base_url" : "http://demo.example.com",
					"app_allow_insecure_public_url" : "true"
				} );

				expect( arrayLen( errors ) ).toBe( 0 );
			} );

			it( "rejects an out of range database port", function () {
				var errors = buildConfigService().validateInput( {
					"database_mode" : "application",
					"database_port" : "99999"
				} );

				expect( arrayLen( errors ) ).toBe( 1 );
			} );

			it( "rejects an unsupported database type", function () {
				var errors = buildConfigService().validateInput( { "database_type":"oracle" } );

				expect( arrayLen( errors ) ).toBe( 1 );
			} );

			it( "rejects an invalid default visitor email", function () {
				var errors = buildConfigService().validateInput( { "visitor_default_email":"not an address" } );

				expect( arrayLen( errors ) ).toBe( 1 );
			} );
		} );

		describe( "buildDatasourceDefinition()", function () {

			it( "builds a PostgreSQL connection for the running engine", function () {
				var config_service = buildConfigService( {
					"database" : { "mode":"application", "type":"postgresql", "host":"db.internal", "port":"5432", "database":"slackchat", "username":"chatuser", "password":"secret" }
				} );

				var definition = config_service.buildDatasourceDefinition();

				expect( definition ).toHaveKey( "username" );
				expect( definition.username ).toBe( "chatuser" );
			} );

			it( "refuses to build one in existing-datasource mode", function () {
				var config_service = buildConfigService( { "database":{ "mode":"existing", "datasource":"myDsn" } } );

				expect( function () {
					config_service.buildDatasourceDefinition();
				} ).toThrow( type = "Configuration.Invalid" );
			} );

			it( "explains itself when the CLI task cannot use a named datasource", function () {
				var config_service = buildConfigService( { "database":{ "mode":"existing", "datasource":"myDsn" } } );

				expect( function () {
					config_service.buildStandaloneDatasource();
				} ).toThrow( type = "Configuration.Invalid" );
			} );
		} );

		describe( "getDatasourceName()", function () {

			it( "uses the operator's own name in existing mode", function () {
				expect( buildConfigService( { "database":{ "mode":"existing", "datasource":"mySupportDsn" } } ).getDatasourceName() )
					.toBe( "mySupportDsn" );
			} );

			it( "uses the application-defined name otherwise", function () {
				expect( buildConfigService().getDatasourceName() ).toBe( "slackSupportChat" );
			} );
		} );
	}

}
