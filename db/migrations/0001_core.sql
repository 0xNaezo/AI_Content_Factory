-- Core entities: brands, users and access, settings, templates, assets, audit.
-- Statuses are text + CHECK; transitions go through transition() (db/functions/00_util.sql).

create function is_timezone(tz text) returns boolean language plpgsql immutable as $$
begin
  perform now() at time zone tz;
  return true;
exception when others then
  return false;
end $$;

create table brands (
  id bigint generated always as identity primary key,
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,39}$'),
  name text not null,
  status text not null default 'draft' check (status in ('draft', 'active', 'archived')),
  timezone text not null default 'UTC' check (is_timezone(timezone)),
  is_demo boolean not null default false,
  is_temporary boolean not null default false,      -- guest brand built from a one-line description
  expires_at timestamptz,
  owner_user_id bigint,
  monthly_budget_usd numeric(10, 2) not null default 50 check (monthly_budget_usd >= 0),
  blog_domain text unique,                           -- host that serves this brand's blog
  created_at timestamptz not null default now()
);

create table users (
  id bigint generated always as identity primary key,
  tg_user_id bigint unique,
  tg_chat_id bigint,
  tg_username text,
  display_name text not null default '',
  email text,
  is_admin boolean not null default false,
  status text not null default 'active' check (status in ('active', 'blocked')),
  guest_enabled boolean not null default false,
  guest_brand_id bigint references brands (id) on delete set null,
  intake_token text not null unique default encode(gen_random_bytes(8), 'hex'),  -- personal email intake address
  tg_blocked_bot boolean not null default false,
  notify_published text not null default 'batch' check (notify_published in ('each', 'batch', 'off')),
  is_system boolean not null default false,          -- service accounts (eval runner)
  created_at timestamptz not null default now(),
  last_seen_at timestamptz
);
create unique index users_email_uq on users (lower(email)) where email is not null;
alter table brands add foreign key (owner_user_id) references users (id) on delete set null;

create table memberships (
  user_id bigint not null references users (id) on delete cascade,
  brand_id bigint not null references brands (id) on delete cascade,
  role text not null check (role in ('manager', 'editor', 'author', 'viewer')),
  granted_by bigint references users (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (user_id, brand_id)
);
create index memberships_brand on memberships (brand_id);

create table invites (
  id bigint generated always as identity primary key,
  token_hash bytea not null unique,
  role text not null check (role in ('admin', 'manager', 'editor', 'author', 'viewer')),
  brand_ids bigint[] not null default '{}',
  created_by bigint references users (id) on delete set null,
  expires_at timestamptz not null,
  used_at timestamptz,
  used_by bigint references users (id) on delete set null,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  check (role = 'admin' or cardinality(brand_ids) > 0)
);

create table brand_profile_versions (
  brand_id bigint not null references brands (id) on delete cascade,
  version int not null,
  profile jsonb not null,
  -- operational part of the brand YAML applied on activation: brand fields, platforms, feeds
  config jsonb not null default '{}',
  status text not null check (status in ('draft', 'active', 'superseded', 'discarded')),
  source text not null check (source in ('seed', 'onboarding', 'yaml', 'guest', 'system')),
  note text,
  created_by bigint references users (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (brand_id, version)
);
create unique index brand_profile_one_active on brand_profile_versions (brand_id) where status = 'active';

create table brand_platforms (
  id bigint generated always as identity primary key,
  brand_id bigint not null references brands (id) on delete cascade,
  platform text not null check (platform in ('telegram', 'blog', 'email', 'linkedin', 'instagram', 'facebook', 'x')),
  language text not null check (language ~ '^[a-z]{2}$'),
  mode text not null check (mode in ('real', 'preview')),
  is_active boolean not null default true,
  auto_publish boolean not null default false,
  -- telegram: {"chat_id": "@channel"}; email: {"from_name": "...", "reply_to": "..."}
  target jsonb not null default '{}',
  -- posts: {"slots":[{"days":[1,2,3,4,5],"times":["09:00","18:00"]}],"max_per_day":2,"min_interval_minutes":120}
  -- email: {"frequency":"weekly","day":5,"time":"10:00","auto_send":false}
  schedule jsonb not null default '{}',
  created_at timestamptz not null default now(),
  unique (brand_id, platform, language),
  -- MVP boundary (tz section 4): social networks run in preview mode only
  check (platform in ('telegram', 'blog', 'email') or mode = 'preview')
);

create table settings (
  key text not null,
  brand_id bigint references brands (id) on delete cascade,   -- null = global default
  value jsonb not null,
  description text,
  updated_at timestamptz not null default now(),
  updated_by bigint references users (id) on delete set null
);
create unique index settings_key_uq on settings (key, coalesce(brand_id, 0));

create table templates (
  key text primary key,
  body text not null,
  updated_at timestamptz not null default now()
);

create table platform_formats (
  platform text primary key,
  spec jsonb not null
);

create table assets (
  id bigint generated always as identity primary key,
  s3_key text not null unique,
  sha256 text,
  mime text not null,
  bytes bigint,
  width int,
  height int,
  origin text not null check (origin in ('telegram', 'email', 'generated', 'derived', 'upload', 'system')),
  brand_id bigint references brands (id) on delete set null,
  material_id bigint,
  parent_asset_id bigint references assets (id) on delete set null,
  aspect text,
  tg_file_id text,
  created_at timestamptz not null default now()
);
create unique index assets_derived_uq on assets (parent_asset_id, aspect) where parent_asset_id is not null and origin = 'derived';

-- Append-only audit (AD-3). UPDATE/DELETE/TRUNCATE are blocked by triggers and grants.
create table audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor_user_id bigint,           -- null = system
  action text not null,
  entity text,
  entity_id bigint,
  brand_id bigint,
  material_id bigint,
  data jsonb not null default '{}'
);
create index audit_material on audit_log (material_id, at) where material_id is not null;
create index audit_brand on audit_log (brand_id, at);
create index audit_entity on audit_log (entity, entity_id);

create function forbid_audit_change() returns trigger language plpgsql as $$
begin
  raise exception 'audit_log is append-only';
end $$;
create trigger audit_log_no_update before update or delete on audit_log for each statement execute function forbid_audit_change();
create trigger audit_log_no_truncate before truncate on audit_log for each statement execute function forbid_audit_change();

-- Allowed status transitions (tz section 7). Seeded in db/functions/05_config.sql.
create table status_graph (
  entity text not null,
  from_status text not null,
  to_status text not null,
  primary key (entity, from_status, to_status)
);
