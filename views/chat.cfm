<cfoutput>
<div class="row g-4" id="chatApp"
	data-default-name="#encodeForHTMLAttribute( page.config.visitor.default_name )#"
	data-default-email="#encodeForHTMLAttribute( page.config.visitor.default_email )#"
	data-dev-tools="#encodeForHTMLAttribute( page.config.app.dev_tools )#">

	<div class="col-lg-8">
		<div class="card shadow-sm chat-card">

			<div class="card-header d-flex flex-wrap justify-content-between align-items-center gap-2">
				<div>
					<h2 class="h6 mb-0">Test conversation</h2>
					<span class="small text-body-secondary" id="conversationStatus">No conversation started</span>
				</div>
				<div class="d-flex align-items-center gap-2">
					<span class="badge text-bg-secondary" id="connectionStatus">Disconnected</span>
					<button type="button" class="btn btn-sm btn-outline-secondary" id="newConversationButton">New conversation</button>
				</div>
			</div>

			<div class="card-body">

				<div class="row g-2 mb-3">
					<div class="col-sm-6">
						<label class="form-label small mb-1" for="visitorName">Your name</label>
						<input type="text" class="form-control form-control-sm" id="visitorName" maxlength="120" autocomplete="name">
					</div>
					<div class="col-sm-6">
						<label class="form-label small mb-1" for="visitorEmail">Your email</label>
						<input type="email" class="form-control form-control-sm" id="visitorEmail" maxlength="255" autocomplete="email">
					</div>
				</div>

				<div class="alert alert-danger d-none" id="chatError" role="alert"></div>

				<div class="message-panel border rounded p-3 mb-3" id="messagePanel" aria-live="polite">
					<div class="text-center text-body-secondary py-5" id="emptyState">
						<p class="mb-1">Nothing here yet.</p>
						<p class="small mb-0">
							Send a message and it becomes a new Slack thread. Reply in that thread and it comes back here,
							without you touching the refresh button.
						</p>
					</div>
				</div>

				<form id="messageForm" autocomplete="off">
					<div class="input-group">
						<textarea class="form-control" id="messageBody" rows="2" maxlength="#encodeForHTMLAttribute( page.config.app.max_message_length )#"
							placeholder="Type a message, then press Send" aria-label="Message"></textarea>
						<button class="btn btn-primary px-4" type="submit" id="sendButton">Send</button>
					</div>
					<div class="form-text d-flex justify-content-between">
						<span>Enter sends. Shift and Enter starts a new line.</span>
						<span id="characterCount">0 / #encodeForHTMLAttribute( page.config.app.max_message_length )#</span>
					</div>
				</form>

			</div>
		</div>
	</div>

	<div class="col-lg-4">

		<div class="card shadow-sm mb-4">
			<div class="card-header"><h2 class="h6 mb-0">Delivery</h2></div>
			<div class="card-body">
				<dl class="row mb-0 small">
					<dt class="col-5">To Slack</dt>
					<dd class="col-7"><span class="badge text-bg-secondary" id="deliveryStatus">idle</span></dd>

					<dt class="col-5">Conversation</dt>
					<dd class="col-7 text-break"><code id="conversationId">&mdash;</code></dd>

					<dt class="col-5">Slack channel</dt>
					<dd class="col-7 text-break"><code id="slackChannelId">&mdash;</code></dd>

					<dt class="col-5">Thread ts</dt>
					<dd class="col-7 text-break"><code id="slackThreadTs">&mdash;</code></dd>
				</dl>
			</div>
		</div>

		<div class="accordion shadow-sm" id="diagnosticsAccordion">
			<div class="accordion-item">
				<h2 class="accordion-header">
					<button class="accordion-button collapsed" type="button" data-bs-toggle="collapse" data-bs-target="##diagnosticsPanel">
						Diagnostics
					</button>
				</h2>
				<div id="diagnosticsPanel" class="accordion-collapse collapse" data-bs-parent="##diagnosticsAccordion">
					<div class="accordion-body small">
						<dl class="row mb-3">
							<dt class="col-6">Events Request URL</dt>
							<dd class="col-6 text-break">
								<cfif len( page.events_url )><code>#encodeForHTML( page.events_url )#</code><cfelse><span class="text-body-secondary">not set</span></cfif>
							</dd>
							<dt class="col-6">Bot user</dt>
							<dd class="col-6 text-break"><code>#encodeForHTML( len( page.config.slack.bot_user_id ) ? page.config.slack.bot_user_id : "unknown" )#</code></dd>
							<dt class="col-6">Channel</dt>
							<dd class="col-6 text-break"><code>#encodeForHTML( page.config.slack.channel_id )#</code></dd>
							<dt class="col-6">Auto-drain queues</dt>
							<dd class="col-6">#encodeForHTML( page.config.app.auto_process_events ? "on" : "off" )#</dd>
						</dl>

						<div id="queueSummary" class="text-body-secondary mb-3">Queue state appears here after a refresh.</div>

						<div class="d-flex gap-2 flex-wrap">
							<button type="button" class="btn btn-sm btn-outline-secondary" id="refreshStatusButton">Refresh status</button>
							<cfif page.config.app.dev_tools>
								<button type="button" class="btn btn-sm btn-outline-secondary" id="processQueuesButton">Process queues now</button>
							</cfif>
						</div>

						<p class="mt-3 mb-0 text-body-secondary">
							The supported worker is the CommandBox task. The button above is a local development
							convenience and refuses anything that is not a loopback request.
						</p>
					</div>
				</div>
			</div>
		</div>

	</div>
</div>
</cfoutput>
