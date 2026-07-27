# Slack-backed support chat, in ColdFusion

A complete, runnable reference application. A visitor types into a web page, the
message becomes a Slack thread, support replies inside that thread, and the reply
appears back in the visitor's browser over Server-Sent Events.

No admin console. No WebSockets. No message broker. Slack is the operator
interface; the database is the system of record.

---

## Table of contents

1. [What this demonstrates](#what-this-demonstrates)
2. [Architecture](#architecture)
3. [Message flow](#message-flow)
4. [Requirements](#requirements)
5. [Quick start](#quick-start)
6. [Database setup](#database-setup)
7. [CommandBox setup](#commandbox-setup)
8. [Application configuration](#application-configuration)
9. [Creating the Slack app](#creating-the-slack-app)
10. [Required Slack scopes](#required-slack-scopes)
11. [Installing the app and inviting the bot](#installing-the-app-and-inviting-the-bot)
12. [Finding the channel ID](#finding-the-channel-id)
13. [Starting a public HTTPS tunnel](#starting-a-public-https-tunnel)
14. [Configuring the Events API](#configuring-the-events-api)
15. [Testing the complete flow](#testing-the-complete-flow)
16. [Running the event processor](#running-the-event-processor)
17. [Configuration precedence](#configuration-precedence)
18. [Security notes](#security-notes)
19. [Troubleshooting](#troubleshooting)
20. [Database-specific notes](#database-specific-notes)
21. [Running the tests](#running-the-tests)
22. [Project structure](#project-structure)
23. [Known limitations](#known-limitations)
24. [Production hardening](#production-hardening)
25. [License](#license)

---

## What this demonstrates

- Persisting a customer conversation **before** calling Slack, so a Slack outage
  delays delivery instead of losing the message.
- Mapping one customer conversation to exactly one Slack thread, using the
  channel ID and thread timestamp Slack returns — never by matching text, email
  addresses or approximate timestamps.
- Verifying inbound Slack requests: HMAC-SHA256 over the exact raw body, a
  five-minute replay window, and a constant-time comparison.
- Making duplicate Slack event deliveries harmless through a unique `event_id`
  and an atomic insert-if-missing, rather than a select followed by an insert.
- Acknowledging Slack in milliseconds and doing the real work in a separate
  worker.
- Delivering support replies to the browser over Server-Sent Events, with
  reconnection, `Last-Event-ID` replay and per-conversation authorization.
- Writing one dialect of SQL across PostgreSQL, MySQL and SQL Server, with the
  unavoidable differences isolated in a single component.

## Architecture

```
Browser                 ColdFusion                     Slack
───────                 ──────────                     ─────
                   ┌──────────────────┐
POST /api/… ──────►│ conversation_    │──► database (source of truth)
                   │ service          │
                   └────────┬─────────┘
                            │ queue row
                   ┌────────▼─────────┐
                   │ slack_delivery_  │──► chat.postMessage ──► thread
                   │ service          │◄── channel + ts
                   └──────────────────┘

                   ┌──────────────────┐
GET /stream/… ◄────│ event_stream_    │◄── conversation_message
   (SSE)           │ service          │
                   └──────────────────┘

                   ┌──────────────────┐
                   │ slack/events.cfm │◄── Events API callback
                   │ verify + enqueue │
                   └────────┬─────────┘
                            │ slack_event_inbox
                   ┌────────▼─────────┐
                   │ slack_event_     │──► support message ──► SSE
                   │ service (worker) │
                   └──────────────────┘
```

Each service has one job:

| Component | Responsibility |
| --- | --- |
| `config_service` | Load, validate and persist configuration |
| `database_service` | Everything that differs between the three databases |
| `slack_service` | Slack URLs, bearer auth, JSON, `ok` checking, signature verification |
| `conversation_service` | Conversations, messages, authorization, the message cursor |
| `slack_delivery_service` | The outbound queue: customer messages into Slack |
| `slack_event_service` | The inbound queue: Slack events into support messages |
| `event_stream_service` | SSE framing and cursor reads |
| `setup_service` | Configuration diagnostics |
| `api_service` | Exceptions into safe HTTP responses |
| `log_service` | Structured logging with secret redaction |

`slack_service` knows nothing about your tables. `conversation_service` knows
nothing about Slack's API. That separation is the point.

## Message flow

**Customer sends the first message**

1. `api/conversation.cfm` validates the name, email and body.
2. In one transaction: insert the conversation, insert the message, insert an
   outbound delivery row.
3. Commit. The message is now a fact.
4. Attempt delivery immediately. Slack returns a channel and a `ts`.
5. Store both against the conversation. That pair is the thread from now on.
6. Return the conversation, the message, and an honest delivery status.

If step 4 fails, steps 1 to 3 still happened. The queue row remains and is
retried; the browser is told the message is queued, not that it vanished.

**Customer sends a later message**

Same, except the stored `slack_channel_id` and `slack_thread_ts` are reused as a
thread reply. A second root message is never created.

**Support replies in Slack**

1. Slack POSTs to `slack/events.cfm`.
2. The endpoint reads the raw body, verifies the signature, checks the timestamp,
   writes the event to `slack_event_inbox`, and returns HTTP 200. Nothing else.
3. The worker claims the event, filters it, maps channel + `thread_ts` to a
   conversation, and inserts the support message once.
4. The open SSE request notices a message past its cursor and writes a frame.
5. The browser renders it.

## Requirements

| | |
| --- | --- |
| CommandBox | 5.0 or later |
| Java | 11 or later (CommandBox can install one) |
| Database | PostgreSQL 12+, MySQL 8.0.16+, or SQL Server 2016+ |
| Slack | A workspace where you can create and install an app |
| Tunnel | Cloudflare Tunnel, ngrok or similar, for the Events API |

**Tested on:** Lucee 6.2.7.16 under CommandBox 6.3.2 with Java 21, against
PostgreSQL 16, MySQL 8 and SQL Server 2022. The full test suite passes against
all three.

Adobe ColdFusion 2021 and 2023 should work — the code is engine-neutral and the
two places where the engines differ are isolated and commented — but the suite
has only been executed on Lucee.

## Quick start

Ten minutes, assuming you have a database and a Slack workspace.

```bash
git clone <this-repository> cfml-slack-chat
cd cfml-slack-chat
```

Create the schema (PostgreSQL shown; see [Database setup](#database-setup) for
the others):

```bash
psql -h localhost -U your_user -d your_database -f sql/postgresql.sql
```

Start the server:

```bash
box server start
```

CommandBox prints the URL, normally <http://127.0.0.1:8080>. Open it. You will
see the setup form.

In a second terminal, start a tunnel:

```bash
cloudflared tunnel --url http://localhost:8080
```

Copy the `https://…trycloudflare.com` address it prints.

Now, in the browser:

1. Paste your Slack bot token, signing secret and channel ID.
2. Enter your database connection details.
3. Paste the tunnel address as the public base URL.
4. Press **Save configuration**.
5. Press **Test configuration**. Fix anything red.
6. Copy the **Slack Events Request URL** it displays.

In Slack, paste that URL into **Event Subscriptions**, subscribe to
`message.channels`, and reinstall if prompted. Then invite the bot to your
channel:

```
/invite @your-bot-name
```

Back in the browser, send a message. It appears in Slack as a new thread. Reply
in that thread. The reply appears in the browser without a refresh.

## Database setup

Three scripts, one per platform. Each is independently runnable and safe to run
more than once.

```bash
# PostgreSQL
psql -h localhost -U your_user -d your_database -f sql/postgresql.sql

# MySQL
mysql -h 127.0.0.1 -u your_user -p your_database < sql/mysql.sql

# SQL Server
sqlcmd -S localhost -U your_user -P your_password -d your_database -i sql/sqlserver.sql
```

Four tables are created:

| Table | Purpose |
| --- | --- |
| `conversation` | One row per conversation, including the Slack channel and thread |
| `conversation_message` | Customer and support messages in one ordered stream |
| `slack_event_inbox` | Verified Slack callbacks, keyed on Slack's `event_id` |
| `slack_outbound_delivery` | The durable queue for messages on their way to Slack |

The database user needs `SELECT`, `INSERT`, `UPDATE`, `DELETE` on those tables
and read access to `information_schema` for the startup schema check.

## CommandBox setup

Install CommandBox from <https://commandbox.ortusbooks.com/setup/installation> —
on macOS, `brew install commandbox`.

```bash
box server start      # start; prints the URL
box server stop       # stop
box server restart    # restart, needed after changing CFML code
box server log        # tail the engine log
box server info       # port, PID, paths
```

`server.json` pins Lucee 6 and port 8080. To try a different engine:

```bash
box server start cfengine=adobe@2023
box server start cfengine=lucee@5
```

The engine installs into `.engine/`, which `.gitignore` excludes.

**Reloading.** Configuration changes take effect on the next request — the
application watches the configuration file's modification time and rebuilds its
services. Changes to CFML *code* need `box server restart`, because the services
already instantiated in the application scope keep running the code they were
compiled from.

## Application configuration

Open the application in a browser and use the setup form. It writes
`.config/config.json`, which `.gitignore` excludes and which is created with
owner-only permissions where the operating system allows it.

The form collects:

- **Slack**: bot token, signing secret, channel ID, and optionally app ID and
  workspace ID.
- **Database**: either the name of a datasource you have already defined in the
  CFML administrator, or the host, port, database, user and password for the
  application to define one itself. Either way, the database *type* is required,
  because it selects the SQL dialect.
- **Public base URL**: the address of your tunnel.
- **Test visitor defaults**: optional name and email to prefill the chat form.

**Test configuration** checks the datasource, the schema, the bot token, the
channel and whether the bot is a member of it. It posts nothing into your
channel to do so.

Secrets are never sent back to the browser. Once a token is stored the form shows
only that one is present; leaving the field blank keeps it.

If you would rather not use the form, see [`config/README.md`](config/README.md)
for the file format and the environment variables.

## Creating the Slack app

1. Go to <https://api.slack.com/apps> and choose **Create New App**, then
   **From scratch**.
2. Name it something recognisable, pick your test workspace, and create it.
3. Open **OAuth & Permissions** and add the scopes below.

## Required Slack scopes

Under **Bot Token Scopes**:

| Scope | Why this application needs it |
| --- | --- |
| `chat:write` | Post the root message and thread replies |
| `channels:history` | Receive `message.channels` events from public channels |
| `channels:read` | Read channel information, so setup can tell you the bot is not in the channel before you discover it the hard way |

If your support channel is **private**, add these as well and use the private
channel equivalents throughout:

| Scope | |
| --- | --- |
| `groups:history` | Receive `message.groups` events |
| `groups:read` | Read private channel information |

That is the complete list. This application does not request `users:read`, so
support replies are attributed using the profile Slack includes on the event, or
"Support" when it includes none. Add `users:read` yourself if you want real
display names; nothing else changes.

## Installing the app and inviting the bot

1. **OAuth & Permissions** → **Install to Workspace** → **Allow**.
2. Copy the **Bot User OAuth Token**. It starts `xoxb-`.
3. **Basic Information** → **App Credentials** → copy the **Signing Secret**.
4. In Slack, open your support channel and invite the bot:

   ```
   /invite @your-bot-name
   ```

The bot must be a member of the channel. Authenticating is not the same as being
in the room, and Slack will tell you so with `not_in_channel`.

Whenever you change scopes, Slack requires you to reinstall the app, and
reinstalling issues a **new** bot token. Copy it again.

## Finding the channel ID

The application needs `C0123456789`, not `#support`.

1. Open the channel in Slack.
2. Click the channel name to open **View channel details**.
3. Scroll to the bottom of the **About** tab. The channel ID is there, with a
   copy button.

Alternatively, **Copy link** on the channel gives a URL ending in the ID.

## Starting a public HTTPS tunnel

Slack's servers cannot reach `localhost`. That address is extremely meaningful to
your laptop and to nobody else.

**Cloudflare Tunnel** (no account needed for a quick tunnel):

```bash
cloudflared tunnel --url http://localhost:8080
```

**ngrok**:

```bash
ngrok http 8080
```

Both print an `https://…` address. Copy it into the setup form as the public base
URL and save. The Events Request URL appears immediately below it.

Free tunnel addresses change every time you restart the tunnel. When that
happens you must update the public base URL here *and* the Request URL in Slack.
Slack re-verifies the new URL on save.

## Configuring the Events API

1. In your Slack app, open **Event Subscriptions** and turn it on.
2. Paste the Request URL:

   ```
   https://your-tunnel-address/slack/events.cfm
   ```

3. Slack immediately sends a `url_verification` challenge. The endpoint echoes it
   back and Slack shows **Verified**. If it does not, see
   [Troubleshooting](#troubleshooting).
4. Expand **Subscribe to bot events** and add:

   | Event | For |
   | --- | --- |
   | `message.channels` | Public channels |
   | `message.groups` | Private channels, if that is what you are using |

5. **Save Changes**. Reinstall the app if Slack asks.

The server must be running before you save the Request URL, because Slack
verifies it on the spot.

## Testing the complete flow

1. Open <http://127.0.0.1:8080>. You should see the chat interface, not the setup
   form, and the connection badge should read **Live**.
2. Enter a name and email, type a message, press **Send**.
3. In the browser: your message appears, and the diagnostics panel fills in the
   Slack channel and thread timestamp.
4. In Slack: a new thread appears in the channel with the visitor's details and
   the message.
5. Reply **inside that thread**. A top-level channel message is deliberately
   ignored, because it belongs to no conversation.
6. Within a couple of seconds the reply appears in the browser. No refresh.
7. Send another message from the browser. It joins the same thread rather than
   starting a new one.
8. Press **New conversation** and repeat. You get a second, separate thread.

Things worth trying, since this is a reference application and breaking it is
educational:

- Stop the tunnel and send a message. It is saved, the status shows a delivery
  problem, and nothing is lost.
- Reply in a thread twice in quick succession. Both replies arrive, once each.
- Leave the page open for a minute. The SSE connection closes on schedule and the
  browser reconnects on its own; the badge flickers to **Reconnecting** and back.

## Running the event processor

The application ships with automatic draining switched on
(`app.auto_process_events`), which lets the open SSE request work through both
queues. That is what makes the walkthrough above work with one terminal.

The supported worker is a CommandBox task:

```bash
box task run taskFile=tasks/process_slack_events
```

Continuously, for a demo you are leaving running:

```bash
box task run taskFile=tasks/process_slack_events --watch interval=5
```

Output looks like this:

```
Slack event processor
  database : postgresql
  channel  : C0123456789

events     claimed=1 processed=1 ignored=0 retrying=0 failed=0
deliveries claimed=1 sent=1 deferred=0 failed=0
```

Run it from the repository root. The task runs in CommandBox's own CFML engine
rather than in the server, so it builds its own connection from the same
configuration file. That requires application-managed database settings; if you
configured an existing datasource by *name*, the task says so and stops, because
a name defined inside the CFML server means nothing outside it.

When the task is doing the work, set `app.auto_process_events` to `false` so the
streaming requests stop competing for the same rows.

There is also a **Process queues now** button in the diagnostics panel. It
requires development tools to be enabled, a matching CSRF token, and a loopback
connection. It is a convenience, not an administrative endpoint.

**Logs** are written to `logs/slack-chat.log` as one JSON object per line:

```bash
tail -f logs/slack-chat.log
```

Engine logs are separate: `box server log`.

## Configuration precedence

Highest first:

1. **Environment variables** — and they are locked. A value from the environment
   is shown read-only in the setup form and cannot be overwritten from a browser.
2. **`.config/config.json`** — written by the setup form, excluded by
   `.gitignore`.
3. **Built-in defaults** — non-secret values only.

The variables are `SLACK_BOT_TOKEN`, `SLACK_SIGNING_SECRET`, `SLACK_CHANNEL_ID`,
`SLACK_APP_ID`, `SLACK_TEAM_ID`, `CF_DATASOURCE`, `DB_TYPE`, `DB_HOST`,
`DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `PUBLIC_BASE_URL` and
`SLACK_CHAT_CONFIG_FILE`. Full details in [`config/README.md`](config/README.md).

## Security notes

Implemented here:

- **Signature verification** on every inbound Slack request, over the exact raw
  bytes, before the payload is parsed or trusted.
- **Replay protection**: requests more than 300 seconds old or in the future are
  rejected.
- **Constant-time comparison**, via a keyed HMAC of both values so the loop
  cannot leak the length either.
- **Parameterized SQL** everywhere. No value — not an ID, a timestamp, a message
  body or a configuration setting — is concatenated into a statement.
- **Conversation access tokens**: 256 bits of randomness, stored only as a
  SHA-256 hash, required for sending, reading history and opening a stream.
- **Output encoding** in views, and `textContent` for message bodies in the
  browser. Never `innerHTML`.
- **Slack escaping** on outbound text, so a visitor cannot type `<!channel>` into
  your support room.
- **CSRF tokens** on the setup form and the JSON API.
- **Secret redaction** in logs, error messages and API responses.
- **Generic public errors**, detailed private logs.
- **Blocked paths**: `services/`, `tasks/`, `config/`, `sql/`, `logs/` and
  `.config/` are refused by both the web server rules and `Application.cfc`.
- **Message length and request size limits**, and email validation.
- **HttpOnly, SameSite session cookies**, marked Secure when the request arrived
  over TLS.

Not implemented, deliberately: user accounts, roles, rate limiting on the public
endpoints, and encryption at rest. See [Known limitations](#known-limitations).

**Do not commit your bot token.** Git has an excellent memory and very poor
judgement. If one does escape, rotate it in Slack — rewriting history is not a
fix.

## Troubleshooting

### Slack rejects the token — `invalid_auth`

You pasted the wrong value. The bot token starts `xoxb-` and lives under **OAuth
& Permissions**, not **Basic Information**. If you changed scopes recently, Slack
issued a new token when you reinstalled; the old one is dead.

### `missing_scope`

The app is installed but lacks a scope. Slack's error names the one it wanted.
Add it under **OAuth & Permissions**, reinstall, then copy the new token into the
setup form.

### `channel_not_found`

Almost always a channel *name* where an ID belongs. It must look like
`C0123456789`. It also appears if the channel is private and you have not added
`groups:read` and `groups:history`.

### `not_in_channel`

The bot authenticated but is not in the room. `/invite @your-bot-name` in the
channel. **Test configuration** catches this before you send anything.

### Slack will not verify the Request URL

Work through it in order:

1. Is the server running? `box server info`.
2. Is the tunnel running, and is the address in the setup form the current one?
3. Does the URL end in `/slack/events.cfm`?
4. Try it yourself: `curl -i https://your-tunnel/slack/events.cfm` should return
   **405**, not a connection error and not a 404. A 405 means the endpoint is
   reachable and refusing GET, which is correct.
5. Check `logs/slack-chat.log` for a `slack.inbound` entry. If verification was
   rejected, the `reason` field says which check failed.

### Signature mismatch

`reason: signature_mismatch` in the log means the signing secret is wrong, or a
proxy modified the body. Copy the signing secret again from **Basic
Information**. Note that it is the *signing secret*, not the deprecated
verification token, and not the bot token.

### `stale_timestamp` or `future_timestamp`

Your server's clock has drifted more than five minutes from Slack's. Enable NTP.
Inside a virtual machine that has been suspended, this is common.

### Duplicate Slack event callbacks

Expected, and harmless. Slack retries when it does not get a fast 200. The
`event_id` primary key means a repeat delivery is stored once, and the unique
index on `(conversation_id, slack_message_ts)` means it becomes one message even
if Slack invents a new event ID for the same reply.

### Slack keeps retrying

Slack retries anything slower than three seconds or unsuccessful. Check the log
for how long `slack/events.cfm` took. If the database is slow to accept the
insert, that is where to look — the endpoint does nothing else.

### No SSE updates in the browser

- Is the connection badge **Live**? If it says **Disconnected**, look at the
  browser console.
- Are events arriving at all? Check `logs/slack-chat.log` for `slack.inbound`
  entries. No entries means Slack is not reaching you — a tunnel problem.
- Are events arriving but being ignored? The log's `reason` field explains why:
  `wrong_channel`, `not_a_thread_reply`, `no_matching_conversation`.
- `no_matching_conversation` means you replied in a thread this application does
  not own, or the conversation never got a thread because the original post
  failed.
- Is the worker running? Either `app.auto_process_events` must be on, or the
  CommandBox task must be running.

### CFML debugging output corrupting the SSE stream

If debug output is enabled server-wide it is appended to every response,
including the event stream, and the browser sees malformed frames.
`Application.cfc` calls `cfsetting( showdebugoutput = false )` on every request,
which handles it. If you have enabled debugging in the CFML administrator for a
specific IP, turn it off while testing this.

### CommandBox will not start

`box server log` first. Common causes: port 8080 already taken (change it in
`server.json`), or a partial engine download (`box server forget` then start
again).

### Missing datasource

The application defines `slackSupportChat` itself from your settings. If it says
the datasource does not exist, you are probably in *existing datasource* mode
with a name the CFML server does not have. Either fix the name or switch to
application-managed settings.

### Missing tables

**Test configuration** names exactly which tables are absent. Run the script in
`sql/` for your platform.

### Database permission errors

The user needs DML on all four tables plus read access to `information_schema`.
Without the latter the startup schema check cannot run and the application will
not report itself ready.

### The tunnel address changed

Free tunnels get a new address on every restart. Update the public base URL in
the setup form, then update the Request URL in Slack. Both.

### Messages land in the channel root instead of the thread

This means the conversation has no stored `slack_thread_ts` — the original post
failed and later messages have nothing to reply to. Check
`slack_outbound_delivery` for the conversation: a `failed` or `abandoned` first
row explains it. Fix the underlying Slack error and the retry opens the thread
properly.

### The bot's own messages come back into the chat

They should not. Events carrying a `bot_id` are dropped, and so are events from
this app's own bot user ID once **Test configuration** has recorded it. If you
see this, run **Test configuration** so the bot user ID is stored.

## Database-specific notes

Application SQL is identical across all three. The differences live in
`services/database_service.cfc` and the DDL.

| | PostgreSQL | MySQL | SQL Server |
| --- | --- | --- | --- |
| Identity column | `generated by default as identity` | `auto_increment` | `identity(1,1)` |
| Returning the new ID | `RETURNING` | `LAST_INSERT_ID()` in the transaction | `OUTPUT INSERTED` |
| Insert-if-missing | `ON CONFLICT DO NOTHING` | `ON DUPLICATE KEY UPDATE` (no-op) | `INSERT … WHERE NOT EXISTS` with `UPDLOCK, HOLDLOCK` |
| Nullable unique keys | Partial index | InnoDB allows repeated NULLs | Filtered index |
| Current database | `current_schema()` | `database()` | `db_name()` |
| Timestamp type | `timestamp` | `datetime(3)` | `datetime2(3)` |

Three things worth knowing before they cost you an evening:

**MySQL** columns are `datetime(3)`, not `datetime`. A plain `datetime` has
one-second precision and *rounds* to it, so a row queued at `12:00:00.900` is
stored as `12:00:01` and a worker sweeping 50 ms later decides it is not due yet.
The connection string also sets `useAffectedRows=true`, so the driver reports
rows *changed* rather than rows *matched* — matching what the other two do.

**SQL Server** needs `SET QUOTED_IDENTIFIER ON` to create a filtered index. The
script sets it. Without it the tables are created perfectly happily and the three
unique indexes are not, leaving a schema that looks correct and enforces nothing.

**Foreign keys** are `ON DELETE RESTRICT` (`NO ACTION` on SQL Server, which is the
same behaviour under a different name). Deleting a conversation that still has
messages is refused rather than quietly orphaning them.

## Running the tests

TestBox is a development dependency:

```bash
box install
```

Then either:

```bash
box testbox run
```

or open <http://127.0.0.1:8080/tests/runner.cfm> with the server running.

**Unit specs** need nothing but the engine: signature verification against a
fixed vector, event filtering, SSE framing, cursor resolution, identifier
generation, configuration precedence and error mapping.

**Integration specs** use the database in your configuration and skip cleanly
when none is available. Slack itself is stubbed at the HTTP boundary only —
formatting, escaping and error classification are the real code — so the specs
that assert "the first message opens a thread and every later message joins it"
are asserting about the real delivery logic.

Everything the specs create is cleaned up afterwards, in foreign-key order.

At the time of writing: **183 specs pass** against PostgreSQL 16, MySQL 8 and
SQL Server 2022, on Lucee 6.2.7.16.

More detail in [`tests/README.md`](tests/README.md).

## Project structure

```
.
├── Application.cfc              Lifecycle, service wiring, datasource, path blocking
├── index.cfm                    Single browser entry point: setup or chat
├── server.json                  CommandBox: engine, port, blocked paths
├── box.json                     Dependencies and scripts
├── api/
│   ├── conversation.cfm         POST  start a conversation
│   ├── message.cfm              POST  add a message · GET history
│   ├── status.cfm               GET   diagnostics · POST dev queue drain
│   └── response.cfm             Shared endpoint plumbing (included, never requested)
├── assets/
│   ├── css/app.css              Chat presentation only
│   └── js/app.js                Fetch, EventSource, safe rendering
├── config/
│   ├── config.example.json      Placeholders only
│   └── README.md                Configuration reference
├── services/                    All application logic
├── slack/events.cfm             Events API endpoint: verify, enqueue, return
├── sql/                         One schema script per platform
├── stream/conversation.cfm      SSE endpoint
├── tasks/process_slack_events.cfc   CommandBox worker
├── tests/                       TestBox specs and support doubles
└── views/
    ├── setup.cfm                Configuration form
    └── chat.cfm                 Chat interface
```

## Known limitations

This is a focused reference application. The following are out of scope by
design, not oversights:

- **No user accounts.** Conversations are protected by an access token, which is
  a lightweight test-application access model, not authentication.
- **One workspace, one channel.** No Slack OAuth distribution flow.
- **No attachments, files or emoji reactions.** Text only.
- **Message edits and deletions in Slack are ignored.** The customer keeps the
  message as first sent. Making edits propagate means deciding what a chat
  transcript *is*, which is a product decision rather than a technical one.
- **Thread broadcasts are accepted** as ordinary replies, because Slack sends
  them once and the unique index makes a duplicate impossible; dropping them
  would only lose real replies.
- **Support display names** come from whatever profile Slack includes on the
  event. Real names need `users:read`, which this app does not request.
- **The SSE poll interval is a database query every 1.5 seconds per connection.**
  Fine for a demo, not a design to copy at scale.
- **No rate limiting** on the public endpoints.
- **Conversations are never expired or purged.**

## Production hardening

If you take this architecture into production, these are the parts that need
more than a reference implementation gives them.

**Workers and queues.** Replace the SSE-triggered drain entirely with a real
worker process. Run several. The claim mechanism here is a conditional `UPDATE`,
which is genuinely safe across workers, but you will want a visibility timeout so
a worker that dies mid-message releases its claim instead of stranding it in
`processing`. Add a dead-letter queue with alerting rather than a terminal
`failed` status nobody reads.

**Retries and rate limits.** The backoff here is a fixed schedule. Add jitter, or
a thundering herd will find you after any Slack incident. `Retry-After` is
honoured for 429s; extend that to a token bucket per workspace, since Slack's
limits are per-app.

**Secrets.** A local JSON file is right for a test application and wrong for a
deployment. Use your platform's secret manager, rotate on a schedule, and make
rotation not require a restart.

**Authentication and authorization.** Conversation access tokens are not
identity. Tie conversations to real accounts, and re-check authorization on every
request rather than trusting a token that was issued once.

**Data retention and PII.** Message bodies are customer data, and this schema
keeps them forever. Decide a retention period, implement deletion, and remember
that Slack has its own copy governed by its own retention settings. Message
bodies stay out of logs by default here; keep it that way.

**Monitoring.** Alert on inbox depth, delivery queue depth, `abandoned`
deliveries, `failed` events, signature rejection rate and Slack API error rates.
A steady trickle of `signature_mismatch` means either a misconfiguration or
somebody probing.

**Scaling and SSE.** Each open stream holds a request thread and issues periodic
queries. At scale, replace polling with a notification mechanism — LISTEN/NOTIFY,
a message bus, a shared cache — and size the connection pool for concurrent
streams rather than concurrent users. Load balancers and reverse proxies need
idle timeouts above the stream lifetime, and buffering disabled; the endpoint
sends `X-Accel-Buffering: no` for the ones that respect it. The bounded
connection lifetime here exists precisely so that intermediaries never have to
guess whether a quiet connection is dead.

**Multiple workspaces and channels.** Store the installation per workspace, key
conversations by workspace as well as channel, and implement the Slack OAuth
installation flow. The signing secret becomes per-app rather than global.

**Slack outages.** The queue already survives them. What needs adding is a
circuit breaker, so a workspace-wide outage does not mean every queued message
burning its retry budget against a wall in the first thirty seconds.

**Attachments, edits and deletions.** All three are genuine features rather than
missing plumbing. Each needs a product decision before it needs code.

## License

No license has been chosen for this repository yet, which means default copyright
applies and nobody else has permission to use it. Add a license file before
publishing — MIT or Apache-2.0 are the usual choices for a reference
implementation intended to be copied from.
