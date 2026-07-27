<cfsetting enablecfoutputonly="true" showdebugoutput="false">
<cfscript>
	/**
	* The application's single browser entry point.
	*
	* Two states. Setup, when required configuration is missing or unusable, and
	* chat, when it is not. The setup form is an ordinary HTML form posting back
	* here, so configuration and validation work with JavaScript switched off. Live
	* chat does not, for reasons that should be obvious.
	*
	* This file decides which state applies and hands off to a view. Business logic
	* belongs in services, and the views know only how to render.
	*/

	slack_chat = application.slack_chat;
	config_service = slack_chat.config_service;

	page = {
		"csrf_token" : session.csrf_token,
		"flash" : {},
		"field_errors" : {},
		"diagnostics" : {},
		"config" : config_service.getPublicConfig(),
		"missing_settings" : config_service.getMissingSettings(),
		"ready" : slack_chat.ready ?: false,
		"ready_reason" : slack_chat.ready_reason ?: "",
		"events_url" : config_service.getEventsRequestUrl(),
		"local_url" : buildLocalBaseUrl(),
		"bootstrap_error" : request.bootstrap_error ?: ""
	};

	string function buildLocalBaseUrl() {

		var scheme = ( cgi.https ?: "off" ) == "on" ? "https" : "http";
		var host = len( cgi.http_host ?: "" ) ? cgi.http_host : ( cgi.server_name & ":" & cgi.server_port );

		return scheme & "://" & host;
	}

	// ------------------------------------------------------------- form handling

	if ( ( cgi.request_method ?: "" ) == "POST" ) {

		posted_token = form.csrf_token ?: "";

		if ( !len( posted_token ) || compare( posted_token, session.csrf_token ) != 0 ) {
			session.flash = {
				"type" : "danger",
				"message" : "That form could not be verified. Reload the page and try again."
			};
			location( url = cgi.script_name, addToken = false );
		}

		action = form.action ?: "";

		if ( action == "save-config" ) {

			validation_errors = config_service.validateInput( form );

			if ( arrayLen( validation_errors ) ) {
				session.flash = {
					"type" : "danger",
					"message" : "Some values need attention before they can be saved.",
					"errors" : validation_errors
				};
			} else {
				try {
					config_service.save( form );
					session.flash = {
						"type" : "success",
						"message" : "Configuration saved. Services were rebuilt with the new values."
					};
				} catch ( any save_error ) {
					slack_chat.log.error( "setup.saveFailed", slack_chat.log.describeException( save_error ) );
					session.flash = {
						"type" : "danger",
						"message" : "The configuration could not be written: " & save_error.message
					};
				}
			}

			location( url = cgi.script_name, addToken = false );
		}

		if ( action == "test-config" ) {

			try {
				session.diagnostics = slack_chat.setup.runDiagnostics();
			} catch ( any diagnostic_error ) {
				slack_chat.log.error( "setup.diagnosticsFailed", slack_chat.log.describeException( diagnostic_error ) );
				session.flash = {
					"type" : "danger",
					"message" : "The configuration check could not be completed: " & diagnostic_error.message
				};
			}

			location( url = cgi.script_name, addToken = false );
		}

		session.flash = { "type":"warning", "message":"That action is not recognised." };
		location( url = cgi.script_name, addToken = false );
	}

	// --------------------------------------------------------------- flash pickup

	if ( structKeyExists( session, "flash" ) ) {
		page.flash = session.flash;
		structDelete( session, "flash" );
	}

	if ( structKeyExists( session, "diagnostics" ) ) {
		page.diagnostics = session.diagnostics;
		structDelete( session, "diagnostics" );
	}

	if ( structKeyExists( page.flash, "errors" ) ) {
		for ( field_error in page.flash.errors ) {
			page.field_errors[ field_error.field ] = field_error.message;
		}
	}

	show_setup = !page.ready || structKeyExists( url, "setup" );
</cfscript>

<cfoutput>
<!doctype html>
<html lang="en" data-bs-theme="light">
	<head>
		<meta charset="utf-8">
		<meta name="viewport" content="width=device-width, initial-scale=1">
		<meta name="csrf-token" content="#encodeForHTMLAttribute( page.csrf_token )#">
		<title>Slack-backed support chat</title>
		<link rel="stylesheet"
			href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/css/bootstrap.min.css"
			integrity="sha384-sRIl4kxILFvY47J16cr9ZwB07vP4J8+LH7qKQnuqkuIAvNWLzeN8tE5YBujZqJLB"
			crossorigin="anonymous">
		<link rel="stylesheet" href="/assets/css/app.css">
	</head>

	<body class="bg-body-tertiary">

		<nav class="navbar navbar-expand-lg bg-body border-bottom">
			<div class="container">
				<span class="navbar-brand mb-0 h1">Slack-backed support chat</span>
				<div class="d-flex align-items-center gap-2">
					<cfif page.ready>
						<span class="badge text-bg-success">Configured</span>
					<cfelse>
						<span class="badge text-bg-warning">Setup required</span>
					</cfif>
					<cfif page.ready>
						<a class="btn btn-sm btn-outline-secondary" href="#encodeForHTMLAttribute( cgi.script_name )#?setup=1">Settings</a>
					</cfif>
				</div>
			</div>
		</nav>

		<main class="container py-4">

			<cfif len( page.bootstrap_error )>
				<div class="alert alert-danger">
					<strong>The configuration file could not be read.</strong>
					<p class="mb-0">#encodeForHTML( page.bootstrap_error )#</p>
				</div>
			</cfif>

			<cfif structKeyExists( page.flash, "message" )>
				<div class="alert alert-#encodeForHTMLAttribute( page.flash.type )#" role="alert">
					#encodeForHTML( page.flash.message )#
					<cfif structKeyExists( page.flash, "errors" ) && arrayLen( page.flash.errors )>
						<ul class="mb-0 mt-2">
							<cfloop array="#page.flash.errors#" index="field_error">
								<li>#encodeForHTML( field_error.message )#</li>
							</cfloop>
						</ul>
					</cfif>
				</div>
			</cfif>

			<cfif show_setup>
				<cfinclude template="views/setup.cfm">
			<cfelse>
				<cfinclude template="views/chat.cfm">
			</cfif>

		</main>

		<footer class="container pb-5">
			<p class="text-body-secondary small mb-0">
				Reference implementation. The database is the system of record; Slack is a participant.
			</p>
		</footer>

		<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/js/bootstrap.bundle.min.js"
			integrity="sha384-FKyoEForCGlyvwx9Hj09JcYn3nv7wiPVlz7YYwJrWVcXK/BmnVDxM+D2scQbITxI"
			crossorigin="anonymous"></script>
		<script src="/assets/js/app.js" defer></script>

	</body>
</html>
</cfoutput>
