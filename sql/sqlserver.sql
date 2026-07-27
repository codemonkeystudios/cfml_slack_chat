-- =============================================================================
-- cfml-slack-chat : schema for Microsoft SQL Server
-- Target: SQL Server 2016 or later (filtered indexes, SYSUTCDATETIME)
--
-- Safe to run more than once. Every object is wrapped in an existence check.
--
-- sqlcmd -S localhost -U your_user -P your_password -d your_database -i sql/sqlserver.sql
--
-- GO separates batches so that each CREATE INDEX compiles after its table
-- exists. Run this in SSMS, Azure Data Studio or sqlcmd, all of which understand
-- GO. It is a client directive, not T-SQL, so tools that do not recognise it
-- will need the batches split by hand.
--
-- Note on foreign keys: T-SQL has no ON DELETE RESTRICT. NO ACTION is the same
-- behaviour under a different name — the delete is refused rather than allowed
-- to orphan rows.
--
-- An optional reset section is at the bottom. It is commented out, and it is
-- commented out for a reason.
-- =============================================================================


-- Three of the indexes below are filtered, and SQL Server refuses to create a
-- filtered index unless these options are on. SSMS sets them; sqlcmd does not,
-- and without them the CREATE INDEX statements fail while the tables are created
-- perfectly happily — leaving a schema that looks fine and has no uniqueness
-- guarantee at all. The same options must be on for any connection that later
-- modifies these tables; JDBC drivers set them by default.
set ansi_nulls on;
GO
set quoted_identifier on;
GO


-- -----------------------------------------------------------------------------
-- conversation
-- One row per customer conversation. slack_channel_id and slack_thread_ts are
-- null until Slack has accepted the opening message and told us where it went.
-- -----------------------------------------------------------------------------
if object_id('dbo.conversation', 'U') is null
begin
	create table dbo.conversation (
		conversation_id char(36) not null,
		visitor_name nvarchar(120) not null,
		visitor_email nvarchar(255) not null,
		status varchar(20) not null constraint df_conversation_status default 'waiting',
		access_token_hash char(64) not null,
		slack_channel_id varchar(32) null,
		slack_thread_ts varchar(32) null,
		created_at datetime2(3) not null constraint df_conversation_created default sysutcdatetime(),
		updated_at datetime2(3) not null constraint df_conversation_updated default sysutcdatetime(),
		closed_at datetime2(3) null,
		constraint pk_conversation primary key clustered (conversation_id),
		constraint ck_conversation_status check (status in ('active', 'waiting', 'closed'))
	);
end;
GO

if not exists (select 1 from sys.indexes where name = 'ix_conversation_status' and object_id = object_id('dbo.conversation'))
	create index ix_conversation_status on dbo.conversation (status);
GO

if not exists (select 1 from sys.indexes where name = 'ix_conversation_updated' and object_id = object_id('dbo.conversation'))
	create index ix_conversation_updated on dbo.conversation (updated_at);
GO

-- The pairing of channel and thread is how an inbound Slack reply finds its
-- conversation, so it has to be both unique and fast. The filter is required:
-- SQL Server treats NULLs as equal in a unique index, so an unfiltered version
-- would allow exactly one conversation to exist without a Slack thread.
if not exists (select 1 from sys.indexes where name = 'ux_conversation_slack_thread' and object_id = object_id('dbo.conversation'))
	create unique index ux_conversation_slack_thread
		on dbo.conversation (slack_channel_id, slack_thread_ts)
		where slack_channel_id is not null and slack_thread_ts is not null;
GO


-- -----------------------------------------------------------------------------
-- conversation_message
-- Customer and support messages share one ordered stream. message_id is the
-- cursor the browser's SSE connection reads from.
-- -----------------------------------------------------------------------------
if object_id('dbo.conversation_message', 'U') is null
begin
	create table dbo.conversation_message (
		message_id bigint identity(1,1) not null,
		conversation_id char(36) not null,
		sender_type varchar(16) not null,
		sender_id varchar(64) null,
		sender_name nvarchar(120) null,
		body nvarchar(max) not null,
		source varchar(16) not null,
		slack_event_id varchar(64) null,
		slack_message_ts varchar(32) null,
		created_at datetime2(3) not null constraint df_message_created default sysutcdatetime(),
		constraint pk_conversation_message primary key clustered (message_id),
		constraint fk_message_conversation foreign key (conversation_id)
			references dbo.conversation (conversation_id) on delete no action,
		constraint ck_message_sender_type check (sender_type in ('customer', 'support', 'system')),
		constraint ck_message_source check (source in ('web', 'slack', 'system'))
	);
end;
GO

if not exists (select 1 from sys.indexes where name = 'ix_message_conversation' and object_id = object_id('dbo.conversation_message'))
	create index ix_message_conversation on dbo.conversation_message (conversation_id, message_id);
GO

-- Two independent guarantees that one Slack reply becomes one customer-visible
-- message, no matter how many times Slack delivers the event.
if not exists (select 1 from sys.indexes where name = 'ux_message_slack_ts' and object_id = object_id('dbo.conversation_message'))
	create unique index ux_message_slack_ts
		on dbo.conversation_message (conversation_id, slack_message_ts)
		where slack_message_ts is not null;
GO

if not exists (select 1 from sys.indexes where name = 'ux_message_slack_event' and object_id = object_id('dbo.conversation_message'))
	create unique index ux_message_slack_event
		on dbo.conversation_message (slack_event_id)
		where slack_event_id is not null;
GO


-- -----------------------------------------------------------------------------
-- slack_event_inbox
-- Verified Slack event callbacks, written by the webhook and drained by the
-- processor. event_id is Slack's globally unique identifier and is the primary
-- key, which is what makes duplicate delivery a no-op rather than a bug.
-- -----------------------------------------------------------------------------
if object_id('dbo.slack_event_inbox', 'U') is null
begin
	create table dbo.slack_event_inbox (
		event_id varchar(64) not null,
		event_type varchar(64) not null,
		inner_event_type varchar(64) null,
		payload nvarchar(max) not null,
		raw_body nvarchar(max) not null,
		retry_num int not null constraint df_event_retry_num default 0,
		retry_reason varchar(64) null,
		received_at datetime2(3) not null constraint df_event_received default sysutcdatetime(),
		processed_at datetime2(3) null,
		attempt_count int not null constraint df_event_attempts default 0,
		last_error nvarchar(1000) null,
		status varchar(16) not null constraint df_event_status default 'pending',
		next_attempt_at datetime2(3) not null constraint df_event_next_attempt default sysutcdatetime(),
		claimed_by varchar(64) null,
		constraint pk_slack_event_inbox primary key clustered (event_id),
		constraint ck_event_status check (status in ('pending', 'processing', 'processed', 'ignored', 'failed'))
	);
end;
GO

if not exists (select 1 from sys.indexes where name = 'ix_event_status' and object_id = object_id('dbo.slack_event_inbox'))
	create index ix_event_status on dbo.slack_event_inbox (status, next_attempt_at);
GO

if not exists (select 1 from sys.indexes where name = 'ix_event_received' and object_id = object_id('dbo.slack_event_inbox'))
	create index ix_event_received on dbo.slack_event_inbox (received_at);
GO


-- -----------------------------------------------------------------------------
-- slack_outbound_delivery
-- The durable queue for customer messages on their way to Slack. One row per
-- message, so a Slack outage delays delivery instead of losing it.
-- -----------------------------------------------------------------------------
if object_id('dbo.slack_outbound_delivery', 'U') is null
begin
	create table dbo.slack_outbound_delivery (
		delivery_id bigint identity(1,1) not null,
		conversation_id char(36) not null,
		message_id bigint not null,
		destination varchar(32) not null constraint df_delivery_destination default 'slack',
		status varchar(16) not null constraint df_delivery_status default 'pending',
		attempt_count int not null constraint df_delivery_attempts default 0,
		next_attempt_at datetime2(3) not null constraint df_delivery_next_attempt default sysutcdatetime(),
		last_attempt_at datetime2(3) null,
		last_error nvarchar(1000) null,
		slack_channel_id varchar(32) null,
		slack_thread_ts varchar(32) null,
		created_at datetime2(3) not null constraint df_delivery_created default sysutcdatetime(),
		completed_at datetime2(3) null,
		claimed_by varchar(64) null,
		constraint pk_slack_outbound_delivery primary key clustered (delivery_id),
		constraint uq_delivery_message unique (message_id),
		constraint fk_delivery_conversation foreign key (conversation_id)
			references dbo.conversation (conversation_id) on delete no action,
		constraint fk_delivery_message foreign key (message_id)
			references dbo.conversation_message (message_id) on delete no action,
		constraint ck_delivery_status check (status in ('pending', 'processing', 'sent', 'failed', 'abandoned'))
	);
end;
GO

if not exists (select 1 from sys.indexes where name = 'ix_delivery_status' and object_id = object_id('dbo.slack_outbound_delivery'))
	create index ix_delivery_status on dbo.slack_outbound_delivery (status, next_attempt_at);
GO

if not exists (select 1 from sys.indexes where name = 'ix_delivery_conversation' and object_id = object_id('dbo.slack_outbound_delivery'))
	create index ix_delivery_conversation on dbo.slack_outbound_delivery (conversation_id, message_id);
GO


-- =============================================================================
-- Optional reset. Uncomment only when you want the test data gone.
-- Deletion order matters: the foreign keys refuse the delete rather than
-- allowing a conversation to leave its messages behind.
-- =============================================================================
-- drop table if exists dbo.slack_outbound_delivery;
-- drop table if exists dbo.slack_event_inbox;
-- drop table if exists dbo.conversation_message;
-- drop table if exists dbo.conversation;
-- GO
