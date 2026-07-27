# Tests

TestBox specs for the Slack-backed support chat.

## Running them

Install the development dependency once:

```bash
box install
```

Then either run from the command line:

```bash
box testbox run
```

or, with the server running, open the runner in a browser:

```
http://127.0.0.1:8080/tests/runner.cfm
```

The runner accepts the usual TestBox parameters:

```
http://127.0.0.1:8080/tests/runner.cfm?reporter=text
http://127.0.0.1:8080/tests/runner.cfm?directory=tests.unit
```

Only files ending in `_test.cfc` are collected, so the base spec and the test
doubles beside them are not mistaken for suites.

## Layout

```
tests/
├── Application.cfc          Test application: mappings and the datasource
├── runner.cfm               TestBox runner
├── support/
│   ├── null_log_service.cfc   Keeps log entries in memory instead of on disk
│   └── stub_slack_service.cfc Extends the real Slack service; replaces only postMessage()
├── unit/                    No database, no network
└── integration/             Needs a configured database
```

## Unit specs

These need nothing but the CFML engine.

| Spec | Covers |
| --- | --- |
| `slack_signature_test` | Signature generation against a fixed vector; valid, invalid, missing, non-numeric, stale and future timestamps; modified bodies; wrong secret; constant-time comparison |
| `event_filter_test` | Which Slack events become support replies and which are dropped, using the event shapes Slack actually sends |
| `event_stream_test` | SSE framing, single-line JSON, frame termination, cursor resolution |
| `config_service_test` | Precedence, secret redaction, saving without clobbering stored secrets, setup validation, datasource building |
| `identifier_test` | UUIDv7 version and variant nibbles, ordering, uniqueness; access token entropy and hashing |
| `api_error_test` | Exception to status code mapping, and what must not appear in a response |

The signature vector in `slack_signature_test` was cross-checked against an
independent HMAC-SHA256 implementation outside CFML. A passing suite means this
code agrees with the algorithm Slack specifies, not merely with itself.

## Integration specs

These use the datasource from your configuration, so they run against whichever
of PostgreSQL, MySQL or SQL Server you have set up. When no usable database is
available they skip with a stated reason rather than failing — a missing test
database is a missing test database, not a broken application.

| Spec | Covers |
| --- | --- |
| `conversation_service_test` | Persisting conversations and messages before Slack is involved; access token authorization; the message cursor; support message idempotency; thread lookup |
| `slack_delivery_test` | The first message opening a thread; later messages joining it; never a second root message; failure preserving the customer's message; permanent versus transient errors; claim safety |
| `slack_event_test` | Event queueing idempotency; retry metadata; raw body preservation; processing, filtering and mapping; the full round trip |

Slack is stubbed at the HTTP boundary only. `stub_slack_service` extends the real
component and overrides `postMessage()`, so message formatting, escaping, error
classification and signature verification are the genuine implementations.

Every spec cleans up what it created, in foreign-key order.

## What the suite deliberately does not do

- **Drive a real Slack workspace.** That needs credentials, a network and a
  channel that fills with test messages. Use the walkthrough in the main README
  for that.
- **Open a real SSE connection.** Streaming is a request-level concern; the
  service beneath it — framing and the cursor read — is tested directly.
- **Test Adobe ColdFusion.** The code is engine-neutral and the two places the
  engines differ are isolated and commented, but the suite has only been executed
  on Lucee.

## Last recorded run

183 specs pass, 1 skipped, against PostgreSQL 16, MySQL 8 and SQL Server 2022 on
Lucee 6.2.7.16 under CommandBox 6.3.2.

The single skip is the spec that reports why the integration suites were skipped.
It correctly skips itself when the database *is* available, which is the point of
it.
