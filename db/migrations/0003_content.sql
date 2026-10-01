-- Content pipeline: materials -> extracts -> packages -> variants -> versions -> checks.

create table materials (
  id bigint generated always as identity primary key,
  author_user_id bigint references users (id) on delete set null,
  source text not null check (source in ('telegram', 'email', 'table_row', 'eval')),
  status text not null default 'received'
    check (status in ('received', 'parsed', 'awaiting_author', 'routed', 'rejected')),
  status_changed_at timestamptz not null default now(),
  is_guest boolean not null default false,
  is_eval boolean not null default false,
  is_container boolean not null default false,      -- table file split into row materials (IN-9)
  parent_material_id bigint references materials (id) on delete cascade,
  row_number int,
  chat_id bigint,                                   -- where to answer (Telegram)
  reply_email text,                                 -- where to answer (email source)
  -- author hints from buttons/table: {"brand_ids":[..],"platforms":[..],"publish_at_local":"YYYY-MM-DDTHH:MM","digest_only":bool,"urgent":bool}
  hints jsonb not null default '{}',
  question jsonb,                                   -- pending question to the author
  low_data boolean not null default false,          -- EX-3: generated without enough source data
  revision int not null default 1,                  -- bumps when the author adds a clarification
  text_hash text,                                   -- normalized text hash (IN-6 exact duplicates)
  duplicate_of bigint references materials (id) on delete set null,
  reject_reason text,
  eval_case_id text,
  sealed_at timestamptz,                            -- no more parts are glued (IN-5)
  last_part_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (parent_material_id, row_number)
);
create index materials_author on materials (author_user_id, created_at desc);
create index materials_hash on materials (text_hash) where text_hash is not null;

create table material_parts (
  id bigint generated always as identity primary key,
  material_id bigint not null references materials (id) on delete cascade,
  kind text not null check (kind in ('text', 'voice', 'audio', 'image', 'pdf', 'docx', 'table', 'url', 'clarification')),
  ord int not null default 0,
  inbound_event_id bigint references inbound_events (id) on delete set null,
  source_ref text not null,                         -- natural key inside the material: tg message id + slot, email attachment id...
  tg_file_id text,
  tg_file_unique_id text,
  media_group_id text,
  file_name text,
  mime text,
  size_bytes bigint,
  duration_s int,
  url text,
  input_text text,                                  -- text/caption/url as received
  asset_id bigint references assets (id) on delete set null,
  extracted_text text,
  extract_meta jsonb not null default '{}',         -- pages, rows, duration, title...
  extracted_at timestamptz,
  error text,
  created_at timestamptz not null default now(),
  unique (material_id, source_ref)
);
create index material_parts_unique_file on material_parts (tg_file_unique_id) where tg_file_unique_id is not null;
alter table assets add foreign key (material_id) references materials (id) on delete set null;

create table material_extracts (
  material_id bigint primary key references materials (id) on delete cascade,
  revision int not null,
  text text not null,
  text_prefix text not null,                        -- first 4000 chars, trigram-indexed for near duplicates
  language text,
  summary jsonb not null,
  sufficient boolean not null,
  created_at timestamptz not null default now()
);
create index material_extracts_trgm on material_extracts using gin (text_prefix gin_trgm_ops);

create table material_routes (
  material_id bigint not null references materials (id) on delete cascade,
  brand_id bigint not null references brands (id) on delete cascade,
  method text not null check (method in ('hint', 'single_brand', 'classifier', 'author_choice', 'redirect', 'guest', 'table', 'eval')),
  confidence numeric,
  decided_by bigint references users (id) on delete set null,
  ranking jsonb,
  created_at timestamptz not null default now(),
  primary key (material_id, brand_id)
);

create table packages (
  id bigint generated always as identity primary key,
  material_id bigint not null references materials (id) on delete cascade,
  brand_id bigint not null references brands (id) on delete cascade,
  profile_version int not null,
  is_guest boolean not null default false,
  is_eval boolean not null default false,
  low_data boolean not null default false,
  redirected_from bigint references packages (id) on delete set null,
  image_brief jsonb,
  visual_status text not null default 'pending' check (visual_status in ('pending', 'done', 'failed', 'skipped')),
  visual_note text,
  visual_attempt int not null default 0,
  card_sent_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (brand_id, profile_version) references brand_profile_versions (brand_id, version)
);
create unique index packages_one_live on packages (material_id, brand_id) where cancelled_at is null;

create table package_visuals (
  package_id bigint not null references packages (id) on delete cascade,
  aspect text not null check (aspect in ('16:9', '1:1', '4:5')),
  asset_id bigint not null references assets (id),
  origin text not null check (origin in ('source', 'generated', 'upload')),
  check_result jsonb,
  ok boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (package_id, aspect)
);

create table variants (
  id bigint generated always as identity primary key,
  package_id bigint not null references packages (id) on delete cascade,
  brand_platform_id bigint not null references brand_platforms (id),
  platform text not null,
  status text not null default 'draft'
    check (status in ('draft', 'pending_approval', 'revising', 'approved', 'scheduled', 'rescheduled',
                      'publishing', 'failed', 'published', 'rejected', 'cancelled')),
  status_changed_at timestamptz not null default now(),
  current_version int not null default 0,
  check_status text not null default 'pending' check (check_status in ('pending', 'passed', 'warned', 'failed')),
  fix_attempts int not null default 0,
  slot_hint_at timestamptz,                         -- author asked for this time (PB-1)
  proposed_at timestamptz,                          -- soft-reserved slot shown on the card (AP-1)
  scheduled_at timestamptz,
  urgent boolean not null default false,
  approved_by bigint references users (id) on delete set null,
  approved_at timestamptz,
  auto_approved boolean not null default false,
  publish_first_attempt_at timestamptz,
  next_attempt_at timestamptz,
  published_at timestamptz,
  external_id text,
  external_url text,
  external_deleted_at timestamptz,
  digest_issue_id bigint,
  preview_token uuid not null default gen_random_uuid() unique,
  embedding vector(1536),
  metrics jsonb not null default '{}',              -- platform metrics (reactions, views, clicks)
  created_at timestamptz not null default now(),
  unique (package_id, brand_platform_id)
);
create index variants_due on variants (scheduled_at) where status = 'scheduled';
create index variants_status on variants (status);
create index variants_bp_time on variants (brand_platform_id, scheduled_at);

create table variant_versions (
  variant_id bigint not null references variants (id) on delete cascade,
  version int not null,
  content jsonb not null,                           -- normalized per platform kind (post/thread/article/email_block)
  plain_text text not null,
  headline_options jsonb not null default '[]',
  image_brief text,
  visual_asset_id bigint references assets (id) on delete set null,  -- explicit visual; null = package visual for the aspect
  used_facts jsonb not null default '[]',
  uncertain jsonb not null default '[]',
  author_kind text not null check (author_kind in ('ai', 'human')),
  author_user_id bigint references users (id) on delete set null,
  reason text not null check (reason in ('generate', 'fix', 'redo', 'edit', 'headline', 'visual', 'edit_published')),
  comment text,
  created_at timestamptz not null default now(),
  primary key (variant_id, version)
);

create table check_results (
  variant_id bigint not null references variants (id) on delete cascade,
  version int not null,
  check_name text not null,
  status text not null check (status in ('pass', 'warn', 'fail')),
  required boolean not null,
  details jsonb not null default '{}',
  created_at timestamptz not null default now(),
  primary key (variant_id, version, check_name)
);

-- AP-4: editor feedback that shapes future generations; managers can review and delete.
create table feedback_examples (
  id bigint generated always as identity primary key,
  brand_id bigint not null references brands (id) on delete cascade,
  platform text,
  kind text not null check (kind in ('example', 'antiexample', 'guidance')),
  source text not null check (source in ('edit', 'redo', 'reject')),
  variant_id bigint references variants (id) on delete set null,
  before_text text,
  after_text text,
  comment text,
  created_by bigint references users (id) on delete set null,
  deleted_at timestamptz,
  deleted_by bigint references users (id) on delete set null,
  created_at timestamptz not null default now()
);
create index feedback_brand on feedback_examples (brand_id, created_at desc) where deleted_at is null;

-- Which variant each editor currently sees on the compact card.
create table card_views (
  package_id bigint not null references packages (id) on delete cascade,
  user_id bigint not null references users (id) on delete cascade,
  variant_id bigint references variants (id) on delete set null,
  menu text not null default 'main',
  primary key (package_id, user_id)
);

-- BP-3 onboarding: sample posts collected before the draft profile is generated.
create table onboarding_samples (
  id bigint generated always as identity primary key,
  brand_id bigint not null references brands (id) on delete cascade,
  kind text not null check (kind in ('text', 'url')),
  content text not null,
  extracted_text text,
  created_by bigint references users (id) on delete set null,
  created_at timestamptz not null default now()
);

alter table jobs add foreign key (material_id) references materials (id) on delete cascade;
alter table jobs add foreign key (package_id) references packages (id) on delete cascade;
alter table jobs add foreign key (variant_id) references variants (id) on delete cascade;
alter table jobs add foreign key (brand_id) references brands (id) on delete cascade;
