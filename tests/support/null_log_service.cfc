/**
 * A log service that keeps entries in memory instead of writing them to disk.
 *
 * Specs can assert on what was logged, and a test run does not leave a trail
 * through logs/slack-chat.log.
 */
component extends="slackchat.services.log_service" accessors="false" {

	public null_log_service function init() {

		super.init( log_directory = getTempDirectory() & "cfml-slack-chat-tests", log_message_bodies = false );

		variables.entries = [];

		return this;
	}

	public array function getEntries() {
		return variables.entries;
	}

	public void function clearEntries() {
		variables.entries = [];
	}

	/** Entries whose category matches, for assertions. */
	public array function entriesFor( required string category ) {

		var matches = [];

		for ( var entry in variables.entries ) {
			if ( entry.category == arguments.category ) {
				arrayAppend( matches, entry );
			}
		}

		return matches;
	}

	private void function writeEntry( required string level, required string category, required struct fields ) {
		arrayAppend( variables.entries, {
			"level" : arguments.level,
			"category" : arguments.category,
			"fields" : arguments.fields
		} );
	}

}
