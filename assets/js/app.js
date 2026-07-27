/**
 * Browser behaviour for the support chat.
 *
 * Sending is an ordinary fetch to a JSON endpoint. Receiving is an EventSource
 * on stream/conversation.cfm. There is no polling loop in here, and there is no
 * WebSocket, because one direction of live data does not need two directions of
 * connection.
 *
 * Message bodies are inserted with textContent. Never innerHTML: the text
 * arrives from a stranger, travels through Slack, and comes back again.
 */
( function () {
	'use strict';

	var root = document.getElementById( 'chatApp' );

	if ( !root ) {
		return;
	}

	var STORAGE_KEY = 'cfmlSlackChat.conversation';

	var elements = {
		visitor_name: document.getElementById( 'visitorName' ),
		visitor_email: document.getElementById( 'visitorEmail' ),
		message_form: document.getElementById( 'messageForm' ),
		message_body: document.getElementById( 'messageBody' ),
		send_button: document.getElementById( 'sendButton' ),
		message_panel: document.getElementById( 'messagePanel' ),
		empty_state: document.getElementById( 'emptyState' ),
		chat_error: document.getElementById( 'chatError' ),
		character_count: document.getElementById( 'characterCount' ),
		connection_status: document.getElementById( 'connectionStatus' ),
		conversation_status: document.getElementById( 'conversationStatus' ),
		conversation_id: document.getElementById( 'conversationId' ),
		slack_channel_id: document.getElementById( 'slackChannelId' ),
		slack_thread_ts: document.getElementById( 'slackThreadTs' ),
		delivery_status: document.getElementById( 'deliveryStatus' ),
		queue_summary: document.getElementById( 'queueSummary' ),
		new_conversation: document.getElementById( 'newConversationButton' ),
		refresh_status: document.getElementById( 'refreshStatusButton' ),
		process_queues: document.getElementById( 'processQueuesButton' )
	};

	var state = {
		conversation_id: '',
		access_token: '',
		last_message_id: 0,
		rendered_ids: {},
		event_source: null,
		sending: false,
		max_length: parseInt( elements.message_body.getAttribute( 'maxlength' ), 10 ) || 4000
	};

	var csrf_token = ( document.querySelector( 'meta[name="csrf-token"]' ) || {} ).content || '';

	// ------------------------------------------------------------------ helpers

	function postJson( endpoint, payload ) {
		return fetch( endpoint, {
			method: 'POST',
			credentials: 'same-origin',
			headers: {
				'Content-Type': 'application/json',
				'X-CSRF-Token': csrf_token
			},
			body: JSON.stringify( payload )
		} ).then( readJsonResponse );
	}

	function getJson( endpoint ) {
		return fetch( endpoint, { credentials: 'same-origin' } ).then( readJsonResponse );
	}

	/**
	 * Turn any response into either a resolved body or a rejection carrying the
	 * server's own error message. A non-JSON body means something upstream broke
	 * before the application got involved.
	 */
	function readJsonResponse( response ) {
		return response.text().then( function ( text ) {

			var body;

			try {
				body = JSON.parse( text );
			} catch ( parse_error ) {
				throw new Error( 'The server returned a response that was not JSON (HTTP ' + response.status + ').' );
			}

			if ( !response.ok || body.ok === false ) {
				var message = ( body.error && body.error.message ) || 'The request failed.';
				var failure = new Error( message );
				failure.code = ( body.error && body.error.code ) || 'unknown';
				throw failure;
			}

			return body;
		} );
	}

	/**
	 * Errors are tagged with where they came from.
	 *
	 * Without that, the stream reconnecting a second later clears the notice
	 * saying Slack has not accepted the visitor's message — two unrelated things
	 * sharing one banner, with the less important one winning.
	 */
	function showError( message, source ) {
		elements.chat_error.textContent = message;
		elements.chat_error.setAttribute( 'data-source', source || 'general' );
		elements.chat_error.classList.remove( 'd-none' );
	}

	/** Clear everything, or only what the named source raised. */
	function clearError( source ) {

		if ( source && elements.chat_error.getAttribute( 'data-source' ) !== source ) {
			return;
		}

		elements.chat_error.textContent = '';
		elements.chat_error.removeAttribute( 'data-source' );
		elements.chat_error.classList.add( 'd-none' );
	}

	function setBadge( element, text, variant ) {
		element.textContent = text;
		element.className = 'badge text-bg-' + variant;
	}

	function setConnectionStatus( text, variant ) {
		setBadge( elements.connection_status, text, variant );
	}

	function setSending( is_sending ) {
		state.sending = is_sending;
		elements.send_button.disabled = is_sending;
		elements.send_button.textContent = is_sending ? 'Sending...' : 'Send';
	}

	function formatTime( iso_value ) {

		if ( !iso_value ) {
			return '';
		}

		var parsed = new Date( iso_value.replace( ' ', 'T' ) );

		return isNaN( parsed.getTime() ) ? '' : parsed.toLocaleTimeString();
	}

	// ---------------------------------------------------------------- rendering

	function renderMessage( message ) {

		if ( state.rendered_ids[ message.id ] ) {
			return;
		}

		state.rendered_ids[ message.id ] = true;

		if ( elements.empty_state ) {
			elements.empty_state.classList.add( 'd-none' );
		}

		var is_customer = message.senderType === 'customer';

		var row = document.createElement( 'div' );
		row.className = 'message-row ' + ( is_customer ? 'message-row-customer' : 'message-row-support' );

		var bubble = document.createElement( 'div' );
		bubble.className = 'message-bubble ' + ( is_customer ? 'message-bubble-customer' : 'message-bubble-support' );

		var meta = document.createElement( 'div' );
		meta.className = 'message-meta';
		meta.textContent = ( message.senderName || ( is_customer ? 'You' : 'Support' ) ) + ' · ' + formatTime( message.createdAt );

		var body = document.createElement( 'div' );
		body.className = 'message-body';
		// textContent, deliberately. This string came from a stranger.
		body.textContent = message.body;

		bubble.appendChild( meta );
		bubble.appendChild( body );
		row.appendChild( bubble );
		elements.message_panel.appendChild( row );

		if ( message.id > state.last_message_id ) {
			state.last_message_id = message.id;
		}

		scrollToLatest();
	}

	function scrollToLatest() {

		// Leave the panel alone if the reader has scrolled up to look at history.
		var distance_from_bottom = elements.message_panel.scrollHeight
			- elements.message_panel.scrollTop
			- elements.message_panel.clientHeight;

		if ( distance_from_bottom < 120 ) {
			elements.message_panel.scrollTop = elements.message_panel.scrollHeight;
		}
	}

	function resetMessagePanel() {

		state.rendered_ids = {};
		state.last_message_id = 0;

		Array.prototype.slice.call( elements.message_panel.querySelectorAll( '.message-row' ) )
			.forEach( function ( row ) {
				row.parentNode.removeChild( row );
			} );

		if ( elements.empty_state ) {
			elements.empty_state.classList.remove( 'd-none' );
		}
	}

	function updateConversationPanel( conversation ) {

		if ( !conversation ) {
			return;
		}

		elements.conversation_id.textContent = conversation.id || '—';
		elements.slack_channel_id.textContent = conversation.slackChannelId || 'not assigned yet';
		elements.slack_thread_ts.textContent = conversation.slackThreadTs || 'not assigned yet';
		elements.conversation_status.textContent = 'Status: ' + ( conversation.status || 'unknown' );

		if ( conversation.slackDeliveryStatus ) {
			var variants = { sent: 'success', pending: 'warning', retrying: 'warning', failed: 'danger' };
			setBadge(
				elements.delivery_status,
				conversation.slackDeliveryStatus,
				variants[ conversation.slackDeliveryStatus ] || 'secondary'
			);
		}
	}

	// ------------------------------------------------------------------ storage

	function rememberConversation() {
		try {
			window.sessionStorage.setItem( STORAGE_KEY, JSON.stringify( {
				conversation_id: state.conversation_id,
				access_token: state.access_token
			} ) );
		} catch ( storage_error ) {
			// Private browsing modes decline. The session cookie still works.
		}
	}

	function forgetConversation() {
		try {
			window.sessionStorage.removeItem( STORAGE_KEY );
		} catch ( storage_error ) {
		}
	}

	function restoreConversation() {

		try {
			var stored = window.sessionStorage.getItem( STORAGE_KEY );

			if ( !stored ) {
				return null;
			}

			var parsed = JSON.parse( stored );

			return parsed && parsed.conversation_id ? parsed : null;
		} catch ( storage_error ) {
			return null;
		}
	}

	// ------------------------------------------------------------------- stream

	function openStream() {

		closeStream();

		if ( !state.conversation_id ) {
			return;
		}

		var stream_url = '/stream/conversation.cfm'
			+ '?conversationId=' + encodeURIComponent( state.conversation_id )
			+ '&accessToken=' + encodeURIComponent( state.access_token )
			+ '&lastMessageId=' + encodeURIComponent( state.last_message_id );

		setConnectionStatus( 'Connecting', 'secondary' );

		var source = new EventSource( stream_url );
		state.event_source = source;

		source.addEventListener( 'ready', function () {
			setConnectionStatus( 'Live', 'success' );
			clearError( 'stream' );
		} );

		source.addEventListener( 'message', function ( event ) {
			try {
				renderMessage( JSON.parse( event.data ) );
			} catch ( parse_error ) {
				// A malformed frame is not worth tearing the stream down for.
			}
		} );

		source.addEventListener( 'reconnect', function () {
			// The server closed on schedule. The browser reopens on its own and
			// replays Last-Event-ID, so nothing is lost and nothing repeats.
			setConnectionStatus( 'Reconnecting', 'secondary' );
		} );

		source.addEventListener( 'stream_error', function () {
			showError( 'The message stream reported a problem. It will try again shortly.', 'stream' );
		} );

		source.onopen = function () {
			setConnectionStatus( 'Live', 'success' );
		};

		source.onerror = function () {

			if ( source.readyState === EventSource.CLOSED ) {
				setConnectionStatus( 'Disconnected', 'danger' );
				showError( 'The live connection closed and will not retry. Reload the page to reconnect.', 'stream' );
				return;
			}

			setConnectionStatus( 'Reconnecting', 'warning' );
		};
	}

	function closeStream() {

		if ( state.event_source ) {
			state.event_source.close();
			state.event_source = null;
		}

		setConnectionStatus( 'Disconnected', 'secondary' );
	}

	// ------------------------------------------------------------------ actions

	function startConversation( body ) {

		return postJson( '/api/conversation.cfm', {
			visitorName: elements.visitor_name.value,
			visitorEmail: elements.visitor_email.value,
			body: body
		} ).then( function ( response ) {

			state.conversation_id = response.conversation.id;
			state.access_token = response.conversation.accessToken;

			rememberConversation();
			updateConversationPanel( response.conversation );
			renderMessage( response.message );

			elements.visitor_name.readOnly = true;
			elements.visitor_email.readOnly = true;

			openStream();

			if ( response.conversation.slackDeliveryStatus !== 'sent' ) {
				showError( 'Your message was saved, but Slack has not accepted it yet. It stays queued and will be retried.', 'delivery' );
			}
		} );
	}

	function sendMessage( body ) {

		return postJson( '/api/message.cfm', {
			conversationId: state.conversation_id,
			accessToken: state.access_token,
			body: body
		} ).then( function ( response ) {

			updateConversationPanel( response.conversation );
			renderMessage( response.message );

			if ( response.conversation.slackDeliveryStatus !== 'sent' ) {
				showError( 'Your message was saved, but Slack has not accepted it yet. It stays queued and will be retried.', 'delivery' );
			}
		} );
	}

	function loadHistory( conversation_id, access_token ) {

		var history_url = '/api/message.cfm'
			+ '?conversationId=' + encodeURIComponent( conversation_id )
			+ '&accessToken=' + encodeURIComponent( access_token )
			+ '&after=0';

		return getJson( history_url ).then( function ( response ) {

			state.conversation_id = conversation_id;
			state.access_token = access_token;

			updateConversationPanel( response.conversation );
			response.messages.forEach( renderMessage );

			elements.visitor_name.readOnly = true;
			elements.visitor_email.readOnly = true;

			openStream();
			refreshStatus();
		} );
	}

	function refreshStatus() {

		var status_url = '/api/status.cfm';

		if ( state.conversation_id ) {
			status_url += '?conversationId=' + encodeURIComponent( state.conversation_id )
				+ '&accessToken=' + encodeURIComponent( state.access_token );
		}

		return getJson( status_url ).then( function ( response ) {

			if ( response.conversation ) {
				updateConversationPanel( response.conversation );

				if ( elements.visitor_name.value === '' ) {
					elements.visitor_name.value = response.conversation.visitorName || '';
				}
				if ( elements.visitor_email.value === '' ) {
					elements.visitor_email.value = response.conversation.visitorEmail || '';
				}
			}

			if ( elements.queue_summary && response.status && response.status.eventQueue ) {
				var queue = response.status.eventQueue;
				elements.queue_summary.textContent =
					'Slack event inbox: ' + queue.pending + ' pending, '
					+ queue.processed + ' processed, '
					+ queue.ignored + ' ignored, '
					+ queue.failed + ' failed.';
			}
		} ).catch( function ( failure ) {
			showError( failure.message );
		} );
	}

	function startNewConversation() {

		closeStream();
		forgetConversation();
		resetMessagePanel();
		clearError();

		state.conversation_id = '';
		state.access_token = '';

		elements.visitor_name.readOnly = false;
		elements.visitor_email.readOnly = false;
		elements.conversation_id.textContent = '—';
		elements.slack_channel_id.textContent = '—';
		elements.slack_thread_ts.textContent = '—';
		elements.conversation_status.textContent = 'No conversation started';
		setBadge( elements.delivery_status, 'idle', 'secondary' );
		elements.message_body.focus();
	}

	// ------------------------------------------------------------------- events

	elements.message_form.addEventListener( 'submit', function ( event ) {

		event.preventDefault();

		if ( state.sending ) {
			return;
		}

		var body = elements.message_body.value.trim();

		if ( !body ) {
			showError( 'Enter a message before pressing Send.' );
			return;
		}

		clearError();
		setSending( true );

		var action = state.conversation_id ? sendMessage( body ) : startConversation( body );

		action.then( function () {
			elements.message_body.value = '';
			updateCharacterCount();
		} ).catch( function ( failure ) {
			showError( failure.message );
		} ).then( function () {
			setSending( false );
			elements.message_body.focus();
		} );
	} );

	elements.message_body.addEventListener( 'keydown', function ( event ) {
		if ( event.key === 'Enter' && !event.shiftKey ) {
			event.preventDefault();
			elements.message_form.dispatchEvent( new Event( 'submit', { cancelable: true } ) );
		}
	} );

	elements.message_body.addEventListener( 'input', updateCharacterCount );

	function updateCharacterCount() {
		elements.character_count.textContent = elements.message_body.value.length + ' / ' + state.max_length;
	}

	elements.new_conversation.addEventListener( 'click', startNewConversation );

	if ( elements.refresh_status ) {
		elements.refresh_status.addEventListener( 'click', function () {
			refreshStatus();
		} );
	}

	if ( elements.process_queues ) {
		elements.process_queues.addEventListener( 'click', function () {

			elements.process_queues.disabled = true;

			postJson( '/api/status.cfm', { action: 'process-queues' } )
				.then( refreshStatus )
				.catch( function ( failure ) {
					showError( failure.message );
				} )
				.then( function () {
					elements.process_queues.disabled = false;
				} );
		} );
	}

	window.addEventListener( 'beforeunload', closeStream );

	// -------------------------------------------------------------------- start

	elements.visitor_name.value = root.getAttribute( 'data-default-name' ) || '';
	elements.visitor_email.value = root.getAttribute( 'data-default-email' ) || '';
	updateCharacterCount();

	var restored = restoreConversation();

	if ( restored ) {
		loadHistory( restored.conversation_id, restored.access_token ).catch( function () {
			// The conversation is gone, or the token no longer matches. Start clean
			// rather than leaving the page pointed at something that is not there.
			forgetConversation();
			startNewConversation();
		} );
	} else {
		refreshStatus();
	}

}() );
