-- AI gateway data (routes, prices, prompts, usage), web panel service data, eval runs.

create table ai_routes (
  route text primary key,
  provider text not null check (provider in ('anthropic', 'openrouter')),
  kind text not null check (kind in ('text', 'stt', 'image', 'embedding')),
  model text not null,
  params jsonb not null default '{}',               -- effort, max_tokens, aspect defaults...
  prompt_route text,                                -- prompts.route; null = no prompt (stt/embedding/image use vars)
  schema_name text,                                 -- structured output schema (prompts/schemas); null = plain text
  enabled boolean not null default true,
  updated_at timestamptz not null default now()
);

create table ai_prices (
  provider text not null,
  model text not null,
  unit text not null check (unit in ('mtok_in', 'mtok_out', 'mtok_cache_write', 'mtok_cache_read')),
  usd numeric(12, 6) not null,
  primary key (provider, model, unit)
);

-- Prompt templates and response schemas, synced from prompts/ by scripts/sync-config.sh.
create table prompts (
  route text not null,
  version_hash text not null,
  template text not null,
  is_current boolean not null default true,
  synced_at timestamptz not null default now(),
  primary key (route, version_hash)
);
create unique index prompts_current on prompts (route) where is_current;

create table ai_schemas (
  name text primary key,
  schema jsonb not null,
  version_hash text not null,
  synced_at timestamptz not null default now()
);

-- Every AI call (success or failure): cost, trace refs, prompt version (GN-8, AD-4, tz section 8 tracing).
create table ai_usage (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  account_type text not null check (account_type in ('brand', 'guest', 'eval', 'system')),
  brand_id bigint references brands (id) on delete set null,
  material_id bigint references materials (id) on delete set null,
  package_id bigint references packages (id) on delete set null,
  variant_id bigint references variants (id) on delete set null,
  job_id bigint,
  route text not null,
  provider text not null,
  model text not null,
  prompt_hash text,
  status text not null check (status in ('ok', 'error', 'refused', 'invalid', 'budget')),
  stop_reason text,
  input_tokens int not null default 0,
  output_tokens int not null default 0,
  cache_write_tokens int not null default 0,
  cache_read_tokens int not null default 0,
  units jsonb not null default '{}',                -- seconds of audio, images...
  cost_usd numeric(12, 6) not null default 0,
  latency_ms int,
  error text
);
create index ai_usage_material on ai_usage (material_id) where material_id is not null;
create index ai_usage_package on ai_usage (package_id) where package_id is not null;
create index ai_usage_account_month on ai_usage (account_type, brand_id, at);

-- Web panel: magic-link login (issued by the bot) and sessions. Only hashes are stored.
create table panel_login_tokens (
  token_hash bytea primary key,
  user_id bigint not null references users (id) on delete cascade,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);

create table web_sessions (
  token_hash bytea primary key,
  user_id bigint not null references users (id) on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

-- Cookie-less blog counters (tz 7.9): page views per day, clicks through redirect links.
create table web_page_views (
  day date not null,
  brand_id bigint not null references brands (id) on delete cascade,
  path text not null,
  variant_id bigint references variants (id) on delete cascade,
  views int not null default 0,
  primary key (day, brand_id, path)
);

create table web_link_clicks (
  day date not null,
  brand_id bigint not null references brands (id) on delete cascade,
  variant_id bigint references variants (id) on delete cascade,
  url text not null,
  clicks int not null default 0,
  primary key (day, brand_id, url)
);

-- Quality (tz section 8, architecture 8.6): reference set and run results.
create table eval_cases (
  id text primary key,
  brand_slug text not null,
  kind text not null check (kind in ('generation', 'routing')),
  material jsonb not null,                          -- {"text": "..."} or {"url": "..."}
  expected jsonb not null default '{}',             -- {"brand": "...", "facts": [...], "forbidden_claims": [...]}
  synced_at timestamptz not null default now()
);

create table eval_runs (
  id bigint generated always as identity primary key,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'running' check (status in ('running', 'done', 'failed')),
  note text,
  config jsonb not null default '{}',               -- routes/models/prompt hashes at run time
  metrics jsonb not null default '{}'
);

create table eval_results (
  run_id bigint not null references eval_runs (id) on delete cascade,
  case_id text not null references eval_cases (id) on delete cascade,
  material_id bigint references materials (id) on delete set null,
  metrics jsonb not null default '{}',
  primary key (run_id, case_id)
);
