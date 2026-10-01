-- Mechanics: inbound events (write first, process later), job queue, outbox, bot dialog state.

create table inbound_events (
  id bigint generated always as identity primary key,
  source text not null check (source in ('telegram', 'resend')),
  external_key text not null,                       -- update_id / svix id / email id: natural idempotency key
  payload jsonb not null,
  status text not null default 'new' check (status in ('new', 'processed', 'ignored', 'failed')),
  error text,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (source, external_key)
);

create table job_types (
  type text primary key,
  workflow_id text not null,                        -- n8n workflow that handles the job
  max_concurrency int not null default 4,
  max_attempts int not null default 5,
  lease_seconds int not null default 300,
  backoff_seconds int not null default 15,
  budget_gated boolean not null default false,      -- AI generation: blocked when the budget is exhausted
  description text not null default ''
);

create table jobs (
  id bigint generated always as identity primary key,
  type text not null references job_types (type),
  status text not null default 'queued'
    check (status in ('queued', 'running', 'done', 'failed', 'dead', 'blocked', 'cancelled')),
  priority int not null default 0,
  payload jsonb not null default '{}',
  material_id bigint,
  package_id bigint,
  variant_id bigint,
  brand_id bigint,
  dedupe_key text unique,                           -- never enqueue the same step twice
  coalesce_key text,                                -- at most one pending job per key
  attempts int not null default 0,
  max_attempts int not null,
  run_after timestamptz not null default now(),
  locked_until timestamptz,
  started_at timestamptz,
  finished_at timestamptz,
  last_error text,
  blocked_reason text,
  result jsonb,
  created_at timestamptz not null default now()
);
create unique index jobs_coalesce_uq on jobs (coalesce_key)
  where coalesce_key is not null and status in ('queued', 'failed', 'blocked');
create index jobs_ready on jobs (priority desc, run_after) where status in ('queued', 'failed');
create index jobs_running on jobs (type, locked_until) where status = 'running';
create index jobs_material on jobs (material_id) where material_id is not null;
create index jobs_blocked on jobs (blocked_reason) where status = 'blocked';

-- Outbox for everything the bot says (and system emails). Sent by CORE · Outbox sender with throttling.
create table outbox (
  id bigint generated always as identity primary key,
  channel text not null check (channel in ('telegram', 'email')),
  kind text not null check (kind in ('message', 'slot', 'document', 'callback_answer', 'delete', 'email')),
  chat_id bigint,
  email_to text,
  slot_key text,                                    -- kind=slot: send once, then edit the same message
  payload jsonb not null,
  batch_key text,                                   -- queued rows with the same key are merged into one message
  dedupe_key text unique,
  priority int not null default 0,
  status text not null default 'queued'
    check (status in ('queued', 'sending', 'sent', 'failed', 'dead', 'merged', 'cancelled')),
  attempts int not null default 0,
  send_after timestamptz not null default now(),
  locked_until timestamptz,
  sent_at timestamptz,
  result jsonb,
  last_error text,
  user_id bigint,
  brand_id bigint,
  material_id bigint,
  created_at timestamptz not null default now(),
  check ((channel = 'telegram' and chat_id is not null) or (channel = 'email' and email_to is not null))
);
create unique index outbox_slot_queued on outbox (slot_key) where status = 'queued' and slot_key is not null;
create index outbox_ready on outbox (priority desc, id) where status = 'queued';
create index outbox_sending on outbox (chat_id) where status = 'sending';

create table tg_message_slots (
  slot_key text primary key,                        -- ack:<material>, q:<material>, card:<package>:<user>, ...
  chat_id bigint not null,
  message_id bigint,
  content_kind text check (content_kind in ('text', 'photo')),
  photo_asset_id bigint references assets (id) on delete set null,
  updated_at timestamptz not null default now()
);

-- Multi-step bot input (edit text, comment, reason, time, uploads). One active session per user.
create table bot_sessions (
  user_id bigint primary key references users (id) on delete cascade,
  kind text not null,
  data jsonb not null default '{}',
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create table workflow_errors (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  workflow_id text,
  workflow_name text,
  execution_id text,
  node text,
  message text,
  data jsonb not null default '{}'
);

-- Deduplication for admin alerts (AD-5) and one-per-period notices (budget 80/100%).
create table alert_log (
  key text primary key,
  sent_at timestamptz not null default now()
);
