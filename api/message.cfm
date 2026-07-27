<cfsetting enablecfoutputonly="true" showdebugoutput="false">
<cfinclude template="response.cfm">
<cfscript>
	/**
	* /api/message.cfm
	*
	* POST add another customer message to an existing conversation
	* GET read message history after a cursor
	*
	* Both require the conversation's access token. Neither creates a new Slack root
	* message: later messages always go into the thread the conversation already
	* owns.
	*/

	requireReady();

	slack_chat = application.slack_chat;
	request_method = cgi.request_method ?: "";

	if ( request_method == "GET" ) {

		conversation_id = trim( url.conversationId ?: "" );
		access_token = resolveAccessToken( conversation_id, trim( url.accessToken ?: "" ) );
		after_message_id = val( url.after ?: 0 );

		try {
			conversation = slack_chat.conversations.authorize( conversation_id, access_token );
			messages = slack_chat.conversations.getMessagesAfter( conversation_id, after_message_id );
		} catch ( any history_error ) {
			writeException( history_error, "message.history" );
		}

		writeJson( 200, {
			"ok" : true,
			"conversation" : {
				"id" : conversation.id,
				"status" : conversation.status,
				"slackChannelId" : conversation.slackChannelId,
				"slackThreadTs" : conversation.slackThreadTs
			},
			"messages" : messages
		} );
	}

	requireMethod( "POST" );
	requireCsrfToken();

	body = readJsonBody();

	conversation_id = bodyValue( body, "conversationId" );
	access_token = resolveAccessToken( conversation_id, bodyValue( body, "accessToken" ) );
	message_body = bodyValue( body, "body" );

	try {
		added = slack_chat.conversations.addCustomerMessage(
			conversation_id = conversation_id,
			access_token = access_token,
			body = message_body
		);
	} catch ( any message_error ) {
		writeException( message_error, "message.create" );
	}

	// Keep the session's copy of the token fresh for reconnections.
	rememberConversation( conversation_id, access_token );

	try {
		slack_chat.deliveries.processPendingDeliveries( conversation_id );
	} catch ( any delivery_error ) {
		slack_chat.log.warn( "message.inlineDeliveryFailed", { "conversation_id":conversation_id } );
	}

	conversation = slack_chat.conversations.getConversation( conversation_id );
	delivery_status = slack_chat.conversations.getDeliveryStatus( conversation_id );

	writeJson( 201, {
		"ok" : true,
		"conversation" : {
			"id" : conversation.id,
			"status" : conversation.status,
			"slackChannelId" : conversation.slackChannelId,
			"slackThreadTs" : conversation.slackThreadTs,
			"slackDeliveryStatus" : delivery_status.summary
		},
		"message" : added.message
	} );
</cfscript>
