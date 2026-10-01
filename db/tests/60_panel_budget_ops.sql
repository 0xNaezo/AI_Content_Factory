-- Panel isolation (tz 7.11), AI budget (AD-4), brand profile YAML versions (BP-2), eval (8.6), cron/health/housekeeping.
begin;
-- temp helpers first, as the superuser: like in production, the app roles have no TEMP privilege

create temporary table ctx (k text primary key, v text) on commit drop;
grant all on ctx to app_n8n, app_web;
set local role app_n8n;

do $$
declare
  ba bigint := t.brand('alpha');
  bb bigint := t.brand('beta');
  m bigint;
begin
  perform t.user(6001, ba, 'editor');
  perform t.user(6002, bb, 'editor');
  perform t.user(6003, ba, 'author');
  perform t.user(6004, null, null, true);
  perform t.msg(6001, 'Alpha secret launch plan for the spring collection.');
  perform t.flush(6001);
  perform t.msg(6002, 'Beta confidential numbers for the quarter ahead.');
  perform t.flush(6002);
  perform t.msg(6003, 'Alpha author note about a small event on Sunday morning.');
  m := t.flush(6003);
  perform t.no_errors();
  insert into ctx values ('ba', ba), ('bb', bb), ('m_author', m);
  insert into ctx select 'login_' || x, (select panel_link(t.uid(x))) from unnest(array[6001, 6002, 6003, 6004]) x;
end $$;

-- the web role sees only site/panel objects; rows are filtered by the session user
reset role;
set local role app_web;
do $$
declare
  s text;
  u bigint;
begin
  begin
    perform count(*) from materials;
    raise exception 'web role can read base tables';
  exception when insufficient_privilege then null;
  end;
  begin
    perform tg_ingest('{}');
    raise exception 'web role can call business functions';
  exception when insufficient_privilege then null;
  end;

  -- magic link: one-time
  select l.session_token, l.user_id into s, u from panel.login(substring((select v from ctx where k = 'login_6001') from 'token=([a-f0-9]+)')) l;
  perform t.ok(s is not null, 'login with magic link');
  perform t.eq((select count(*) from panel.login(substring((select v from ctx where k = 'login_6001') from 'token=([a-f0-9]+)')))::int, 0, 'magic link is single-use');
  perform t.eq(panel.session_user(s), u, 'session resolves to the user');

  perform set_config('app.user_id', u::text, true);
  perform t.eq((select array_agg(slug order by slug) from panel.brands), array['alpha'], 'editor A sees brand A only');
  perform t.ok((select count(*) from panel.materials) = 2, 'editor A sees both alpha materials');
  perform t.ok(not exists (select 1 from panel.materials where main_idea like '%Beta%'), 'no beta materials');
  perform t.ok(not exists (select 1 from panel.variants where brand_id = (select v::bigint from ctx where k = 'bb')), 'no beta variants');
  perform t.ok(not exists (select 1 from panel.audit where brand_id = (select v::bigint from ctx where k = 'bb')), 'no beta audit');
  perform t.ok(not exists (select 1 from panel.material_events e where e.material_id not in (select id from panel.materials)), 'events follow material visibility');

  perform set_config('app.user_id', '', true);  -- nobody
  perform t.eq((select count(*) from panel.materials)::int, 0, 'no user -> nothing');

  select l.user_id into u from panel.login(substring((select v from ctx where k = 'login_6003') from 'token=([a-f0-9]+)')) l;
  perform set_config('app.user_id', u::text, true);
  perform t.eq((select count(*) from panel.materials)::int, 1, 'author sees only own materials');
  perform t.eq((select count(*) from panel.digests)::int, 0, 'author has no digest access');

  select l.user_id into u from panel.login(substring((select v from ctx where k = 'login_6004') from 'token=([a-f0-9]+)')) l;
  perform set_config('app.user_id', u::text, true);
  perform t.eq((select count(*) from panel.brands)::int, 2, 'admin sees all brands');

  -- public site: only published blog posts, previews by token
  perform t.eq((select count(*) from site.posts)::int, 0, 'nothing published yet');
  perform t.ok((select count(*) from site.brands) = 2, 'public brand list');
  perform t.eq((select count(*) from site.case_stats)::int, 1, 'case page numbers readable by the web role');
end $$;
reset role;
set local role app_n8n;

-- revocation is immediate for panel sessions
do $$
declare
  s text;
begin
  select l.session_token into s from panel.login(substring((select v from ctx where k = 'login_6002') from 'token=([a-f0-9]+)')) l;
  perform t.ok(panel.session_user(s) is not null, 'session works');
  delete from memberships where user_id = t.uid(6002);
  perform t.eq(panel.session_user(s), null::bigint, 'no access -> session rejected');
end $$;

-- budget (AD-4): blocked calls never reach the provider, jobs wait, author told once, raising the budget unblocks
do $$
declare
  ba bigint := (select v::bigint from ctx where k = 'ba');
  r jsonb;
  m bigint;
begin
  update brands set monthly_budget_usd = 1 where id = ba;
  r := ai_prepare('gen.variant', 'brand', ba);
  perform t.eq(r ->> 'blocked', 'false', 'within budget');
  perform t.eq(r ->> 'model', 'claude-opus-5-5', 'default model');
  r := ai_record(jsonb_build_object('route', 'gen.variant', 'provider', 'anthropic', 'model', 'claude-opus-5-5', 'account_type', 'brand',
                                    'brand_id', ba, 'input_tokens', 100000, 'output_tokens', 20000));
  perform t.eq((r ->> 'cost_usd')::numeric, 0.8::numeric, 'cost from list prices (0.1M in x $4 + 0.02M out x $20)');
  perform t.ok(exists (select 1 from outbox where payload ->> 'text' like '%$0.80%'), '80% warning');
  perform ai_record(jsonb_build_object('route', 'gen.variant', 'provider', 'anthropic', 'model', 'claude-opus-5-5', 'account_type', 'brand',
                                       'brand_id', ba, 'input_tokens', 100000));
  r := ai_prepare('gen.variant', 'brand', ba);
  perform t.eq(r ->> 'blocked', 'true', 'blocked at 100%');
  perform t.ok(r ->> 'error' like 'budget_exceeded:brand:' || ba || ':%', 'error code routes the job to blocked');

  perform t.msg(6001, 'Alpha new material while the budget is exhausted.');
  m := t.flush(6001);
  perform t.ok(exists (select 1 from jobs where material_id = m and status = 'blocked'), 'generation blocked');
  perform t.eq((select status from materials where id = m), 'routed', 'intake and routing continue');
  perform t.eq((select count(*) from outbox where dedupe_key = 'blocked:' || m)::int, 1, 'author told once');
  perform t.msg(6004, '/budget alpha 100');
  perform t.work();
  perform t.no_errors('budget_exceeded%');
  perform t.eq((select count(*) from jobs where material_id = m and status = 'blocked')::int, 0, 'raised budget unblocks');
  perform t.ok(exists (select 1 from variants v join packages p on p.id = v.package_id where p.material_id = m and v.status = 'pending_approval'),
               'generation finished after unblocking');
  delete from t.handled;
end $$;

-- brand profile as YAML (BP-2): invalid upload explained; valid -> draft; activation applies platforms, versions kept
do $$
declare
  ba bigint := (select v::bigint from ctx where k = 'ba');
  mgr bigint := t.user(6010, ba, 'manager');
  cfg jsonb := brand_config(ba);
  r jsonb;
  pkg_version int;
begin
  r := profile_import(ba, mgr, cfg || jsonb_build_object('platforms', jsonb_build_array(jsonb_build_object('platform', 'linkedin', 'language', 'en', 'mode', 'real'))), '[]');
  perform t.eq(r ->> 'ok', 'false', 'real LinkedIn refused (MVP boundary)');
  r := profile_import(ba, mgr, cfg, '["basics.description: must be at least 10 characters"]');
  perform t.eq(r ->> 'ok', 'false', 'schema errors reported');
  perform t.ok(t.last_text(6010) like '%basics.description%', 'errors shown to the manager');
  r := profile_import(ba, mgr, jsonb_set(jsonb_set(cfg, '{profile,voice,tone}', '"bold"'), '{platforms}',
                      (cfg -> 'platforms') || jsonb_build_array(jsonb_build_object('platform', 'x', 'language', 'en', 'mode', 'preview', 'active', true))), '[]');
  perform t.eq(r ->> 'ok', 'true', 'valid config -> draft');
  perform t.eq((select status from brand_profile_versions where brand_id = ba and version = 2), 'draft', 'draft v2');
  pkg_version := (select profile_version from packages where brand_id = ba order by id limit 1);
  perform t.cb(6010, 'pa:' || ba || ':2');
  perform t.work();
  perform t.no_errors();
  perform t.eq((select version from brand_profile_versions where brand_id = ba and status = 'active'), 2, 'v2 active');
  perform t.eq((select status from brand_profile_versions where brand_id = ba and version = 1), 'superseded', 'v1 kept as superseded');
  perform t.eq(active_profile(ba) #>> '{voice,tone}', 'bold', 'new voice');
  perform t.ok(exists (select 1 from brand_platforms where brand_id = ba and platform = 'x' and mode = 'preview'), 'new platform added');
  perform t.eq((select profile_version from packages where brand_id = ba order by id limit 1), pkg_version, 'old packages keep their profile version');
  perform t.cb(6001, 'pa:' || ba || ':1');
  perform t.work();
  perform t.eq((select version from brand_profile_versions where brand_id = ba and status = 'active'), 2, 'editor cannot activate');
end $$;

-- eval (8.6): a run goes through the real steps, never gets cards or real publications, metrics computed
do $$
declare
  r jsonb;
  run bigint;
begin
  update brands set is_demo = true where slug in ('alpha', 'beta');
  delete from eval_cases;  -- the synced reference set targets the seed brands, not this test's
  insert into eval_cases (id, brand_slug, kind, material, expected) values
    ('g1', 'alpha', 'generation', '{"text": "Alpha opens a pop-up store on Saturday."}', '{"facts": ["Saturday"], "forbidden_claims": ["free"]}'),
    ('r1', 'beta', 'routing', '{"text": "Beta quarterly webinar for customers."}', '{"brand": "alpha"}');
  r := eval_start('test run');
  run := (r ->> 'run_id')::bigint;
  perform t.eq((r ->> 'cases')::int, 2, 'two cases');
  perform t.work();
  perform t.no_errors();
  perform t.eq((select status from eval_runs where id = run), 'done', 'run finished');
  perform t.eq((select (metrics ->> 'routing_accuracy')::numeric from eval_runs where id = run), 1.000, 'routing case scored');
  perform t.ok((select (metrics ->> 'variants')::int from eval_runs where id = run) > 0, 'generation case produced variants');
  perform t.ok(not exists (select 1 from packages p where p.is_eval and p.card_sent_at is not null), 'no cards for eval');
  perform t.ok(not exists (select 1 from variants v join packages p on p.id = v.package_id where p.is_eval and v.status in ('scheduled', 'published')),
               'eval variants are never scheduled');
end $$;

-- cron tick, health, housekeeping
do $$
declare
  r jsonb;
begin
  perform cron_tick();
  perform cron_tick();
  perform t.eq((select count(*) from jobs where type = 'health.check')::int, 1, 'health enqueued once per 5 minutes');
  perform t.ok(exists (select 1 from digest_issues where brand_id = (select v::bigint from ctx where k = 'ba')), 'digest planned by cron');
  update settings set value = '0' where key = 'health.queue_depth_alert';
  perform enqueue_job('report.weekly', '{}', p_dedupe => 'x');
  r := health_check();
  perform t.eq(r ->> 'ok', 'false', 'queue depth alert');
  perform t.ok(exists (select 1 from outbox where chat_id = 6004 and payload ->> 'text' like '%queue depth%'), 'admin alerted');
end $$;

do $$
declare
  r jsonb;
  g bigint;
begin
  g := (guest_brand_create(t.uid(6003), t.profile('Guest Biz')) ->> 'brand_id')::bigint;
  perform t.ok((select is_temporary from brands where id = g), 'temporary guest brand');
  update brands set expires_at = now() - interval '1 minute' where id = g;
  insert into assets (s3_key, mime, origin, brand_id) values ('b/guest/x.png', 'image/png', 'generated', g);
  r := housekeeping();
  perform t.ok(r -> 's3_keys' ? 'b/guest/x.png', 'S3 keys returned for deletion');
  perform t.ok(not exists (select 1 from brands where id = g), 'expired guest brand deleted');
end $$;

rollback;
