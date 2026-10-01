-- Approval (AP-1..AP-7, RT-5), scheduling (PB-1, PB-2), publishing at most once (PB-3..PB-6), pauses (PB-9).
begin;
-- temp helpers first, as the superuser: like in production, the app roles have no TEMP privilege

create temporary table ids (k text primary key, v bigint) on commit drop;
grant all on ids to app_n8n;
create function pg_temp.id(p text) returns bigint language sql as $$ select v from ids where k = p $$;
create function pg_temp.var(p_material bigint, p_platform text) returns bigint language sql as $$
  select v.id from variants v join packages p on p.id = v.package_id where p.material_id = p_material and v.platform = p_platform and p.cancelled_at is null $$;
set local role app_n8n;

do $$
declare
  b bigint := t.brand('shop');
  b2 bigint := t.brand('outlet', array['telegram']);
  m bigint;
begin
  perform t.user(3001, b, 'author');
  perform t.user(3002, b, 'editor');
  perform t.user(3002, b2, 'editor');
  perform t.user(3003, b, 'manager');
  perform t.user(3004, b, 'viewer');
  perform t.msg(3001, 'Summer sale: all jackets 30% off until Sunday.');
  m := t.flush(3001);
  perform t.no_errors();
  insert into ids values ('b', b), ('b2', b2), ('m', m), ('pkg', (select id from packages where material_id = m));
end $$;

-- approve from the card: one editor is enough (AP-7), the variant gets a slot from the schedule (PB-1)
do $$
declare
  v bigint := pg_temp.var(pg_temp.id('m'), 'telegram');
  r variants;
begin
  perform t.cb(3004, 'ap:' || v || ':1');  -- viewer can't approve
  perform t.work();
  perform t.eq((select status from variants where id = v), 'pending_approval', 'viewer cannot approve');
  perform t.cb(3002, 'ap:' || v || ':1');
  perform t.work();
  perform t.no_errors();
  select * into r from variants where id = v;
  perform t.eq(r.status, 'scheduled', 'approved -> scheduled');
  perform t.eq(r.approved_by, t.uid(3002), 'approved by the editor');
  perform t.ok(to_char(r.scheduled_at at time zone 'Europe/Berlin', 'HH24:MI') in ('09:00', '18:00'), 'scheduled into a slot: ' || r.scheduled_at);
  perform t.eq(r.proposed_at, null::timestamptz, 'soft reservation released');
  perform t.ok(t.last_answer() like 'Approved%', 'toast');
  perform t.ok(exists (select 1 from jobs where type = 'card.refresh' and package_id = pg_temp.id('pkg') and status = 'done'), 'card refreshed for everyone');
end $$;

-- manual edit (AP-2/AP-3): new human version, checks re-run; approving an outdated card version is refused
do $$
declare
  v bigint := pg_temp.var(pg_temp.id('m'), 'blog');
begin
  perform t.cb(3003, 'ed:' || v);
  perform t.work();
  perform t.ok(exists (select 1 from bot_sessions where user_id = t.uid(3003) and kind = 'edit_text'), 'edit session');
  perform t.msg(3003, E'# Jackets sale\n\nOur lead.\n\n## Why now\n' || t.words(700));
  perform t.work();
  perform t.no_errors();
  perform t.eq((select current_version from variants where id = v), 2, 'new version');
  perform t.eq((select author_kind || '/' || reason from variant_versions where variant_id = v and version = 2), 'human/edit', 'human edit version');
  perform t.eq((select content ->> 'title' from variant_versions where variant_id = v and version = 2), 'Jackets sale', 'title parsed from edit');
  perform t.eq((select check_status from variants where id = v), 'passed', 'edited version re-checked');
  perform t.ok(exists (select 1 from feedback_examples where variant_id = v and source = 'edit'), 'edit saved as example (AP-4)');
  perform t.cb(3002, 'ap:' || v || ':1');
  perform t.work();
  perform t.eq((select status from variants where id = v), 'pending_approval', 'outdated approval refused');
  perform t.eq(t.last_answer(), ellipsis(tpl('err.card_outdated', '{}'), 190), 'outdated toast');
  perform t.cb(3002, 'ap:' || v || ':2');
  perform t.work();
  perform t.eq((select status from variants where id = v), 'scheduled', 'current version approved');
end $$;

-- redo with a preset comment (AP-2): revising -> new AI version -> approval closes the feedback loop (AP-4)
do $$
declare
  v bigint := pg_temp.var(pg_temp.id('m'), 'email');
begin
  perform t.cb(3002, 'rq:' || v || ':shorter');
  perform t.work();
  perform t.no_errors();
  perform t.eq((select status from variants where id = v), 'pending_approval', 'back to approval after redo');
  perform t.eq((select reason from variant_versions where variant_id = v and version = 2), 'redo', 'redo version');
  perform t.ok((select comment from variant_versions where variant_id = v and version = 2) = tpl('redo.preset.shorter', '{}'), 'redo comment kept');
  -- facts an editor gives in a redo comment are sources for the fact check and for later fixes
  perform t.ok(check_context(v) #>> '{vars,source_text}' like '%[Editor comments%' || tpl('redo.preset.shorter', '{}') || '%', 'redo comment is a fact source');
  perform t.ok(gen_context(v, 'fix') #>> '{vars,source_text}' like '%' || tpl('redo.preset.shorter', '{}') || '%', 'fixes see the redo comment');
  perform t.ok(gen_context(v, 'redo', 'The price is 12 euros') #>> '{vars,source_text}' like '%The price is 12 euros', 'a new redo comment is a source');
  perform t.cb(3002, 'ap:' || v || ':2');
  perform t.work();
  perform t.ok((select after_text from feedback_examples where variant_id = v and source = 'redo') is not null, 'redo feedback has the approved result');
  perform t.eq((select status from variants where id = v), 'scheduled', 'email variant scheduled for the digest');
end $$;

-- publishing: due telegram post goes out once; blog is local; editors get a batched notice
do $$
declare
  v bigint := pg_temp.var(pg_temp.id('m'), 'telegram');
  vb bigint := pg_temp.var(pg_temp.id('m'), 'blog');
begin
  update variants set scheduled_at = now() - interval '1 minute' where id in (v, vb);
  perform t.eq(t.publish(), 2, 'two due posts');
  perform t.eq((select status from variants where id = v), 'published', 'telegram published');
  perform t.ok((select external_id from variants where id = v) like '@shop_channel:%', 'external id');
  perform t.eq((select external_url from variants where id = vb), 'http://localhost:3001/b/shop/a-title-' || vb, 'blog url keeps the generated slug after edits');
  perform t.eq(t.publish(), 0, 'nothing is published twice');
  perform t.eq((select count(*) from publish_attempts where variant_id = v)::int, 1, 'one attempt');
  perform t.ok(exists (select 1 from outbox where user_id = t.uid(3002) and batch_key = 'published:' || t.uid(3002)), 'batched notice to the editor');
  perform t.ok(exists (select 1 from outbox where user_id = t.uid(3001) and payload ->> 'text' like '%Telegram%'), 'author told too');
  perform t.eq((select request ->> 'text' from claim_publications(1) limit 1), null, 'no more work');
  perform t.eq(publish_request(v) ->> 'method', 'sendPhoto', 'post with the package visual');
end $$;

-- crash after sending (PB-6): unknown outcome is not retried automatically; the editor confirms
do $$
declare
  m bigint;
  v bigint;
begin
  perform t.msg(3001, 'Winter collection preview on October 10, doors open at 10.');
  m := t.flush(3001);
  v := pg_temp.var(m, 'telegram');
  perform approve_and_schedule(v, t.uid(3002), null, true);
  perform t.eq(t.publish('crash'), 1, 'attempt started');
  perform t.eq((select status from variants where id = v), 'publishing', 'publishing');
  perform t.eq(t.publish(), 0, 'pending attempt blocks a second send');
  update publish_attempts set started_at = now() - interval '10 minutes' where variant_id = v;
  perform t.eq(t.publish(), 0, 'unknown outcome: no auto retry');
  perform t.eq((select outcome from publish_attempts where variant_id = v), 'unknown', 'marked unknown');
  perform t.ok(exists (select 1 from outbox where payload::text like '%pm:' || v || '%'), '"it is published" button sent');
  perform t.cb(3002, 'pm:' || v);
  perform t.work();
  perform t.no_errors();
  perform t.eq((select status from variants where id = v), 'published', 'confirmed manually');
  insert into ids values ('m2', m);
end $$;

-- API failure (PB-5): retries with backoff inside the window, then failed + buttons; retry publishes
do $$
declare
  v bigint := pg_temp.var(pg_temp.id('m2'), 'blog');
  vt bigint;
  m bigint;
begin
  perform t.msg(3001, 'Pop-up store in the mall this weekend, 12 to 18.');
  m := t.flush(3001);
  vt := pg_temp.var(m, 'telegram');
  perform approve_and_schedule(vt, t.uid(3002), null, true);
  perform t.eq(t.publish('failed'), 1, 'first attempt');
  perform t.eq((select status from variants where id = vt), 'publishing', 'still publishing after one failure');
  perform t.ok((select next_attempt_at from variants where id = vt) > now(), 'retry scheduled with backoff');
  update variants set next_attempt_at = now() - interval '1 second', publish_first_attempt_at = now() - interval '31 minutes' where id = vt;
  perform t.eq(t.publish('failed'), 1, 'second attempt');
  perform t.eq((select status from variants where id = vt), 'failed', 'failed after the retry window');
  perform t.ok(exists (select 1 from outbox where payload::text like '%pr:' || vt || '%'), 'retry button sent');
  perform t.cb(3003, 'pr:' || vt);
  perform t.work();
  perform t.eq((select status from variants where id = vt), 'scheduled', 'retry -> scheduled now');
  perform t.eq(t.publish(), 1, 'retried');
  perform t.eq((select status from variants where id = vt), 'published', 'published on retry');
  perform t.eq((select count(*) from publish_attempts where variant_id = vt)::int, 3, 'three attempts in total');
end $$;

-- stop switch (PB-9): paused brand publishes nothing; resume publishes overdue posts
do $$
declare
  m bigint;
  v bigint;
  sp bigint;
begin
  perform t.msg(3001, 'Customer of the month interview, coming this Friday evening.');
  m := t.flush(3001);
  v := pg_temp.var(m, 'telegram');
  perform approve_and_schedule(v, t.uid(3002));
  update variants set scheduled_at = now() - interval '5 minutes' where id = v;
  perform t.msg(3002, '/pause shop');
  perform t.work();
  perform t.no_errors();
  sp := (select id from system_pauses where brand_id = pg_temp.id('b') and resumed_at is null);
  perform t.ok(sp is not null, 'brand paused');
  perform t.eq(t.publish(), 0, 'nothing published while paused');
  perform t.cb(3004, 'ur:' || sp || ':p');
  perform t.work();
  perform t.ok((select resumed_at from system_pauses where id = sp) is null, 'viewer cannot resume');
  perform t.cb(3002, 'ur:' || sp || ':r');
  perform t.work();
  perform t.ok((select resumed_at from system_pauses where id = sp) is not null, 'resumed');
  perform t.ok((select scheduled_at from variants where id = v) > now(), 'overdue post rescheduled');
  perform t.eq(t.publish(), 0, 'not due anymore');
end $$;

-- reject with a reason, remove, time, redirect to another brand (RT-5)
do $$
declare
  m bigint;
  pkg bigint;
  v bigint;
  t1 timestamptz;
begin
  perform t.msg(3001, 'Our new loyalty card gives every tenth coffee free of charge.');
  m := t.flush(3001);
  pkg := (select id from packages where material_id = m);
  v := pg_temp.var(m, 'telegram');
  perform t.cb(3002, 'rr:' || v || ':facts');
  perform t.cb(3002, 'rs:' || v);
  perform t.work();
  perform t.eq((select status from variants where id = v), 'rejected', 'rejected');
  perform t.ok(exists (select 1 from feedback_examples where variant_id = v and kind = 'antiexample' and comment like 'facts%'), 'antiexample saved');

  v := pg_temp.var(m, 'email');
  perform t.cb(3002, 'rmy:' || v);
  perform t.work();
  perform t.eq((select status from variants where id = v), 'cancelled', 'removed');

  v := pg_temp.var(m, 'blog');
  t1 := date_trunc('minute', now()) + interval '3 days';
  perform t.cb(3002, 'ts:' || v || ':' || extract(epoch from t1)::bigint);
  perform t.work();
  perform t.eq((select slot_hint_at from variants where id = v), t1, 'time hint stored for a pending variant');

  perform t.cb(3002, 'rob:' || pkg || ':' || pg_temp.id('b2'));
  perform t.work();
  perform t.no_errors();
  perform t.ok((select cancelled_at from packages where id = pkg) is not null, 'old package cancelled');
  perform t.eq((select status from variants where id = v), 'cancelled', 'pending variant of the old package cancelled');
  perform t.eq((select count(*) from packages where material_id = m and brand_id = pg_temp.id('b2') and redirected_from = pkg)::int, 1, 'new package in the other brand');
  perform t.eq((select count(*) from variants v2 join packages p on p.id = v2.package_id
                where p.material_id = m and p.brand_id = pg_temp.id('b2') and v2.status = 'pending_approval')::int, 1, 'new variant generated and checked');
end $$;

-- auto-publish (AP-6): checks passed -> approved and scheduled without a person
do $$
declare
  m bigint;
  v variants;
begin
  update brand_platforms set auto_publish = true where brand_id = pg_temp.id('b') and platform = 'telegram';
  perform t.msg(3001, 'Weekend brunch menu is back with pancakes and fresh juice.');
  m := t.flush(3001);
  select * into v from variants where id = pg_temp.var(m, 'telegram');
  perform t.eq(v.status, 'scheduled', 'auto-approved and scheduled');
  perform t.eq(v.auto_approved, true, 'auto flag');
  perform t.eq((select status from variants where id = pg_temp.var(m, 'blog')), 'pending_approval', 'other platforms still need approval');
end $$;

-- approval deadline (AP-5): not approved by the proposed slot -> moved, editors told
do $$
declare
  m bigint;
  v variants;
  j bigint;
  old timestamptz;
begin
  perform t.msg(3001, 'Barista workshop next month, sign up at the counter.');
  m := t.flush(3001);
  select * into v from variants where id = pg_temp.var(m, 'blog');
  old := v.proposed_at;
  select id into j from jobs where variant_id = v.id and type = 'variant.deadline' and payload ->> 'kind' = 'missed';
  update jobs set run_after = now() where id = j;
  update variants set proposed_at = old where id = v.id;
  perform t.work();
  perform t.no_errors();
  perform t.ok((select proposed_at from variants where id = v.id) >= old, 'slot moved on');
  perform t.ok(exists (select 1 from outbox where payload ->> 'text' like '%' || fmt_local(old, 'Europe/Berlin') || '%'), 'missed slot notice');
  perform t.eq((select status from variants where id = v.id), 'pending_approval', 'not published without approval');
end $$;

rollback;
