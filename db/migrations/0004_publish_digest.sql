-- Publishing (at most once), stop switch, email digest, subscribers, external feeds.

create table publish_attempts (
  id bigint generated always as identity primary key,
  variant_id bigint references variants (id) on delete cascade,
  digest_issue_id bigint,
  op text not null default 'publish' check (op in ('publish', 'edit', 'delete')),
  adapter text not null check (adapter in ('telegram', 'blog', 'preview', 'email')),
  idempotency_key text not null unique,
  outcome text not null default 'pending' check (outcome in ('pending', 'ok', 'failed', 'unknown')),
  http_status int,
  external_id text,
  external_url text,
  error text,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  check (variant_id is not null or digest_issue_id is not null)
);
create index publish_attempts_variant on publish_attempts (variant_id, started_at desc);
create unique index publish_attempts_one_pending on publish_attempts (variant_id) where outcome = 'pending' and op = 'publish';

-- PB-9: pause at system, brand or platform level. Active = resumed_at is null.
create table system_pauses (
  id bigint generated always as identity primary key,
  scope text not null check (scope in ('system', 'brand', 'platform')),
  brand_id bigint references brands (id) on delete cascade,
  brand_platform_id bigint references brand_platforms (id) on delete cascade,
  reason text,
  paused_by bigint references users (id) on delete set null,
  paused_at timestamptz not null default now(),
  resumed_at timestamptz,
  resumed_by bigint references users (id) on delete set null,
  resume_mode text check (resume_mode in ('publish_overdue', 'reschedule')),
  check ((scope = 'system' and brand_id is null and brand_platform_id is null)
      or (scope = 'brand' and brand_id is not null and brand_platform_id is null)
      or (scope = 'platform' and brand_platform_id is not null))
);
create index system_pauses_active on system_pauses (scope, brand_id, brand_platform_id) where resumed_at is null;

create table digest_issues (
  id bigint generated always as identity primary key,
  brand_id bigint not null references brands (id) on delete cascade,
  brand_platform_id bigint not null references brand_platforms (id) on delete cascade,
  period_start timestamptz not null,
  period_end timestamptz not null,
  send_at timestamptz not null,
  status text not null default 'draft'
    check (status in ('draft', 'pending_approval', 'revising', 'approved', 'scheduled', 'rescheduled',
                      'publishing', 'failed', 'published', 'rejected', 'cancelled', 'skipped')),
  status_changed_at timestamptz not null default now(),
  subject text,
  preheader text,
  intro text,
  cta jsonb,
  html text,                                        -- rendered template (without per-subscriber footer links)
  approved_by bigint references users (id) on delete set null,
  approved_at timestamptz,
  auto_send boolean not null default false,
  preview_token uuid not null default gen_random_uuid() unique,
  stats jsonb not null default '{}',                -- sent, delivered, opened, clicked, bounced, complained, unsubscribed
  created_at timestamptz not null default now(),
  unique (brand_platform_id, send_at)
);
alter table publish_attempts add foreign key (digest_issue_id) references digest_issues (id) on delete cascade;
alter table variants add foreign key (digest_issue_id) references digest_issues (id) on delete set null;

create table digest_items (
  issue_id bigint not null references digest_issues (id) on delete cascade,
  ord int not null,
  kind text not null check (kind in ('variant', 'feed')),
  variant_id bigint references variants (id) on delete set null,
  feed_item_id bigint,
  title text not null,
  body text not null,
  link_label text,
  link_url text,
  image_asset_id bigint references assets (id) on delete set null,
  primary key (issue_id, ord)
);

-- Privacy (tz section 8): only email, status and service tokens are stored about subscribers.
create table subscribers (
  id bigint generated always as identity primary key,
  brand_id bigint not null references brands (id) on delete cascade,
  email text not null,
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'unsubscribed', 'bounced', 'complained')),
  token text not null unique default encode(gen_random_bytes(18), 'hex'),
  confirmed_at timestamptz,
  unsubscribed_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index subscribers_brand_email on subscribers (brand_id, lower(email));

create table digest_deliveries (
  issue_id bigint not null references digest_issues (id) on delete cascade,
  subscriber_id bigint not null references subscribers (id) on delete cascade,
  chunk int not null,
  status text not null default 'queued' check (status in ('queued', 'sent', 'delivered', 'opened', 'clicked', 'bounced', 'complained', 'failed')),
  esp_message_id text,
  sent_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (issue_id, subscriber_id)
);
create index digest_deliveries_esp on digest_deliveries (esp_message_id) where esp_message_id is not null;

create table feed_sources (
  id bigint generated always as identity primary key,
  brand_id bigint not null references brands (id) on delete cascade,
  url text not null,
  title text,
  is_active boolean not null default true,
  last_fetched_at timestamptz,
  last_error text,
  unique (brand_id, url)
);

create table feed_items (
  id bigint generated always as identity primary key,
  source_id bigint not null references feed_sources (id) on delete cascade,
  guid text not null,
  title text not null,
  link text,
  summary text,
  published_at timestamptz,
  embedding vector(1536),
  relevance numeric,
  used_in_issue_id bigint references digest_issues (id) on delete set null,
  created_at timestamptz not null default now(),
  unique (source_id, guid)
);
alter table digest_items add foreign key (feed_item_id) references feed_items (id) on delete set null;
