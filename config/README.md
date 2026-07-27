# Configuration

This directory holds the example configuration only. Nothing in here is read at
runtime.

## Where the real configuration lives

The application reads its settings from, in order of precedence:

1. **Environment variables** — highest priority, and locked. A value supplied by
 the environment is shown as read-only in the setup form and cannot be
 overwritten from a browser.
2. **`.config/config.json`** in the repository root — created by the setup form,
 excluded by `.gitignore`, written with owner-only permissions where the
 operating system allows it.
3. **Built-in defaults** — non-secret values only.

`.config/` is blocked in three separate places: the `server.json` web rules, the
path check in `Application.cfc`, and the fact that no endpoint ever reads a file
by a caller-supplied path.

## Environment variables

| Variable | Maps to | Notes |
| --- | --- | --- |
| `SLACK_BOT_TOKEN` | `slack.bot_token` | Bot User OAuth Token, starts `xoxb-` |
| `SLACK_SIGNING_SECRET` | `slack.signing_secret` | 32 hexadecimal characters |
| `SLACK_CHANNEL_ID` | `slack.channel_id` | The ID, such as `C0123456789`, not `#support` |
| `SLACK_APP_ID` | `slack.app_id` | Optional. Set it and events from other apps are rejected |
| `SLACK_TEAM_ID` | `slack.team_id` | Optional. Filled in by the configuration check |
| `SLACK_BOT_USER_ID` | `slack.bot_user_id` | Optional. Filled in by the configuration check |
| `CF_DATASOURCE` | `database.datasource` | Setting this also forces `database.mode` to `existing` |
| `DB_TYPE` | `database.type` | `postgresql`, `mysql` or `sqlserver` |
| `DB_HOST` | `database.host` | |
| `DB_PORT` | `database.port` | |
| `DB_NAME` | `database.database` | |
| `DB_USER` | `database.username` | |
| `DB_PASSWORD` | `database.password` | |
| `PUBLIC_BASE_URL` | `app.public_base_url` | Your HTTPS tunnel address, no trailing slash |
| `SLACK_CHAT_CONFIG_FILE` | — | Absolute path to the configuration file, if you want it somewhere else entirely |

## Using this example file

You do not need to. The setup form writes `.config/config.json` for you, and it
is the easier path.

If you would rather start from a file:

```bash
mkdir -p .config
cp config/config.example.json .config/config.json
chmod 600 .config/config.json
```

Then edit the values. The application picks the change up on the next request —
the file's modification time is what triggers a service rebuild, so there is no
restart to remember.

## Keeping secrets out of git

`.gitignore` already excludes `.config/` and `config/config.json`. The example
file contains placeholders and must stay that way.

If a token does reach a commit, rotating it in Slack is the fix. Deleting the
commit is not: git has an excellent memory and very poor judgement.

## Settings that are not secrets

| Setting | Default | What it does |
| --- | --- | --- |
| `app.auto_process_events` | `true` | Lets the SSE request drain the queues, so the end-to-end test works without a second terminal. Turn it off when the CommandBox task is doing the work |
| `app.dev_tools` | `true` | Enables the "Process queues now" button, which also requires a loopback request |
| `app.log_message_bodies` | `false` | When false, logs record a message length instead of its text |
| `app.max_message_length` | `4000` | Rejected above this, before anything reaches the database |
| `app.sse_max_seconds` | `55` | How long one streaming connection lives before the browser reconnects |
| `app.sse_poll_milliseconds` | `1500` | How often the streaming request looks for new messages |
| `app.slack_timeout_seconds` | `15` | HTTP timeout on calls to Slack |
| `app.signature_max_age_seconds` | `300` | Replay window for inbound Slack requests |
| `app.allow_insecure_public_url` | `false` | Local-only mode. Relaxes the HTTPS requirement on the public base URL |
