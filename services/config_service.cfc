/**
 * Loads, validates and persists the runtime configuration for the Slack-backed
 * support chat.
 *
 * Precedence, highest first:
 * 1. Environment variables
 * 2. The local JSON configuration file (ignored by git, never served)
 * 3. Non-secret defaults defined in this component
 *
 * A value supplied by the environment is treated as authoritative and locked:
 * the setup form may show that it is set, but may not overwrite it. That keeps
 * a container or CI environment from being silently reconfigured by whoever
 * last opened a browser tab.
 */
component accessors="false" {

	// Dotted paths whose values must never reach the browser, a log file or an
	// API response.
	variables.secret_keys = [ "slack.bot_token", "slack.signing_secret", "database.password" ];

	// Environment variable name -> dotted config path.
	variables.environment_map = {
		"SLACK_BOT_TOKEN" : "slack.bot_token",
		"SLACK_SIGNING_SECRET" : "slack.signing_secret",
		"SLACK_CHANNEL_ID" : "slack.channel_id",
		"SLACK_APP_ID" : "slack.app_id",
		"SLACK_TEAM_ID" : "slack.team_id",
		"SLACK_BOT_USER_ID" : "slack.bot_user_id",
		"CF_DATASOURCE" : "database.datasource",
		"DB_TYPE" : "database.type",
		"DB_HOST" : "database.host",
		"DB_PORT" : "database.port",
		"DB_NAME" : "database.database",
		"DB_USER" : "database.username",
		"DB_PASSWORD" : "database.password",
		"PUBLIC_BASE_URL" : "app.public_base_url"
	};

	/**
	 * @config_file Absolute path to the runtime configuration file. Defaults to
	 * SLACK_CHAT_CONFIG_FILE, then <webroot>/.config/config.json.
	 */
	public config_service function init( string config_file = "" ) {

		variables.environment = readEnvironment();

		if ( len( trim( arguments.config_file ) ) ) {
			variables.config_file = arguments.config_file;
		} else if ( len( environmentValue( "SLACK_CHAT_CONFIG_FILE" ) ) ) {
			variables.config_file = environmentValue( "SLACK_CHAT_CONFIG_FILE" );
		} else {
			variables.config_file = expandPath( "/.config/config.json" );
		}

		load();

		return this;
	}

	// ----------------------------------------------------------------- reading

	/**
	 * The merged configuration including secrets. Server side only. Never hand
	 * the result of this method to a view, an API response or a log entry.
	 */
	public struct function getConfig() {
		return duplicate( variables.config );
	}

	/**
	 * The merged configuration with every secret replaced by a boolean marker.
	 * This is the only shape allowed to reach the browser.
	 */
	public struct function getPublicConfig() {

		var safe = duplicate( variables.config );

		for ( var path in variables.secret_keys ) {
			var parts = listToArray( path, "." );
			var section = safe[ parts[ 1 ] ];
			var key = parts[ 2 ];
			section[ key & "_is_set" ] = len( trim( section[ key ] ) ) > 0;
			structDelete( section, key );
		}

		safe.meta = {
			"config_file" : variables.config_file,
			"config_file_exists" : fileExists( variables.config_file ),
			"environment_locked" : getEnvironmentLockedPaths()
		};

		return safe;
	}

	public any function getSetting( required string path, any default_value = "" ) {

		var parts = listToArray( arguments.path, "." );

		if ( !structKeyExists( variables.config, parts[ 1 ] ) ) {
			return arguments.default_value;
		}

		var section = variables.config[ parts[ 1 ] ];
		return structKeyExists( section, parts[ 2 ] ) ? section[ parts[ 2 ] ] : arguments.default_value;
	}

	public string function getConfigFilePath() {
		return variables.config_file;
	}

	/**
	 * Dotted config paths currently supplied by the environment. The setup form
	 * renders these read-only.
	 */
	public array function getEnvironmentLockedPaths() {

		var locked = [];

		for ( var name in variables.environment_map ) {
			if ( len( trim( environmentValue( name ) ) ) ) {
				arrayAppend( locked, variables.environment_map[ name ] );
			}
		}

		return locked;
	}

	public boolean function isEnvironmentLocked( required string path ) {
		return arrayFindNoCase( getEnvironmentLockedPaths(), arguments.path ) > 0;
	}

	// -------------------------------------------------------------- validation

	/**
	 * Settings that must be present before the chat interface can be shown.
	 * Returns an array of { path, label, reason } structs; empty means ready.
	 */
	public array function getMissingSettings() {

		var missing = [];
		var database = variables.config.database;

		var required_settings = [
			{ "path":"slack.bot_token", "label":"Slack bot token", "reason":"Without a bot token the application cannot post anything into Slack." },
			{ "path":"slack.signing_secret", "label":"Slack signing secret", "reason":"Without the signing secret every inbound Slack event has to be rejected as unverifiable." },
			{ "path":"slack.channel_id", "label":"Slack channel ID", "reason":"The application needs to know which channel the support threads belong in." },
			{ "path":"database.type", "label":"Database type", "reason":"The SQL dialect depends on knowing which database this is." }
		];

		for ( var item in required_settings ) {
			if ( !len( trim( getSetting( item.path ) ) ) ) {
				arrayAppend( missing, item );
			}
		}

		if ( database.mode == "existing" ) {
			if ( !len( trim( database.datasource ) ) ) {
				arrayAppend( missing, {
					"path" : "database.datasource",
					"label" : "Datasource name",
					"reason" : "You chose an existing server datasource but did not name it."
				} );
			}
		} else {
			for ( var field in [ "host", "port", "database", "username" ] ) {
				if ( !len( trim( database[ field ] ) ) ) {
					arrayAppend( missing, {
						"path" : "database." & field,
						"label" : "Database " & field,
						"reason" : "Application-managed datasources need the full set of connection values."
					} );
				}
			}
		}

		return missing;
	}

	public boolean function isConfigured() {
		return arrayLen( getMissingSettings() ) == 0;
	}

	/**
	 * Field level validation for values arriving from the setup form. Returns an
	 * array of { field, message } structs.
	 */
	public array function validateInput( required struct input ) {

		var errors = [];

		var bot_token = inputValue( arguments.input, "slack_bot_token" );
		if ( len( bot_token ) && !reFind( "^xox[bpe]-", bot_token ) ) {
			arrayAppend( errors, {
				"field" : "slack_bot_token",
				"message" : "A Slack bot token normally starts with ""xoxb-"". Check that you copied the Bot User OAuth Token rather than an app-level or user token."
			} );
		}

		var signing_secret = inputValue( arguments.input, "slack_signing_secret" );
		if ( len( signing_secret ) && len( signing_secret ) < 16 ) {
			arrayAppend( errors, {
				"field" : "slack_signing_secret",
				"message" : "That signing secret is too short to be real. Slack issues a 32 character hexadecimal value."
			} );
		}

		var channel_id = inputValue( arguments.input, "slack_channel_id" );
		if ( len( channel_id ) ) {
			if ( left( channel_id, 1 ) == "##" ) {
				arrayAppend( errors, {
					"field" : "slack_channel_id",
					"message" : "Use the channel ID, not the channel name. Slack's API is entirely unmoved by ""##support"" and wants something like ""C0123456789""."
				} );
			} else if ( !reFind( "^[CGD][A-Z0-9]{6,}$", channel_id ) ) {
				arrayAppend( errors, {
					"field" : "slack_channel_id",
					"message" : "Channel IDs look like ""C0123456789"". Open the channel in Slack, choose View channel details, and copy the ID from the bottom of the panel."
				} );
			}
		}

		var public_base_url = inputValue( arguments.input, "app_public_base_url" );
		var allow_insecure = isTruthy( inputValue( arguments.input, "app_allow_insecure_public_url" ) );

		if ( len( public_base_url ) ) {
			if ( !reFindNoCase( "^https?://", public_base_url ) ) {
				arrayAppend( errors, {
					"field" : "app_public_base_url",
					"message" : "The public base URL must include a scheme, for example https://example.trycloudflare.com."
				} );
			} else if ( reFindNoCase( "^https?://(localhost|127\.0\.0\.1|\[::1\])", public_base_url ) && !allow_insecure ) {
				arrayAppend( errors, {
					"field" : "app_public_base_url",
					"message" : "Slack's servers cannot reach ""localhost"". That address is extremely meaningful to your laptop and to nobody else."
				} );
			} else if ( !reFindNoCase( "^https://", public_base_url ) && !allow_insecure ) {
				arrayAppend( errors, {
					"field" : "app_public_base_url",
					"message" : "The Events API requires a publicly reachable HTTPS endpoint. Start a tunnel, or tick local-only mode if you are deliberately testing without Slack callbacks."
				} );
			}
		}

		var default_email = inputValue( arguments.input, "visitor_default_email" );
		if ( len( default_email ) && !isValid( "email", default_email ) ) {
			arrayAppend( errors, {
				"field" : "visitor_default_email",
				"message" : "That default visitor email address is not a valid address."
			} );
		}

		var mode = inputValue( arguments.input, "database_mode" );
		if ( len( mode ) && !arrayFindNoCase( [ "existing", "application" ], mode ) ) {
			arrayAppend( errors, {
				"field" : "database_mode",
				"message" : "Choose either an existing server datasource or application-managed connection settings."
			} );
		}

		var database_type = inputValue( arguments.input, "database_type" );
		if ( len( database_type ) && !arrayFindNoCase( [ "postgresql", "mysql", "sqlserver" ], database_type ) ) {
			arrayAppend( errors, {
				"field" : "database_type",
				"message" : "Supported database types are postgresql, mysql and sqlserver."
			} );
		}

		if ( mode == "application" ) {
			var port = inputValue( arguments.input, "database_port" );
			if ( len( port ) && ( !isNumeric( port ) || port < 1 || port > 65535 ) ) {
				arrayAppend( errors, {
					"field" : "database_port",
					"message" : "The database port must be a number between 1 and 65535."
				} );
			}
		}

		return errors;
	}

	// ------------------------------------------------------------- persistence

	/**
	 * Merge form input into the stored configuration and write it to disk.
	 *
	 * Input keys use the flattened "section_key" form produced by the setup
	 * form. Blank secret fields are ignored, so an operator can re-save the page
	 * without wiping a token they were never shown in the first place.
	 */
	public struct function save( required struct input ) {

		var stored = fileExists( variables.config_file ) ? readConfigFile() : buildDefaults();
		var defaults = buildDefaults();

		for ( var section in [ "slack", "database", "app", "visitor" ] ) {

			if ( !structKeyExists( stored, section ) ) {
				stored[ section ] = {};
			}

			for ( var key in structKeyArray( defaults[ section ] ) ) {

				var form_key = section & "_" & key;
				var dotted_path = section & "." & key;

				if ( !structKeyExists( arguments.input, form_key ) ) {
					continue;
				}
				if ( isEnvironmentLocked( dotted_path ) ) {
					continue;
				}

				var value = arguments.input[ form_key ];
				value = isSimpleValue( value ) ? trim( value ) : value;

				// Never clear a stored secret just because the form posted an
				// empty masked field.
				if ( arrayFindNoCase( variables.secret_keys, dotted_path ) && !len( value ) ) {
					continue;
				}

				stored[ section ][ key ] = value;
			}
		}

		writeConfigFile( stored );
		load();

		return getPublicConfig();
	}

	/**
	 * Persist a single derived value, such as the bot user ID discovered by
	 * calling auth.test during configuration validation.
	 */
	public void function saveDerived( required string path, required string value ) {

		if ( isEnvironmentLocked( arguments.path ) ) {
			return;
		}

		var parts = listToArray( arguments.path, "." );
		var stored = fileExists( variables.config_file ) ? readConfigFile() : buildDefaults();

		if ( !structKeyExists( stored, parts[ 1 ] ) ) {
			stored[ parts[ 1 ] ] = {};
		}

		stored[ parts[ 1 ] ][ parts[ 2 ] ] = arguments.value;

		writeConfigFile( stored );
		load();
	}

	/** Re-read environment and file. Called after the setup form saves. */
	public void function reload() {
		variables.environment = readEnvironment();
		load();
	}

	// -------------------------------------------------------- datasource wiring

	/**
	 * Build the engine-specific datasource definition consumed by
	 * Application.cfc's this.datasources struct.
	 *
	 * Lucee wants a JDBC class plus a connection string. Adobe ColdFusion wants
	 * a named driver with discrete host, port and database values. This is the
	 * one place in the application that cares about the difference.
	 */
	public struct function buildDatasourceDefinition() {

		var database = variables.config.database;

		if ( database.mode != "application" ) {
			throw(
				type = "Configuration.Invalid",
				message = "buildDatasourceDefinition() is only valid when the database mode is ""application""."
			);
		}

		var port = len( trim( database.port ) ) ? database.port : getDefaultPort( database.type );

		if ( isLucee() ) {
			var driver = buildJdbcDriver( database.type, database.host, port, database.database );
			return {
				"class" : driver.class,
				"connectionString" : driver.url,
				"username" : database.username,
				"password" : database.password,
				"connectionLimit" : 25,
				"connectionTimeout" : 1
			};
		}

		var adobe_drivers = { "postgresql":"PostgreSQL", "mysql":"MySQL", "sqlserver":"MSSQLServer" };

		return {
			"driver" : adobe_drivers[ database.type ],
			"host" : database.host,
			"port" : port,
			"database" : database.database,
			"username" : database.username,
			"password" : database.password
		};
	}

	/**
	 * A Lucee-only datasource struct suitable for passing straight to
	 * queryExecute(). Used by the CommandBox task, which runs outside the web
	 * application and therefore has no server-defined datasources to borrow.
	 */
	public struct function buildStandaloneDatasource() {

		var database = variables.config.database;

		if ( database.mode != "application" ) {
			throw(
				type = "Configuration.Invalid",
				message = "The command line event processor needs application-managed database settings. You configured an existing server datasource named """
				 & database.datasource
				 & """, which only exists inside the CFML server. Either add host, port, database, user and password to the configuration, or run the processor from the application's diagnostics panel."
			);
		}

		var port = len( trim( database.port ) ) ? database.port : getDefaultPort( database.type );
		var driver = buildJdbcDriver( database.type, database.host, port, database.database );

		return {
			"class" : driver.class,
			"connectionString" : driver.url,
			"username" : database.username,
			"password" : database.password
		};
	}

	public string function getDefaultPort( required string type ) {
		var ports = { "postgresql":"5432", "mysql":"3306", "sqlserver":"1433" };
		return structKeyExists( ports, arguments.type ) ? ports[ arguments.type ] : "";
	}

	/**
	 * The datasource reference handed to DatabaseService inside the web
	 * application: either the operator's own datasource name, or the name of the
	 * datasource Application.cfc defines from these settings.
	 */
	public string function getDatasourceName() {
		return variables.config.database.mode == "existing"
			? variables.config.database.datasource
			: "slackSupportChat";
	}

	/** The Request URL an operator pastes into Slack's Event Subscriptions page. */
	public string function getEventsRequestUrl() {

		var base = trim( variables.config.app.public_base_url );

		if ( !len( base ) ) {
			return "";
		}

		return reReplace( base, "/+$", "" ) & "/slack/events.cfm";
	}

	// --------------------------------------------------------------- internals

	private struct function buildJdbcDriver(
		required string type,
		required string host,
		required string port,
		required string database_name
	) {

		switch ( arguments.type ) {

			case "postgresql":
				return {
					"class" : "org.postgresql.Driver",
					"url" : "jdbc:postgresql://#arguments.host#:#arguments.port#/#arguments.database_name#"
				};

			case "mysql":
				// useAffectedRows=true makes the driver report rows *changed*
				// rather than rows *matched*, which is what PostgreSQL and SQL
				// Server report. Without it, "insert ... on duplicate key update"
				// claims to have inserted a row it only found.
				return {
					"class" : "com.mysql.cj.jdbc.Driver",
					"url" : "jdbc:mysql://#arguments.host#:#arguments.port#/#arguments.database_name#?useUnicode=true&characterEncoding=UTF-8&serverTimezone=UTC&allowPublicKeyRetrieval=true&useSSL=false&useAffectedRows=true"
				};

			case "sqlserver":
				return {
					"class" : "com.microsoft.sqlserver.jdbc.SQLServerDriver",
					"url" : "jdbc:sqlserver://#arguments.host#:#arguments.port#;databaseName=#arguments.database_name#;encrypt=false"
				};

			default:
				throw( type = "Configuration.Invalid", message = "Unsupported database type ""#arguments.type#""." );
		}
	}

	private void function load() {

		var merged = buildDefaults();

		if ( fileExists( variables.config_file ) ) {

			var stored = readConfigFile();

			for ( var section in stored ) {

				if ( !structKeyExists( merged, section ) || !isStruct( stored[ section ] ) ) {
					continue;
				}

				for ( var key in stored[ section ] ) {
					if ( structKeyExists( merged[ section ], key ) ) {
						merged[ section ][ key ] = stored[ section ][ key ];
					}
				}
			}
		}

		for ( var name in variables.environment_map ) {

			var value = environmentValue( name );

			if ( !len( trim( value ) ) ) {
				continue;
			}

			var parts = listToArray( variables.environment_map[ name ], "." );
			merged[ parts[ 1 ] ][ parts[ 2 ] ] = value;
		}

		// CF_DATASOURCE only makes sense alongside the "existing" mode.
		if ( len( trim( environmentValue( "CF_DATASOURCE" ) ) ) ) {
			merged.database.mode = "existing";
		}

		merged.app.auto_process_events = isTruthy( merged.app.auto_process_events );
		merged.app.dev_tools = isTruthy( merged.app.dev_tools );
		merged.app.log_message_bodies = isTruthy( merged.app.log_message_bodies );
		merged.app.allow_insecure_public_url = isTruthy( merged.app.allow_insecure_public_url );

		variables.config = merged;
	}

	private struct function buildDefaults() {
		return {
			"slack" : {
				"bot_token" : "",
				"signing_secret" : "",
				"channel_id" : "",
				"app_id" : "",
				"team_id" : "",
				"bot_user_id" : ""
			},
			"database" : {
				"mode" : "application",
				"datasource" : "",
				"type" : "postgresql",
				"host" : "localhost",
				"port" : "5432",
				"database" : "",
				"username" : "",
				"password" : ""
			},
			"app" : {
				"public_base_url" : "",
				"allow_insecure_public_url" : false,
				"auto_process_events" : true,
				"dev_tools" : true,
				"log_message_bodies" : false,
				"max_message_length" : 4000,
				"sse_max_seconds" : 55,
				"sse_poll_milliseconds" : 1500,
				"slack_timeout_seconds" : 15,
				"signature_max_age_seconds" : 300
			},
			"visitor" : {
				"default_name" : "",
				"default_email" : ""
			}
		};
	}

	private struct function readConfigFile() {

		try {
			var raw = fileRead( variables.config_file, "utf-8" );

			if ( !isJSON( raw ) ) {
				throw( type = "Configuration.Invalid", message = "The configuration file at #variables.config_file# is not valid JSON." );
			}

			return deserializeJSON( raw );

		} catch ( Configuration.Invalid e ) {
			rethrow;
		} catch ( any e ) {
			throw(
				type = "Configuration.Invalid",
				message = "Could not read the configuration file at #variables.config_file#.",
				detail = e.message
			);
		}
	}

	private void function writeConfigFile( required struct data ) {

		var config_directory = getDirectoryFromPath( variables.config_file );

		if ( !directoryExists( config_directory ) ) {
			directoryCreate( config_directory, true );
		}

		fileWrite( variables.config_file, serializeJSON( arguments.data, true ), "utf-8" );

		// Best effort on POSIX systems. Windows will decline, which is fine.
		try {
			fileSetAccessMode( variables.config_file, "600" );
		} catch ( any e ) {
		}
	}

	private struct function readEnvironment() {

		try {
			if ( structKeyExists( server, "system" ) && structKeyExists( server.system, "environment" ) ) {
				return server.system.environment;
			}
		} catch ( any e ) {
		}

		return createObject( "java", "java.lang.System" ).getenv();
	}

	private string function environmentValue( required string name ) {
		return structKeyExists( variables.environment, arguments.name ) ? variables.environment[ arguments.name ] : "";
	}

	private string function inputValue( required struct input, required string key ) {
		return structKeyExists( arguments.input, arguments.key ) ? trim( arguments.input[ arguments.key ] ) : "";
	}

	private boolean function isTruthy( required any value ) {

		if ( isBoolean( arguments.value ) ) {
			return arguments.value;
		}

		return arrayFindNoCase( [ "true", "yes", "on", "1" ], trim( arguments.value ) ) > 0;
	}

	private boolean function isLucee() {
		return structKeyExists( server, "lucee" );
	}

}
