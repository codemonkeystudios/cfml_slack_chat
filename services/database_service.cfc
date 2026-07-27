/**
 * Owns everything that differs between SQL Server, MySQL and PostgreSQL.
 *
 * The rest of the application writes one dialect of SQL. When a statement
 * genuinely cannot be written once — atomic insert-if-missing, returning a
 * generated identity value, inspecting the schema — the branch lives here and
 * nowhere else.
 *
 * The datasource reference may be a string (a name defined by the CFML server
 * or by Application.cfc) or, on Lucee only, a full datasource struct. The struct
 * form is what lets the CommandBox task reach the same database without a
 * server-defined datasource.
 */
component accessors="false" {

	variables.required_tables = [ "conversation", "conversation_message", "slack_event_inbox", "slack_outbound_delivery" ];

	/**
	 * @datasource Datasource name, or a Lucee datasource struct.
	 * @platform postgresql | mysql | sqlserver
	 */
	public database_service function init( required any datasource, required string platform ) {

		variables.datasource = arguments.datasource;
		variables.platform = lCase( trim( arguments.platform ) );

		if ( !arrayFindNoCase( [ "postgresql", "mysql", "sqlserver" ], variables.platform ) ) {
			throw(
				type = "Configuration.Invalid",
				message = "Unsupported database platform ""#arguments.platform#"". Supported values are postgresql, mysql and sqlserver."
			);
		}

		return this;
	}

	public string function getPlatform() {
		return variables.platform;
	}

	// ------------------------------------------------------------ query access

	public any function run( required string sql, struct params = {}, struct options = {} ) {

		var query_options = duplicate( arguments.options );
		query_options.datasource = variables.datasource;

		return queryExecute( arguments.sql, arguments.params, query_options );
	}

	/**
	 * Run a statement and return the result metadata (affected rows, generated
	 * keys) rather than a recordset.
	 */
	public struct function runWithResult( required string sql, struct params = {} ) {

		var query_result = {};

		queryExecute( arguments.sql, arguments.params, {
			"datasource" : variables.datasource,
			"result" : "query_result"
		} );

		return query_result;
	}

	// ------------------------------------------------------------------ schema

	/**
	 * Which of the application's tables exist. Uses each platform's own idea of
	 * "the current database", because information_schema is standard right up
	 * until you ask it a useful question.
	 */
	public struct function getSchemaStatus() {

		var status = { "reachable":false, "error":"", "present":[], "missing":[], "platform":variables.platform };

		try {
			var sql = "";

			switch ( variables.platform ) {
				case "postgresql":
					sql = "select table_name from information_schema.tables where table_schema = current_schema()";
					break;
				case "mysql":
					sql = "select table_name from information_schema.tables where table_schema = database()";
					break;
				default:
					sql = "select table_name from information_schema.tables where table_catalog = db_name()";
			}

			var found = run( sql );
			var names = {};

			for ( var row in found ) {
				names[ lCase( row.table_name ) ] = true;
			}

			status.reachable = true;

			for ( var table_name in variables.required_tables ) {
				if ( structKeyExists( names, table_name ) ) {
					arrayAppend( status.present, table_name );
				} else {
					arrayAppend( status.missing, table_name );
				}
			}

		} catch ( any e ) {
			status.error = e.message;
		}

		return status;
	}

	public void function requireSchema() {

		var status = getSchemaStatus();

		if ( !status.reachable ) {
			throw( type = "Database.SchemaMissing", message = "The configured datasource is not reachable.", detail = status.error );
		}

		if ( arrayLen( status.missing ) ) {
			throw(
				type = "Database.SchemaMissing",
				message = "The datasource is reachable, but these tables are missing: "
				 & arrayToList( status.missing, ", " )
				 & ". Run the script in sql/ for your database."
			);
		}
	}

	// --------------------------------------------------- platform SQL fragments

	/**
	 * Insert a row and return its generated BIGINT identity value.
	 *
	 * PostgreSQL and SQL Server can return the key in the insert itself. MySQL
	 * needs a follow-up call on the same connection, which is why callers must
	 * already be inside a transaction.
	 *
	 * @table Target table.
	 * @id_column Identity column to return.
	 * @columns Ordered array of column names.
	 * @params Ordered array of queryparam structs matching columns.
	 */
	public numeric function insertReturningId(
		required string table,
		required string id_column,
		required array columns,
		required array params
	) {

		var column_list = arrayToList( arguments.columns, ", " );
		var placeholders = [];
		var named_params = {};

		for ( var index = 1; index <= arrayLen( arguments.columns ); index++ ) {
			var param_name = "p" & index;
			arrayAppend( placeholders, ":" & param_name );
			named_params[ param_name ] = arguments.params[ index ];
		}

		var placeholder_list = arrayToList( placeholders, ", " );

		switch ( variables.platform ) {

			case "postgresql":
				var postgres_result = run(
					"insert into #arguments.table# (#column_list#) values (#placeholder_list#) returning #arguments.id_column# as generated_id",
					named_params
				);
				return postgres_result.generated_id[ 1 ];

			case "sqlserver":
				var sqlserver_result = run(
					"insert into #arguments.table# (#column_list#) output inserted.#arguments.id_column# as generated_id values (#placeholder_list#)",
					named_params
				);
				return sqlserver_result.generated_id[ 1 ];

			default:
				run( "insert into #arguments.table# (#column_list#) values (#placeholder_list#)", named_params );
				var mysql_result = run( "select last_insert_id() as generated_id" );
				return mysql_result.generated_id[ 1 ];
		}
	}

	/**
	 * Insert a Slack event unless its event_id is already present.
	 *
	 * Every branch is a single atomic statement backed by the primary key. No
	 * select-then-insert, because two Slack retries arriving a millisecond apart
	 * would race straight through that.
	 *
	 * Returns true when this call is believed to have created the row. The value
	 * is advisory and used only for logging: correctness comes from the unique
	 * constraint, not from the return value.
	 */
	public boolean function insertEventIfMissing( required struct row ) {

		var column_list = "event_id, event_type, inner_event_type, payload, raw_body, retry_num, retry_reason, received_at, next_attempt_at, status, attempt_count";
		var value_list = ":event_id, :event_type, :inner_event_type, :payload, :raw_body, :retry_num, :retry_reason, :received_at, :received_at, 'pending', 0";

		var params = {
			"event_id" : { value:arguments.row.event_id, cfsqltype:"cf_sql_varchar" },
			"event_type" : { value:arguments.row.event_type, cfsqltype:"cf_sql_varchar" },
			"inner_event_type" : { value:arguments.row.inner_event_type, cfsqltype:"cf_sql_varchar", null:!len( arguments.row.inner_event_type ) },
			"payload" : { value:arguments.row.payload, cfsqltype:"cf_sql_longvarchar" },
			"raw_body" : { value:arguments.row.raw_body, cfsqltype:"cf_sql_longvarchar" },
			"retry_num" : { value:arguments.row.retry_num, cfsqltype:"cf_sql_integer" },
			"retry_reason" : { value:arguments.row.retry_reason, cfsqltype:"cf_sql_varchar", null:!len( arguments.row.retry_reason ) },
			"received_at" : { value:arguments.row.received_at, cfsqltype:"cf_sql_timestamp" }
		};

		var sql = "";

		switch ( variables.platform ) {

			case "postgresql":
				sql = "insert into slack_event_inbox (#column_list#) values (#value_list#) on conflict (event_id) do nothing";
				break;

			case "mysql":
				// ON DUPLICATE KEY UPDATE with a no-op assignment, rather than
				// INSERT IGNORE, which would also swallow unrelated errors.
				sql = "insert into slack_event_inbox (#column_list#) values (#value_list#) on duplicate key update event_id = event_id";
				break;

			default:
				sql = "insert into slack_event_inbox (#column_list#)
				 select #value_list#
				 where not exists (
				 select 1 from slack_event_inbox with (updlock, holdlock) where event_id = :event_id
				 )";
		}

		try {
			var query_result = runWithResult( sql, params );
			return structKeyExists( query_result, "recordCount" ) ? query_result.recordCount > 0 : true;
		} catch ( any e ) {
			// A concurrent insert that beat us to the primary key is the exact
			// outcome we wanted anyway.
			if ( isUniqueConstraintViolation( e ) ) {
				return false;
			}
			rethrow;
		}
	}

	public boolean function isUniqueConstraintViolation( required any exception ) {

		var text = lCase( ( arguments.exception.message ?: "" ) & " " & ( arguments.exception.detail ?: "" ) );

		return findNoCase( "duplicate key", text ) > 0
			|| findNoCase( "duplicate entry", text ) > 0
			|| findNoCase( "unique constraint", text ) > 0
			|| findNoCase( "unique index", text ) > 0
			|| findNoCase( "violation of unique", text ) > 0;
	}

	// -------------------------------------------------------------- identifiers

	/**
	 * A UUIDv7: 48 bits of millisecond timestamp followed by random bits, so
	 * identifiers sort in creation order instead of shredding the B-tree the way
	 * fully random UUIDs do. Stored as 36 characters for portability.
	 */
	public string function newConversationId() {

		// Long.toHexString, not formatBaseN: a millisecond epoch is comfortably
		// larger than the 32-bit integer formatBaseN is willing to accept.
		var epoch_millis = createObject( "java", "java.lang.System" ).currentTimeMillis();
		var epoch_hex = createObject( "java", "java.lang.Long" ).toHexString( javaCast( "long", epoch_millis ) );
		var time_hex = right( repeatString( "0", 12 ) & lCase( epoch_hex ), 12 );
		var random_hex = randomHex( 18 );

		var version_block = "7" & mid( random_hex, 1, 3 );
		var variant_block = mid( "89ab", randRange( 1, 4, "SHA1PRNG" ), 1 ) & mid( random_hex, 4, 3 );

		return mid( time_hex, 1, 8 ) & "-"
		 & mid( time_hex, 9, 4 ) & "-"
		 & version_block & "-"
		 & variant_block & "-"
		 & mid( random_hex, 7, 12 );
	}

	/** 256 bits of conversation access token, hex encoded. */
	public string function newAccessToken() {
		return randomHex( 64 );
	}

	public string function hashToken( required string token ) {
		return lCase( hash( arguments.token, "SHA-256", "utf-8" ) );
	}

	public string function randomHex( required numeric length ) {

		var bytes_needed = ceiling( arguments.length / 2 );
		var secure_random = createObject( "java", "java.security.SecureRandom" ).init();

		var buffer = createObject( "java", "java.lang.reflect.Array" ).newInstance(
			createObject( "java", "java.lang.Byte" ).TYPE,
			javaCast( "int", bytes_needed )
		);

		secure_random.nextBytes( buffer );

		return left( lCase( binaryEncode( buffer, "hex" ) ), arguments.length );
	}

	// --------------------------------------------------------------- timestamps

	/** Everything is stored in UTC. Local time is a presentation concern. */
	public date function utcNow() {
		return dateConvert( "local2utc", now() );
	}

	public numeric function epochSeconds() {
		return int( createObject( "java", "java.lang.System" ).currentTimeMillis() / 1000 );
	}

	/** ISO 8601 in UTC, for JSON payloads. */
	public string function toIso( required any value ) {

		if ( !isDate( arguments.value ) ) {
			return "";
		}

		return dateTimeFormat( arguments.value, "yyyy-mm-dd'T'HH:nn:ss'Z'" );
	}

}
