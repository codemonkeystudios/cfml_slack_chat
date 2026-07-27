<cfsetting enablecfoutputonly="true" showdebugoutput="false">
<cfscript>
	/**
	* Shared plumbing for the JSON endpoints. Included, never requested.
	*
	* Defines the response writers, the JSON body reader and the CSRF check that all
	* three endpoints need. The interesting decisions — which exception becomes
	* which status code — live in services/ApiService.cfc, where they can be tested.
	*/

	// This file only defines functions. Requesting it directly achieves nothing, so
	// say so rather than returning a confusing empty 200.
	if ( right( cgi.script_name ?: "", 17 ) == "/api/response.cfm" ) {
		cfheader( statuscode = 404, statustext = "Not Found" );
		writeOutput( "Not found." );
		abort;
	}

	void function writeJson( required numeric status_code, required any body ) {
		cfheader( statuscode = arguments.status_code, statustext = application.slack_chat.api.statusTextFor( arguments.status_code ) );
		cfcontent( type = "application/json; charset=utf-8", variable = charsetDecode( serializeJSON( arguments.body ), "utf-8" ) );
		abort;
	}

	void function writeError( required numeric status_code, required string code, required string message ) {
		writeJson( arguments.status_code, { "ok":false, "error":{ "code":arguments.code, "message":arguments.message } } );
	}

	void function writeException( required any exception, string context = "" ) {
		var described = application.slack_chat.api.describeError( arguments.exception, arguments.context );
		writeJson( described.status_code, described.body );
	}

	void function requireMethod( required string method ) {
		if ( ( cgi.request_method ?: "" ) != arguments.method ) {
			writeError( 405, "method_not_allowed", "This endpoint expects " & arguments.method & "." );
		}
	}

	void function requireReady() {
		if ( !( application.slack_chat.ready ?: false ) ) {
			writeError( 503, "not_configured", "The application is not configured yet. Finish setup first." );
		}
	}

	/**
	* The conversation access token is the real authorization, but a matching CSRF
	* token keeps another origin from driving this API with the visitor's cookies.
	*/
	void function requireCsrfToken() {

		var headers = getHttpRequestData().headers ?: {};
		var sent_token = structKeyExists( headers, "X-CSRF-Token" ) ? trim( headers[ "X-CSRF-Token" ] ) : "";
		var session_csrf = session.csrf_token ?: "";

		if ( !len( sent_token ) || !len( session_csrf ) || compare( sent_token, session_csrf ) != 0 ) {
			writeError( 403, "csrf_failed", "The request could not be verified. Reload the page and try again." );
		}
	}

	/** Parse the JSON request body, refusing anything oversized or malformed. */
	struct function readJsonBody( numeric max_bytes = 65536 ) {

		var request_data = getHttpRequestData();
		var raw_body = isBinary( request_data.content )
			? charsetEncode( request_data.content, "utf-8" )
			: toString( request_data.content );

		if ( len( raw_body ) > arguments.max_bytes ) {
			writeError( 413, "request_too_large", "That request body is larger than this endpoint accepts." );
		}

		if ( !len( trim( raw_body ) ) ) {
			return {};
		}

		if ( !isJSON( raw_body ) ) {
			writeError( 400, "invalid_json", "The request body was not valid JSON." );
		}

		var parsed = deserializeJSON( raw_body );

		if ( !isStruct( parsed ) ) {
			writeError( 400, "invalid_json", "The request body must be a JSON object." );
		}

		return parsed;
	}

	string function bodyValue( required struct body, required string key ) {

		if ( !structKeyExists( arguments.body, arguments.key ) ) {
			return "";
		}

		var value = arguments.body[ arguments.key ];

		return isSimpleValue( value ) ? trim( value ) : "";
	}

	/** Remember a conversation's access token for this browser session. */
	void function rememberConversation( required string conversation_id, required string access_token ) {

		if ( !structKeyExists( session, "conversations" ) ) {
			session.conversations = {};
		}

		session.conversations[ arguments.conversation_id ] = arguments.access_token;
	}

	/**
	* The token the caller supplied, falling back to the one this session already
	* holds for the conversation.
	*/
	string function resolveAccessToken( required string conversation_id, required string supplied_token ) {

		if ( len( trim( arguments.supplied_token ) ) ) {
			return trim( arguments.supplied_token );
		}

		if ( structKeyExists( session, "conversations" ) && structKeyExists( session.conversations, arguments.conversation_id ) ) {
			return session.conversations[ arguments.conversation_id ];
		}

		return "";
	}
</cfscript>
