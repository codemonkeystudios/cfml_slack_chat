<cfsetting showdebugoutput="false" enablecfoutputonly="true">
<cfscript>
/**
 * TestBox runner.
 *
 * Browser : http://127.0.0.1:8080/tests/runner.cfm
 * CLI : box testbox run
 *
 * Only files ending in _test.cfc are collected, so the base spec and the stubs
 * beside them are not mistaken for suites.
 */

param name="url.reporter" default="simple";
param name="url.directory" default="tests";

test_box = new testbox.system.TestBox(
	directory = {
		mapping : url.directory,
		recurse : true,
		filter : function( required string path ) {
			return right( arguments.path, 9 ) == "_test.cfc";
		}
	}
);

writeOutput( test_box.run( reporter = url.reporter ) );
</cfscript>
