<cfsetting enablecfoutputonly="true" showdebugoutput="false">
<cfinclude template="response.cfm">

<cfscript>
	/**
	* POST /api/conversation.cfm
	*
	* Starts a conversation from the visitor's first message.
	*
	* The order matters and is not negotiable: the conversation and its first
	* message are committed locally, and only then is delivery to Slack attempted.
	* If Slack is unavailable the visitor still has a conversation, the message is
	* still queued, and the response says so honestly rather than pretending the
	* message evaporated.
	*/

	requireMethod( "POST" );
	requireReady();
	requireCsrfToken();

	body = readJsonBody();

	visitor_name = bodyValue( body, "visitorName" );
	visitor_email = bodyValue( body, "visitorEmail" );
	message_body = bodyValue( body, "body" );

	slack_chat = application.slack_chat;

	try {
		created = slack_chat.conversations.createConversation(
			visitor_name = visitor_name,
			visitor_email = visitor_email,
			body = message_body
		);
	} catch ( any creation_error ) {
		writeException( creation_error, "conversation.create" );
	}

	rememberConversation( created.conversation_id, created.access_token );

	// Best effort, outside the transaction. Failure here leaves a durable queue row
	// behind, which the processor will pick up again.
	try {
		slack_chat.deliveries.processPendingDeliveries( created.conversation_id );
	} catch ( any delivery_error ) {
		slack_chat.log.warn( "conversation.inlineDeliveryFailed", {
			"conversation_id" : created.conversation_id
		} );
	}

	conversation = slack_chat.conversations.getConversation( created.conversation_id );
	delivery_status = slack_chat.conversations.getDeliveryStatus( created.conversation_id );

	writeJson( 201, {
		"ok" : true,
		"conversation" : {
			"id" : conversation.id,
			"accessToken" : created.access_token,
			"status" : conversation.status,
			"visitorName" : conversation.visitorName,
			"visitorEmail" : conversation.visitorEmail,
			"slackChannelId" : conversation.slackChannelId,
			"slackThreadTs" : conversation.slackThreadTs,
			"slackDeliveryStatus" : delivery_status.summary,
			"createdAt" : conversation.createdAt
		},
		"message" : created.message
	} );
</cfscript>
