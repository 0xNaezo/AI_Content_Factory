-- Test helpers (throwaway app_test DB only, see scripts/db-test.sh): fixtures and a fake worker that plays
-- the n8n handlers with canned AI outputs, so whole scenarios run inside one transaction.
-- now() is constant inside a transaction: "time passes" by moving timestamps back (t.age) or run_after forward.

create schema if not exists t;

create table if not exists t.knobs (key text primary key, value jsonb not null);
create or replace function t.knob(p_key text, p_default jsonb) returns jsonb
language sql stable as $$ select coalesce((select value from t.knobs where key = p_key), p_default) $$;
create or replace function t.set(p_key text, p_value jsonb) returns void
language sql as $$ insert into t.knobs values (p_key, p_value) on conflict (key) do update set value = excluded.value $$;

create sequence if not exists t.update_seq start 1000;
create sequence if not exists t.message_seq start 1;

create or replace function t.eq(p_actual anyelement, p_expected anyelement, p_what text) returns void
language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'ASSERT %: expected %, got %', p_what, p_expected, p_actual;
  end if;
end $$;

create or replace function t.ok(p_cond boolean, p_what text) returns void
language plpgsql as $$
begin
  if p_cond is not true then
    raise exception 'ASSERT %', p_what;
  end if;
end $$;

-- Minimal valid profile: no required elements, so canned outputs pass the deterministic checks.
create or replace function t.profile(p_name text, p_lang text default 'en') returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'basics', jsonb_build_object('name', p_name, 'description', p_name || ' sells good things to good people.', 'niche', 'test niche',
                                 'audience', 'people who test', 'languages', jsonb_build_array(p_lang), 'timezone', 'Europe/Berlin',
                                 'website', null, 'topics', jsonb_build_array('testing', lower(p_name)), 'facts', jsonb_build_array('Open daily 8-20')),
    'voice', jsonb_build_object('tone', 'friendly', 'style', 'short sentences', 'address', 'informal', 'emoji', 'sparing',
                                'allowed_words', '[]'::jsonb, 'forbidden_words', jsonb_build_array('cheap'), 'allowed_topics', '[]'::jsonb,
                                'forbidden_topics', jsonb_build_array('politics')),
    'required_elements', jsonb_build_object(
      'cta', jsonb_build_object('phrases', '[]'::jsonb, 'platforms', '[]'::jsonb), 'links', '[]'::jsonb,
      'hashtags', jsonb_build_object('required', '[]'::jsonb, 'pool', '[]'::jsonb, 'max', 5, 'platforms', '[]'::jsonb),
      'disclaimers', '[]'::jsonb, 'signature', jsonb_build_object('text', null, 'platforms', '[]'::jsonb)),
    'visual', jsonb_build_object('palette', jsonb_build_array('#112233'), 'image_style', 'bright photo', 'logo', null, 'forbidden', '[]'::jsonb),
    'examples', jsonb_build_object('good', '[]'::jsonb, 'bad', '[]'::jsonb),
    'platforms', '{}'::jsonb,
    'digest', jsonb_build_object('title', p_name || ' weekly'))
$$;

-- Active brand with profile v1 and platforms. Posts: every day 09:00 and 18:00, max 2/day, 3 h apart.
create or replace function t.brand(p_slug text, p_platforms text[] default array['telegram', 'blog', 'email'],
                                   p_tz text default 'Europe/Berlin', p_demo boolean default false) returns bigint
language plpgsql as $$
declare
  v_id bigint;
  pl text;
begin
  insert into brands (slug, name, status, timezone, is_demo) values (p_slug, initcap(replace(p_slug, '-', ' ')), 'active', p_tz, p_demo)
  returning id into v_id;
  insert into brand_profile_versions (brand_id, version, profile, status, source)
  values (v_id, 1, t.profile(initcap(replace(p_slug, '-', ' '))), 'active', 'seed');
  foreach pl in array p_platforms loop
    insert into brand_platforms (brand_id, platform, language, mode, target, schedule)
    values (v_id, pl, 'en', case when pl in ('telegram', 'blog', 'email') then 'real' else 'preview' end,
            case pl when 'telegram' then jsonb_build_object('chat_id', '@' || replace(p_slug, '-', '_') || '_channel') else '{}'::jsonb end,
            case pl when 'email' then '{"frequency": "weekly", "day": 5, "time": "10:00"}'::jsonb
                    else '{"slots": [{"days": [1,2,3,4,5,6,7], "times": ["09:00", "18:00"]}], "max_per_day": 2, "min_interval_minutes": 180}'::jsonb end);
  end loop;
  return v_id;
end $$;

-- Telegram user (tg id = chat id), optionally a member of a brand.
create or replace function t.user(p_tg bigint, p_brand bigint default null, p_role text default null, p_admin boolean default false) returns bigint
language plpgsql as $$
declare
  v_id bigint;
begin
  insert into users (tg_user_id, tg_chat_id, tg_username, display_name, is_admin)
  values (p_tg, p_tg, 'u' || p_tg, 'User ' || p_tg, p_admin)
  on conflict (tg_user_id) do update set is_admin = users.is_admin or excluded.is_admin
  returning id into v_id;
  if p_brand is not null then
    insert into memberships (user_id, brand_id, role) values (v_id, p_brand, p_role)
    on conflict (user_id, brand_id) do update set role = excluded.role;
  end if;
  return v_id;
end $$;

create or replace function t.uid(p_tg bigint) returns bigint language sql stable as $$ select id from users where tg_user_id = p_tg $$;

-- Deliver a private message through the real webhook entry point. p_extra is merged into the message.
create or replace function t.msg(p_tg bigint, p_text text, p_extra jsonb default '{}') returns jsonb
language plpgsql as $$
begin
  return tg_ingest(jsonb_build_object('update_id', nextval('t.update_seq'), 'message',
    jsonb_strip_nulls(jsonb_build_object('message_id', nextval('t.message_seq'), 'date', extract(epoch from now())::bigint,
      'from', jsonb_build_object('id', p_tg, 'is_bot', false, 'first_name', 'User', 'username', 'u' || p_tg),
      'chat', jsonb_build_object('id', p_tg, 'type', 'private'), 'text', p_text)) || p_extra));
end $$;

create or replace function t.cb(p_tg bigint, p_data text) returns jsonb
language plpgsql as $$
begin
  return tg_ingest(jsonb_build_object('update_id', nextval('t.update_seq'), 'callback_query', jsonb_build_object(
    'id', 'cq' || currval('t.update_seq'), 'data', p_data, 'chat_instance', '1',
    'from', jsonb_build_object('id', p_tg, 'is_bot', false, 'first_name', 'User', 'username', 'u' || p_tg),
    'message', jsonb_build_object('message_id', 1, 'chat', jsonb_build_object('id', p_tg, 'type', 'private')))));
end $$;

-- The last callback answer text (what the editor sees in the toast).
create or replace function t.last_answer() returns text
language sql stable as $$ select payload ->> 'text' from outbox where kind = 'callback_answer' order by id desc limit 1 $$;

-- Latest bot text sent to a user (messages and slots).
create or replace function t.last_text(p_tg bigint) returns text
language sql stable as $$ select payload ->> 'text' from outbox where chat_id = p_tg and kind in ('message', 'slot') order by id desc limit 1 $$;

-- Move a material's glue window and all waiting jobs into the past.
create or replace function t.age(p_material bigint, p_by interval default interval '10 minutes') returns void
language sql as $$
  update materials set last_part_at = last_part_at - p_by, created_at = created_at - p_by where id = p_material;
  update jobs set run_after = run_after - p_by where material_id = p_material and status in ('queued', 'failed');
$$;

create or replace function t.last_material(p_tg bigint) returns bigint
language sql stable as $$ select max(id) from materials where author_user_id = t.uid(p_tg) and parent_material_id is null $$;

-- Process what the user sent, let the glue window pass, run the pipeline to idle. Returns the material id.
create or replace function t.flush(p_tg bigint) returns bigint
language plpgsql as $$
begin
  perform t.work();
  perform t.age(t.last_material(p_tg));
  perform t.work();
  return t.last_material(p_tg);
end $$;

-- Canned AI outputs ------------------------------------------------------------------------------

create or replace function t.fake_summary(p_material bigint) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'language', 'en',
    'main_idea', 'Idea of M-' || p_material || ': ' || left(coalesce(material_text(p_material), ''), 60),
    'key_points', jsonb_build_array('point one', 'point two'),
    'facts', jsonb_build_array(jsonb_build_object('fact', 'We open a new place', 'source_quote', 'new place')),
    'quotes', '[]'::jsonb, 'cta', null, 'links', '[]'::jsonb,
    'sufficient', t.knob('summary.sufficient', 'true'),
    'missing_info', null,
    'clarifying_question', t.knob('summary.question', '"When does it open?"') #>> '{}',
    'hints', t.knob('summary.hints', '{"brands": [], "platforms": [], "publish_at": null, "tone": null, "digest_only": false, "urgent": false}'),
    'moderation', jsonb_build_object('flagged', t.knob('summary.flagged', 'false'), 'categories', '[]'::jsonb, 'reason', 'test'))
$$;

create or replace function t.words(n int) returns text
language sql immutable as $$ select string_agg('word' || i, ' ') from generate_series(1, n) i $$;

-- Generation output that passes the deterministic checks for its platform kind (knob gen.text overrides post text).
create or replace function t.fake_output(ctx jsonb) returns jsonb
language sql stable as $$
  select case ctx ->> 'kind'
    when 'article' then jsonb_build_object('title', 'A title', 'slug', 'a-title-' || (ctx ->> 'variant_id'), 'lead', 'Lead paragraph.',
      'sections', jsonb_build_array(jsonb_build_object('heading', 'Part one', 'body_md', t.words(350)), jsonb_build_object('heading', 'Part two', 'body_md', t.words(350))),
      'seo_description', 'SEO text')
    when 'email_block' then jsonb_build_object('title', 'Block title', 'body', t.words(80), 'link_label', 'Read more')
    when 'thread' then jsonb_build_object('posts', jsonb_build_array('First post of the thread.', 'Second post.'))
    else jsonb_build_object('text', coalesce(t.knob('gen.text', 'null') #>> '{}',
                                             'Post for ' || (ctx #>> '{vars,platform}') || ' (' || coalesce(ctx #>> '{vars,mode}', '') || ')'))
  end || jsonb_build_object('headline_options', jsonb_build_array('Headline A', 'Headline B', 'Headline C'),
                            'image_brief', 'A cup of coffee on a wooden table', 'used_facts', '[]'::jsonb, 'uncertain', '[]'::jsonb)
$$;

-- Fake n8n handlers -------------------------------------------------------------------------------

create table if not exists t.table_rows (file_name text primary key, rows jsonb not null);  -- what the table parser returns
create table if not exists t.handled (job_id bigint, type text, error text);

create or replace function t.handle(p_job bigint) returns void
language plpgsql as $$
declare
  j jobs;
  ctx jsonb;
  v_mode text;
  v_chunk jsonb;
  v_items jsonb;
  n int := 0;
begin
  select * into j from jobs where id = p_job;
  -- the AI gateway refuses budget-gated work when the account is over its budget (AD-4)
  if (select budget_gated from job_types where type = j.type) then
    ctx := ai_prepare('gen.variant', coalesce(account_of(j.material_id, j.brand_id) ->> 'account_type', 'brand'), j.brand_id);
    if (ctx ->> 'blocked')::boolean then
      raise exception '%', ctx ->> 'error';
    end if;
  end if;
  if (select workflow_id from job_types where type = j.type) = 'acfSqlJob0000001' then
    perform run_sql_job(j.id);
    return;
  end if;
  case j.type
    when 'part.process' then
      ctx := part_context((j.payload ->> 'part_id')::bigint);
      if not (ctx ->> 'done')::boolean then
        if ctx ->> 'kind' = 'table' then
          perform table_split((ctx ->> 'part_id')::bigint, (select rows from t.table_rows where file_name = ctx ->> 'file_name'));
        elsif t.knob('extract.error', 'null') <> 'null' then
          perform part_extracted((ctx ->> 'part_id')::bigint, null, '{}', t.knob('extract.error', 'null') #>> '{}');
        else
          perform part_extracted((ctx ->> 'part_id')::bigint, 'Extracted ' || (ctx ->> 'kind') || ' ' || coalesce(ctx ->> 'input_text', ctx ->> 'file_name'), '{}');
        end if;
      end if;
    when 'material.summarize' then
      ctx := summarize_context(j.material_id);
      if not (ctx ->> 'skip')::boolean then
        perform save_summary(j.material_id, (ctx ->> 'revision')::int, t.fake_summary(j.material_id));
      end if;
    when 'material.route' then
      ctx := route_context(j.material_id);
      if ctx ? 'decided' then
        perform route_apply(j.material_id, array(select x::bigint from jsonb_array_elements_text(ctx -> 'decided') x), ctx ->> 'method');
      elsif ctx ? 'reject' then
        perform material_reject(j.material_id, ctx ->> 'reject');
      elsif ctx ? 'classify' then
        perform route_decide(j.material_id, t.knob('route.result', jsonb_build_object('off_topic', false, 'reason', 'test',
          'ranking', (select jsonb_agg(jsonb_build_object('brand', b ->> 'slug', 'confidence', case when i = 1 then 0.9 else 0.1 end, 'reason', 'r') order by i)
                      from jsonb_array_elements(ctx #> '{vars,brands}') with ordinality as x(b, i)))));
      end if;
    when 'variant.generate' then
      v_mode := coalesce(j.payload ->> 'mode', 'generate');
      ctx := gen_context(j.variant_id, v_mode, j.payload ->> 'comment');
      if not (ctx ->> 'skip')::boolean then
        perform save_generated(j.variant_id, v_mode, t.fake_output(ctx), j.payload ->> 'comment');
      end if;
    when 'variant.check' then
      ctx := check_context(j.variant_id);
      if not (ctx ->> 'skip')::boolean then
        perform save_checks(j.variant_id, (ctx ->> 'version')::int, '[]',
          t.knob('check.facts', jsonb_build_object('claims', '[]'::jsonb, 'language', ctx #>> '{vars,expected_language}',
                                                   'forbidden_topics', '[]'::jsonb, 'summary', 'ok')), null);
      end if;
    when 'package.visual' then
      v_mode := coalesce(j.payload ->> 'mode', 'auto');
      ctx := visual_context(j.package_id, v_mode);
      if not (ctx ->> 'skip')::boolean then
        perform save_visual(j.package_id, x #>> '{}', 'b/' || j.brand_id || '/p/' || j.package_id || '/' || replace(x #>> '{}', ':', 'x') || '-' || j.id || '.png',
                            'sha', 'image/png', 1000, 1600, 900, case when v_mode = 'upload' then 'upload' else 'generated' end)
        from jsonb_array_elements(ctx -> 'aspects') x;
        perform visual_done(j.package_id, v_mode, true, null, (j.payload ->> 'user_id')::bigint);
      end if;
    when 'digest.build' then
      ctx := digest_build_context((j.payload ->> 'issue_id')::bigint);
      if not (ctx ->> 'skip')::boolean then
        select coalesce(jsonb_agg(x - 'image_asset_id'), '[]') into v_items from jsonb_array_elements(ctx -> 'variants') x;
        perform digest_save((ctx ->> 'issue_id')::bigint,
          jsonb_build_object('subject', 'Weekly news', 'preheader', 'Pre', 'intro', 'Hello', 'cta', null), v_items,
          '<html>' || jsonb_array_length(v_items) || ' blocks <a href="{{unsubscribe_url}}">unsubscribe</a></html>');
      end if;
    when 'digest.send' then
      v_chunk := digest_next_chunk((j.payload ->> 'issue_id')::bigint);
      while not coalesce((v_chunk ->> 'done')::boolean, true) and n < 100 loop
        n := n + 1;
        v_chunk := digest_chunk_result((v_chunk ->> 'issue_id')::bigint, (v_chunk ->> 'chunk')::int,
          jsonb_build_object('data', (select jsonb_agg(jsonb_build_object('id', 'esp-' || (v_chunk ->> 'issue_id') || '-' || (e ->> 'to'))) from jsonb_array_elements(v_chunk -> 'emails') e)));
      end loop;
    else
      null;  -- feeds, ESP events, onboarding, profile IO, guest brand, health, housekeeping: covered by their own tests
  end case;
end $$;

-- Run ready jobs one by one until the queue is idle (or p_max jobs). Errors go to job_failed, like the n8n runner.
create or replace function t.work(p_max int default 500) returns int
language plpgsql as $$
declare
  j record;
  n int := 0;
begin
  loop
    select * into j from claim_jobs(1) limit 1;
    exit when j.id is null;
    n := n + 1;
    if n > p_max then
      raise exception 't.work: more than % jobs, loop?', p_max;
    end if;
    begin
      perform t.handle(j.id);
      perform job_done(j.id);
      insert into t.handled values (j.id, j.type, null);
    exception when others then
      insert into t.handled values (j.id, j.type, sqlerrm);
      perform job_failed(j.id, sqlerrm);
    end;
  end loop;
  return n;
end $$;

-- Publisher tick with a fake adapter: telegram answers p_outcome (ok by default), blog/preview are local.
create or replace function t.publish(p_outcome text default 'ok') returns int
language plpgsql as $$
declare
  r record;
  n int := 0;
begin
  for r in select * from claim_publications(50) loop
    n := n + 1;
    if r.adapter in ('blog', 'preview') then
      perform publish_local(r.attempt_id);
    elsif p_outcome = 'ok' then
      perform publish_result(r.attempt_id, 'ok', 200, (r.request ->> 'chat_id') || ':' || (100 + r.attempt_id), 'https://t.me/c/' || r.attempt_id);
    elsif p_outcome = 'failed' then
      perform publish_result(r.attempt_id, 'failed', 500, null, null, 'Internal Server Error');
    else
      null;  -- 'crash': no result recorded, the attempt stays pending
    end if;
  end loop;
  return n;
end $$;

-- Fail loudly if any handled job errored (optionally ignoring a pattern).
create or replace function t.no_errors(p_ignore text default null) returns void
language plpgsql as $$
declare
  e text;
begin
  select string_agg(type || ': ' || error, E'\n') into e from t.handled
  where error is not null and (p_ignore is null or error not like p_ignore);
  if e is not null then
    raise exception 'job errors:%', E'\n' || e;
  end if;
end $$;

grant usage on schema t to app_n8n, app_web;
grant all on all tables in schema t to app_n8n;
grant all on all sequences in schema t to app_n8n;
grant execute on all functions in schema t to app_n8n, app_web;

-- Placeholder prompts for routes whose prompt files are not synced (ai_prepare refuses unsynced prompts).
insert into prompts (route, version_hash, template)
select distinct prompt_route, 'test', '<<<user>>>test' from ai_routes where prompt_route is not null
on conflict do nothing;
