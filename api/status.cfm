<cfsetting enablecfoutputonly="true" showdebugoutput="false">
<cfinclude template="response.cfm">
<cfscript>
	/**
	* /api/status.cfm
	*
	* GET safe diagnostic state, plus conversation detail when authorized
	* POST { "action":"process-queues" } development-only queue drain
	*
	* No secrets. Not the bot token, not the signing secret, not the datasource
	* password, not a conversation access token. The only thing this endpoint says
	* about a secret is whether one is present.
	*
	* The POST action is not an administrative endpoint for the internet: it
	* requires development tools to be enabled, a loopback client, and a matching
	* CSRF token. The supported way to run the worker is the CommandBox task.
	*/

	slack_chat = application.slack_chat;
	request_method = cgi.request_method ?: "";

	if ( request_method == "POST" ) {

		requireCsrfToken();

		body = readJsonBody();
		action = bodyValue( body, "action" );

		if ( action != "process-queues" ) {
			writeError( 400, "unknown_action", "The only supported action is process-queues." );
		}

		if ( !slack_chat.config_service.getSetting( "app.dev_tools" ) ) {
			writeError( 403, "dev_tools_disabled", "Development tools are switched off. Run the CommandBox task instead." );
		}

		remote_address = cgi.remote_addr ?: "";

		if ( !arrayFindNoCase( [ "127.0.0.1", "0:0:0:0:0:0:0:1", "::1", "localhost" ], remote_address ) ) {
			writeError( 403, "not_local", "This action is only available from the machine running the server." );
		}

		requireReady();

		try {
			event_summary = slack_chat.events.processPendingEvents();
			delivery_summary = slack_chat.deliveries.processPendingDeliveries();
		} catch ( any processing_error ) {
			writeException( processing_error, "status.processQueues" );
		}

		writeJson( 200, { "ok":true, "events":event_summary, "deliveries":delivery_summary } );
	}

	requireMethod( "GET" );

	config_service = slack_chat.config_service;
	public_config = config_service.getPublicConfig();

	response = {
		"ok" : true,
		"status" : {
			"ready" : slack_chat.ready ?: false,
			"readyReason" : slack_chat.ready_reason ?: "",
			// server.coldfusion.productversion reports the CFML compatibility level on
			// Lucee, which is not the same thing as the engine version.
			"engine" : structKeyExists( server, "lucee" )
				? "Lucee " & server.lucee.version
				: server.coldfusion.productname & " " & server.coldfusion.productversion,
			"databasePlatform" : public_config.database.type,
			"databaseMode" : public_config.database.mode,
			"datasourceName" : config_service.getDatasourceName(),
			"botTokenSet" : public_config.slack.bot_token_is_set,
			"signingSecretSet" : public_config.slack.signing_secret_is_set,
			"channelId" : public_config.slack.channel_id,
			"botUserId" : public_config.slack.bot_user_id,
			"publicBaseUrl" : public_config.app.public_base_url,
			"eventsRequestUrl" : config_service.getEventsRequestUrl(),
			"autoProcessEvents": public_config.app.auto_process_events,
			"devTools" : public_config.app.dev_tools
		}
	};

	if ( slack_chat.ready ?: false ) {
		response.status[ "schema" ] = slack_chat.db.getSchemaStatus();
		response.status[ "eventQueue" ] = slack_chat.events.getQueueStatus();
	}

	// Conversation detail, only for a caller holding the access token.
	conversation_id = trim( url.conversationId ?: "" );

	if ( len( conversation_id ) && ( slack_chat.ready ?: false ) ) {

		access_token = resolveAccessToken( conversation_id, trim( url.accessToken ?: "" ) );

		try {
			conversation = slack_chat.conversations.authorize( conversation_id, access_token );
			delivery_status = slack_chat.conversations.getDeliveryStatus( conversation_id );

			response[ "conversation" ] = {
				"id" : conversation.id,
				"status" : conversation.status,
				"visitorName" : conversation.visitorName,
				"visitorEmail" : conversation.visitorEmail,
				"slackChannelId" : conversation.slackChannelId,
				"slackThreadTs" : conversation.slackThreadTs,
				"slackDeliveryStatus" : delivery_status.summary,
				"deliveryCounts" : delivery_status.counts,
				"createdAt" : conversation.createdAt,
				"updatedAt" : conversation.updatedAt
			};
		} catch ( any conversation_error ) {
			writeException( conversation_error, "status.conversation" );
		}
	}

	writeJson( 200, response );
</cfscript>
