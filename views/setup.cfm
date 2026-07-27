<cfoutput>
<cfscript>
	// Presentation helpers only. Anything that decides something lives in a service.
	config_values = page.config;
	locked_paths = config_values.meta.environment_locked;

	boolean function isLocked( required string path ) {
		return arrayFindNoCase( locked_paths, arguments.path ) > 0;
	}

	string function fieldError( required string field ) {
		return structKeyExists( page.field_errors, arguments.field ) ? page.field_errors[ arguments.field ] : "";
	}

	string function invalidClass( required string field ) {
		return len( fieldError( arguments.field ) ) ? " is-invalid" : "";
	}

	string function statusBadge( required string status ) {
		var classes = { "pass":"text-bg-success", "fail":"text-bg-danger", "warn":"text-bg-warning", "skip":"text-bg-secondary" };
		return classes[ arguments.status ] ?: "text-bg-secondary";
	}
</cfscript>

<div class="row g-4">
	<div class="col-lg-7">

		<div class="card shadow-sm">
			<div class="card-header">
				<h2 class="h5 mb-0">Configuration</h2>
			</div>
			<div class="card-body">

				<cfif arrayLen( page.missing_settings )>
					<div class="alert alert-warning">
						<p class="mb-2">The application still needs a few things before it can carry a conversation:</p>
						<ul class="mb-0">
							<cfloop array="#page.missing_settings#" index="missing_setting">
								<li><strong>#encodeForHTML( missing_setting.label )#</strong> &mdash; #encodeForHTML( missing_setting.reason )#</li>
							</cfloop>
						</ul>
					</div>
				<cfelseif !page.ready>
					<div class="alert alert-danger">
						<p class="mb-0">Everything is filled in, but the application is not usable yet: #encodeForHTML( page.ready_reason )#</p>
					</div>
				</cfif>

				<cfif arrayLen( locked_paths )>
					<p class="small text-body-secondary">
						Some values come from environment variables. Those fields are read-only here, because an
						environment that configures itself should not be overridden by a browser tab.
					</p>
				</cfif>

				<form method="post" action="#encodeForHTMLAttribute( cgi.script_name )#" novalidate>
					<input type="hidden" name="csrf_token" value="#encodeForHTMLAttribute( page.csrf_token )#">
					<input type="hidden" name="action" value="save-config">

					<h3 class="h6 text-uppercase text-body-secondary mt-2">Slack</h3>

					<div class="mb-3">
						<label class="form-label" for="slack_bot_token">Bot User OAuth Token</label>
						<input type="password" class="form-control#invalidClass( 'slack_bot_token' )#" id="slack_bot_token" name="slack_bot_token"
							autocomplete="off" placeholder="xoxb-..."
							<cfif isLocked( "slack.bot_token" )>disabled</cfif>>
						<div class="form-text">
							<cfif config_values.slack.bot_token_is_set>
								<span class="text-success">A token is stored.</span> Leave this blank to keep it.
							<cfelse>
								Slack app &rarr; OAuth &amp; Permissions &rarr; Bot User OAuth Token.
							</cfif>
							<cfif isLocked( "slack.bot_token" )><span class="badge text-bg-secondary">from SLACK_BOT_TOKEN</span></cfif>
						</div>
						<cfif len( fieldError( "slack_bot_token" ) )><div class="invalid-feedback d-block">#encodeForHTML( fieldError( "slack_bot_token" ) )#</div></cfif>
					</div>

					<div class="mb-3">
						<label class="form-label" for="slack_signing_secret">Signing Secret</label>
						<input type="password" class="form-control#invalidClass( 'slack_signing_secret' )#" id="slack_signing_secret" name="slack_signing_secret"
							autocomplete="off"
							<cfif isLocked( "slack.signing_secret" )>disabled</cfif>>
						<div class="form-text">
							<cfif config_values.slack.signing_secret_is_set>
								<span class="text-success">A signing secret is stored.</span> Leave this blank to keep it.
							<cfelse>
								Slack app &rarr; Basic Information &rarr; App Credentials &rarr; Signing Secret.
							</cfif>
							<cfif isLocked( "slack.signing_secret" )><span class="badge text-bg-secondary">from SLACK_SIGNING_SECRET</span></cfif>
						</div>
						<cfif len( fieldError( "slack_signing_secret" ) )><div class="invalid-feedback d-block">#encodeForHTML( fieldError( "slack_signing_secret" ) )#</div></cfif>
					</div>

					<div class="mb-3">
						<label class="form-label" for="slack_channel_id">Channel ID</label>
						<input type="text" class="form-control#invalidClass( 'slack_channel_id' )#" id="slack_channel_id" name="slack_channel_id"
							value="#encodeForHTMLAttribute( config_values.slack.channel_id )#" placeholder="C0123456789"
							<cfif isLocked( "slack.channel_id" )>readonly</cfif>>
						<div class="form-text">
							Open the channel in Slack, choose View channel details, and copy the ID at the bottom of the panel.
							Use the ID, not the name. Computers remain stubbornly unimpressed by vibes.
						</div>
						<cfif len( fieldError( "slack_channel_id" ) )><div class="invalid-feedback d-block">#encodeForHTML( fieldError( "slack_channel_id" ) )#</div></cfif>
					</div>

					<div class="row">
						<div class="col-sm-6 mb-3">
							<label class="form-label" for="slack_app_id">App ID <span class="text-body-secondary">(optional)</span></label>
							<input type="text" class="form-control" id="slack_app_id" name="slack_app_id"
								value="#encodeForHTMLAttribute( config_values.slack.app_id )#" placeholder="A0123456789"
								<cfif isLocked( "slack.app_id" )>readonly</cfif>>
							<div class="form-text">Set this and inbound events from any other app are rejected.</div>
						</div>
						<div class="col-sm-6 mb-3">
							<label class="form-label" for="slack_team_id">Workspace ID <span class="text-body-secondary">(optional)</span></label>
							<input type="text" class="form-control" id="slack_team_id" name="slack_team_id"
								value="#encodeForHTMLAttribute( config_values.slack.team_id )#" placeholder="T0123456789"
								<cfif isLocked( "slack.team_id" )>readonly</cfif>>
							<div class="form-text">Filled in automatically when the configuration check runs.</div>
						</div>
					</div>

					<hr class="my-4">
					<h3 class="h6 text-uppercase text-body-secondary">Database</h3>

					<div class="mb-3">
						<label class="form-label d-block">How should the application connect?</label>
						<div class="form-check">
							<input class="form-check-input" type="radio" name="database_mode" id="database_mode_application"
								value="application" <cfif config_values.database.mode eq "application">checked</cfif>>
							<label class="form-check-label" for="database_mode_application">
								Application-managed &mdash; enter the connection details below and Application.cfc defines the datasource.
							</label>
						</div>
						<div class="form-check">
							<input class="form-check-input" type="radio" name="database_mode" id="database_mode_existing"
								value="existing" <cfif config_values.database.mode eq "existing">checked</cfif>>
							<label class="form-check-label" for="database_mode_existing">
								Existing datasource &mdash; use one already defined in the CFML administrator.
							</label>
						</div>
					</div>

					<div class="row">
						<div class="col-sm-6 mb-3">
							<label class="form-label" for="database_type">Database type</label>
							<select class="form-select#invalidClass( 'database_type' )#" id="database_type" name="database_type"
								<cfif isLocked( "database.type" )>disabled</cfif>>
								<option value="postgresql" <cfif config_values.database.type eq "postgresql">selected</cfif>>PostgreSQL</option>
								<option value="mysql" <cfif config_values.database.type eq "mysql">selected</cfif>>MySQL</option>
								<option value="sqlserver" <cfif config_values.database.type eq "sqlserver">selected</cfif>>SQL Server</option>
							</select>
							<div class="form-text">Required in both modes: it selects the SQL dialect.</div>
						</div>
						<div class="col-sm-6 mb-3">
							<label class="form-label" for="database_datasource">Existing datasource name</label>
							<input type="text" class="form-control#invalidClass( 'database_datasource' )#" id="database_datasource" name="database_datasource"
								value="#encodeForHTMLAttribute( config_values.database.datasource )#"
								<cfif isLocked( "database.datasource" )>readonly</cfif>>
							<div class="form-text">Only used in existing-datasource mode.</div>
						</div>
					</div>

					<div class="row">
						<div class="col-sm-8 mb-3">
							<label class="form-label" for="database_host">Host</label>
							<input type="text" class="form-control" id="database_host" name="database_host"
								value="#encodeForHTMLAttribute( config_values.database.host )#"
								<cfif isLocked( "database.host" )>readonly</cfif>>
						</div>
						<div class="col-sm-4 mb-3">
							<label class="form-label" for="database_port">Port</label>
							<input type="text" class="form-control#invalidClass( 'database_port' )#" id="database_port" name="database_port"
								value="#encodeForHTMLAttribute( config_values.database.port )#"
								<cfif isLocked( "database.port" )>readonly</cfif>>
							<cfif len( fieldError( "database_port" ) )><div class="invalid-feedback d-block">#encodeForHTML( fieldError( "database_port" ) )#</div></cfif>
						</div>
					</div>

					<div class="row">
						<div class="col-sm-4 mb-3">
							<label class="form-label" for="database_database">Database name</label>
							<input type="text" class="form-control" id="database_database" name="database_database"
								value="#encodeForHTMLAttribute( config_values.database.database )#"
								<cfif isLocked( "database.database" )>readonly</cfif>>
						</div>
						<div class="col-sm-4 mb-3">
							<label class="form-label" for="database_username">Username</label>
							<input type="text" class="form-control" id="database_username" name="database_username"
								value="#encodeForHTMLAttribute( config_values.database.username )#" autocomplete="off"
								<cfif isLocked( "database.username" )>readonly</cfif>>
						</div>
						<div class="col-sm-4 mb-3">
							<label class="form-label" for="database_password">Password</label>
							<input type="password" class="form-control" id="database_password" name="database_password" autocomplete="off"
								<cfif isLocked( "database.password" )>disabled</cfif>>
							<div class="form-text">
								<cfif config_values.database.password_is_set>Stored. Leave blank to keep it.<cfelse>Blank if the database has no password.</cfif>
							</div>
						</div>
					</div>

					<hr class="my-4">
					<h3 class="h6 text-uppercase text-body-secondary">Public URL</h3>

					<div class="mb-3">
						<label class="form-label" for="app_public_base_url">Public base URL</label>
						<input type="url" class="form-control#invalidClass( 'app_public_base_url' )#" id="app_public_base_url" name="app_public_base_url"
							value="#encodeForHTMLAttribute( config_values.app.public_base_url )#" placeholder="https://something.trycloudflare.com"
							<cfif isLocked( "app.public_base_url" )>readonly</cfif>>
						<div class="form-text">
							The address of your HTTPS tunnel. Slack needs a public HTTPS URL;
							<code>localhost</code> is extremely meaningful to your laptop and to nobody else.
						</div>
						<cfif len( fieldError( "app_public_base_url" ) )><div class="invalid-feedback d-block">#encodeForHTML( fieldError( "app_public_base_url" ) )#</div></cfif>
					</div>

					<div class="form-check mb-3">
						<input class="form-check-input" type="checkbox" value="true" id="app_allow_insecure_public_url" name="app_allow_insecure_public_url"
							<cfif config_values.app.allow_insecure_public_url>checked</cfif>>
						<label class="form-check-label" for="app_allow_insecure_public_url">
							Local-only mode: allow a non-HTTPS base URL
						</label>
						<div class="form-text">For testing outbound posting without Slack callbacks. Replies will not come back.</div>
					</div>

					<hr class="my-4">
					<h3 class="h6 text-uppercase text-body-secondary">Test visitor defaults</h3>

					<div class="row">
						<div class="col-sm-6 mb-3">
							<label class="form-label" for="visitor_default_name">Visitor name</label>
							<input type="text" class="form-control" id="visitor_default_name" name="visitor_default_name"
								value="#encodeForHTMLAttribute( config_values.visitor.default_name )#">
						</div>
						<div class="col-sm-6 mb-3">
							<label class="form-label" for="visitor_default_email">Visitor email</label>
							<input type="email" class="form-control#invalidClass( 'visitor_default_email' )#" id="visitor_default_email" name="visitor_default_email"
								value="#encodeForHTMLAttribute( config_values.visitor.default_email )#">
							<cfif len( fieldError( "visitor_default_email" ) )><div class="invalid-feedback d-block">#encodeForHTML( fieldError( "visitor_default_email" ) )#</div></cfif>
						</div>
					</div>

					<div class="d-flex gap-2">
						<button type="submit" class="btn btn-primary">Save configuration</button>
						<cfif page.ready>
							<a class="btn btn-outline-secondary" href="#encodeForHTMLAttribute( cgi.script_name )#">Back to chat</a>
						</cfif>
					</div>
				</form>

			</div>
		</div>
	</div>

	<div class="col-lg-5">

		<div class="card shadow-sm mb-4">
			<div class="card-header d-flex justify-content-between align-items-center">
				<h2 class="h6 mb-0">Configuration check</h2>
				<form method="post" action="#encodeForHTMLAttribute( cgi.script_name )#" class="m-0">
					<input type="hidden" name="csrf_token" value="#encodeForHTMLAttribute( page.csrf_token )#">
					<input type="hidden" name="action" value="test-config">
					<button type="submit" class="btn btn-sm btn-outline-primary">Test configuration</button>
				</form>
			</div>
			<div class="card-body">
				<cfif structKeyExists( page.diagnostics, "checks" )>
					<ul class="list-group list-group-flush">
						<cfloop array="#page.diagnostics.checks#" index="diagnostic_check">
							<li class="list-group-item px-0">
								<div class="d-flex justify-content-between align-items-start gap-2">
									<strong>#encodeForHTML( diagnostic_check.label )#</strong>
									<span class="badge #statusBadge( diagnostic_check.status )#">#encodeForHTML( diagnostic_check.status )#</span>
								</div>
								<div class="small text-body-secondary mt-1">#encodeForHTML( diagnostic_check.message )#</div>
							</li>
						</cfloop>
					</ul>
				<cfelse>
					<p class="text-body-secondary mb-0">
						Nothing checked yet. Press Test configuration and the application will try the datasource,
						the schema, the Slack token and the channel. Nothing is posted into your channel to do it.
					</p>
				</cfif>
			</div>
		</div>

		<div class="card shadow-sm mb-4">
			<div class="card-header"><h2 class="h6 mb-0">URLs</h2></div>
			<div class="card-body">
				<dl class="mb-0 small">
					<dt>Local browser URL</dt>
					<dd class="text-break"><code>#encodeForHTML( page.local_url )#/</code></dd>

					<dt class="mt-3">Slack Events Request URL</dt>
					<dd class="text-break mb-0">
						<cfif len( page.events_url )>
							<code>#encodeForHTML( page.events_url )#</code>
							<div class="text-body-secondary mt-1">Paste this into Event Subscriptions in your Slack app.</div>
						<cfelse>
							<span class="text-body-secondary">Set a public base URL and this appears here, ready to copy.</span>
						</cfif>
					</dd>
				</dl>
			</div>
		</div>

		<div class="card shadow-sm">
			<div class="card-header"><h2 class="h6 mb-0">Where configuration lives</h2></div>
			<div class="card-body small">
				<p>Values are resolved in this order:</p>
				<ol class="mb-3">
					<li>Environment variables</li>
					<li><code class="text-break">#encodeForHTML( config_values.meta.config_file )#</code></li>
					<li>Built-in defaults</li>
				</ol>
				<p class="mb-0 text-body-secondary">
					That file is excluded by <code>.gitignore</code> and written with owner-only permissions where the
					operating system allows it. Do not commit your bot token. Git has an excellent memory and very poor judgement.
				</p>
			</div>
		</div>

	</div>
</div>
</cfoutput>
