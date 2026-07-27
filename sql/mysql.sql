-- =============================================================================
-- cfml-slack-chat : schema for MySQL
-- Target: MySQL 8.0.16 or later (CHECK constraints, expression defaults)
--
-- Safe to run more than once. MySQL has no CREATE INDEX IF NOT EXISTS, so every
-- index is declared inside its CREATE TABLE IF NOT EXISTS statement. Re-running
-- the script therefore changes nothing.
--
-- mysql -h 127.0.0.1 -u your_user -p your_database < sql/mysql.sql
--
-- An optional reset section is at the bottom. It is commented out, and it is
-- commented out for a reason.
--
-- Note on datetime precision: the columns below are datetime(3), not datetime.
-- A plain MySQL datetime has a precision of one second and ROUNDS to it, so a
-- row queued at 12:00:00.900 is stored as 12:00:01 and a worker sweeping a
-- moment later decides it is not due yet. Milliseconds also match the precision
-- used by PostgreSQL and SQL Server.
--
-- Note on nullable unique keys: InnoDB permits any number of rows with NULL in a
-- unique index, which is exactly the behaviour needed for slack_thread_ts and
-- slack_message_ts before Slack has assigned them. PostgreSQL and SQL Server get
-- there via filtered indexes instead.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- conversation
-- One row per customer conversation. slack_channel_id and slack_thread_ts are
-- null until Slack has accepted the opening message and told us where it went.
-- -----------------------------------------------------------------------------
create table if not exists conversation (
	conversation_id char(36) not null,
	visitor_name varchar(120) not null,
	visitor_email varchar(255) not null,
	status varchar(20) not null default 'waiting',
	access_token_hash char(64) not null,
	slack_channel_id varchar(32) null,
	slack_thread_ts varchar(32) null,
	created_at datetime(3) not null default (utc_timestamp(3)),
	updated_at datetime(3) not null default (utc_timestamp(3)),
	closed_at datetime(3) null,
	primary key (conversation_id),
	key ix_conversation_status (status),
	key ix_conversation_updated (updated_at),
	-- The pairing of channel and thread is how an inbound Slack reply finds its
	-- conversation, so it has to be both unique and fast.
	unique key ux_conversation_slack_thread (slack_channel_id, slack_thread_ts),
	constraint ck_conversation_status check (status in ('active', 'waiting', 'closed'))
) engine=InnoDB default charset=utf8mb4 collate=utf8mb4_unicode_ci;


-- -----------------------------------------------------------------------------
-- conversation_message
-- Customer and support messages share one ordered stream. message_id is the
-- cursor the browser's SSE connection reads from.
-- -----------------------------------------------------------------------------
create table if not exists conversation_message (
	message_id bigint not null auto_increment,
	conversation_id char(36) not null,
	sender_type varchar(16) not null,
	sender_id varchar(64) null,
	sender_name varchar(120) null,
	body text not null,
	source varchar(16) not null,
	slack_event_id varchar(64) null,
	slack_message_ts varchar(32) null,
	created_at datetime(3) not null default (utc_timestamp(3)),
	primary key (message_id),
	key ix_message_conversation (conversation_id, message_id),
	-- Two independent guarantees that one Slack reply becomes one
	-- customer-visible message, no matter how often Slack delivers the event.
	unique key ux_message_slack_ts (conversation_id, slack_message_ts),
	unique key ux_message_slack_event (slack_event_id),
	constraint fk_message_conversation foreign key (conversation_id)
		references conversation (conversation_id) on delete restrict,
	constraint ck_message_sender_type check (sender_type in ('customer', 'support', 'system')),
	constraint ck_message_source check (source in ('web', 'slack', 'system'))
) engine=InnoDB default charset=utf8mb4 collate=utf8mb4_unicode_ci;


-- -----------------------------------------------------------------------------
-- slack_event_inbox
-- Verified Slack event callbacks, written by the webhook and drained by the
-- processor. event_id is Slack's globally unique identifier and is the primary
-- key, which is what makes duplicate delivery a no-op rather than a bug.
-- -----------------------------------------------------------------------------
create table if not exists slack_event_inbox (
	event_id varchar(64) not null,
	event_type varchar(64) not null,
	inner_event_type varchar(64) null,
	payload mediumtext not null,
	raw_body mediumtext not null,
	retry_num int not null default 0,
	retry_reason varchar(64) null,
	received_at datetime(3) not null default (utc_timestamp(3)),
	processed_at datetime(3) null,
	attempt_count int not null default 0,
	last_error varchar(1000) null,
	status varchar(16) not null default 'pending',
	next_attempt_at datetime(3) not null default (utc_timestamp(3)),
	claimed_by varchar(64) null,
	primary key (event_id),
	key ix_event_status (status, next_attempt_at),
	key ix_event_received (received_at),
	constraint ck_event_status check (status in ('pending', 'processing', 'processed', 'ignored', 'failed'))
) engine=InnoDB default charset=utf8mb4 collate=utf8mb4_unicode_ci;


-- -----------------------------------------------------------------------------
-- slack_outbound_delivery
-- The durable queue for customer messages on their way to Slack. One row per
-- message, so a Slack outage delays delivery instead of losing it.
-- -----------------------------------------------------------------------------
create table if not exists slack_outbound_delivery (
	delivery_id bigint not null auto_increment,
	conversation_id char(36) not null,
	message_id bigint not null,
	destination varchar(32) not null default 'slack',
	status varchar(16) not null default 'pending',
	attempt_count int not null default 0,
	next_attempt_at datetime(3) not null default (utc_timestamp(3)),
	last_attempt_at datetime(3) null,
	last_error varchar(1000) null,
	slack_channel_id varchar(32) null,
	slack_thread_ts varchar(32) null,
	created_at datetime(3) not null default (utc_timestamp(3)),
	completed_at datetime(3) null,
	claimed_by varchar(64) null,
	primary key (delivery_id),
	unique key uq_delivery_message (message_id),
	key ix_delivery_status (status, next_attempt_at),
	key ix_delivery_conversation (conversation_id, message_id),
	constraint fk_delivery_conversation foreign key (conversation_id)
		references conversation (conversation_id) on delete restrict,
	constraint fk_delivery_message foreign key (message_id)
		references conversation_message (message_id) on delete restrict,
	constraint ck_delivery_status check (status in ('pending', 'processing', 'sent', 'failed', 'abandoned'))
) engine=InnoDB default charset=utf8mb4 collate=utf8mb4_unicode_ci;


-- =============================================================================
-- Optional reset. Uncomment only when you want the test data gone.
-- Deletion order matters: the foreign keys are restrict, deliberately, so that
-- deleting a conversation cannot quietly orphan its messages.
-- =============================================================================
-- drop table if exists slack_outbound_delivery;
-- drop table if exists slack_event_inbox;
-- drop table if exists conversation_message;
-- drop table if exists conversation;
