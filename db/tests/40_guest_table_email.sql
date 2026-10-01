-- Guest demo (tz section 10), tables (IN-9), email intake (IN-1), invites and revocation (AD-2).
begin;
set local role app_n8n;

-- guest: demo brand, preview only, no editor cards, daily limit; unknown senders are refused (IN-8)
do $$
declare
  demo bigint := t.brand('demo-cafe', array['telegram', 'linkedin'], 'UTC', true);
  admin bigint := t.user(4000, null, null, true);
  m bigint;
  v variants;
begin
  perform t.user(4009, demo, 'editor');
  perform t.msg(4001, 'hello, can I post here?');
  perform t.work();
  perform t.eq((select count(*) from materials where author_user_id = t.uid(4001))::int, 0, 'unknown sender creates nothing');
  perform t.ok(t.last_text(4001) like '%' || left(tpl('start.unknown', '{}'), 20) || '%', 'unknown sender gets the access/demo text');
  perform t.ok(exists (select 1 from outbox where chat_id = 4000 and payload ->> 'text' like '%u4001%'), 'admins told about the unknown sender');

  perform t.cb(4001, 'gd');
  perform t.cb(4001, 'gb:' || demo);
  perform t.work();
  perform t.eq((select guest_brand_id from users where tg_user_id = 4001), demo, 'demo brand selected');
  perform t.msg(4001, 'We are a flower shop opening a second store downtown.');
  m := t.flush(4001);
  perform t.no_errors();
  perform t.eq((select is_guest from materials where id = m), true, 'guest material');
  perform t.eq((select method from material_routes where material_id = m), 'guest', 'routed to the guest brand');
  select * into v from variants where package_id = (select id from packages where material_id = m) and platform = 'telegram';
  perform t.eq(publish_target(v.id), 'preview', 'guest content never reaches a real adapter');
  perform t.eq(v.status, 'scheduled', 'guest variants auto-approved for preview');
  perform t.ok(exists (select 1 from outbox where slot_key like 'card:%:' || t.uid(4001)), 'guest sees its own card');
  perform t.ok(not exists (select 1 from outbox where slot_key like 'card:%:' || t.uid(4009)), 'demo editors get no guest cards');
  perform t.eq(t.publish(), 2, 'preview publications');
  perform t.eq((select status from variants where id = v.id), 'published', 'preview published');
  perform t.ok((select external_url from variants where id = v.id) like 'http://localhost:3001/p/%', 'preview url');
  perform t.ok(not exists (select 1 from publish_attempts where adapter = 'telegram'), 'no telegram attempts at all');

  perform t.msg(4001, 'second material text for the demo brand, quite different.');
  perform t.flush(4001);
  perform t.msg(4001, 'third material text about something else again entirely.');
  perform t.flush(4001);
  perform t.msg(4001, 'fourth material over the daily limit, should be refused.');
  perform t.work();
  perform t.eq((select count(*) from materials where author_user_id = t.uid(4001))::int, 3, 'daily guest limit');
  perform t.ok(t.last_text(4001) like '%3%', 'limit explained');

  -- moderation: flagged guest content is rejected before generation
  update materials set created_at = now() - interval '2 days' where author_user_id = t.uid(4001);
  perform t.set('summary.flagged', 'true');
  perform t.msg(4001, 'some content the moderation flags as not allowed.');
  m := t.flush(4001);
  perform t.eq((select status from materials where id = m), 'rejected', 'flagged guest content rejected');
  perform t.eq((select count(*) from packages where material_id = m)::int, 0, 'nothing generated');
  delete from t.knobs;
end $$;

-- table (IN-9): one material per valid row, invalid rows reported by number, re-processing adds nothing
do $$
declare
  b bigint := t.brand('tabletop', array['telegram', 'blog']);
  m bigint;
  part bigint;
  r jsonb;
begin
  perform t.user(4101, b, 'author');
  insert into t.table_rows values ('plan.xlsx', jsonb_build_array(
    jsonb_build_object('Brand', 'tabletop', 'Topic or text', 'Board game night on Friday', 'Platforms', 'telegram', 'Date', to_char(now() + interval '5 days', 'YYYY-MM-DD HH24:MI')),
    jsonb_build_object('Brand', 'nope', 'Topic or text', 'Unknown brand row'),
    jsonb_build_object('Brand', '', 'Topic or text', '', 'Link', '', 'Platforms', ''),
    jsonb_build_object('Brand', 'Tabletop', 'Link', 'not a url'),
    jsonb_build_object('Brand', 'tabletop', 'Topic or text', 'Chess tournament recap', 'Date', '2020-01-01 10:00'),
    jsonb_build_object('Brand', 'tabletop', 'Topic or text', 'New arrivals: 5 games', 'Platforms', 'telegram, fax'),
    jsonb_build_object('Brand', 'tabletop', 'Topic or text', 'Kids corner opens', 'Platforms', 'Blog')));
  perform t.msg(4101, null, jsonb_build_object('document', jsonb_build_object('file_id', 'X1', 'file_unique_id', 'XU1', 'file_name', 'plan.xlsx',
                     'mime_type', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'file_size', 5000)));
  perform t.work();
  m := t.last_material(4101);
  part := (select id from material_parts where material_id = m);
  perform t.age(m);
  perform t.work();
  perform t.no_errors();
  perform t.eq((select is_container from materials where id = m), true, 'container');
  perform t.eq((select count(*) from materials where parent_material_id = m)::int, 2, 'two valid rows -> two materials');
  perform t.eq((select string_agg(row_number::text, ',' order by row_number) from materials where parent_material_id = m), '2,8', 'row numbers kept');
  r := (select payload from outbox where dedupe_key = 'table_report:' || m);
  perform t.ok(r ->> 'text' like '%row 3: unknown brand "nope"%', 'unknown brand reported');
  perform t.ok(r ->> 'text' like '%row 5: link is not a valid%', 'bad link reported');
  perform t.ok(r ->> 'text' like '%row 6: date is in the past%', 'past date reported');
  perform t.ok(r ->> 'text' like '%row 7: unknown platform(s): fax%', 'unknown platform reported');
  perform t.ok(r ->> 'text' not like '%row 4%', 'empty row skipped silently');
  perform t.eq((select count(*) from variants v join packages p on p.id = v.package_id join materials c on c.id = p.material_id
                where c.parent_material_id = m and c.row_number = 2)::int, 1, 'row platforms respected');
  perform t.ok((select slot_hint_at from variants v join packages p on p.id = v.package_id join materials c on c.id = p.material_id
                where c.parent_material_id = m and c.row_number = 2) > now(), 'row date becomes the slot hint');
  perform t.eq((table_split(part, (select rows from t.table_rows where file_name = 'plan.xlsx'))) ->> 'already', 'true', 're-split is a no-op');
end $$;

-- acceptance (tz 11): a 500-row table -> 0 lost, 0 duplicated, bad rows listed by number; every row reaches its package
do $$
declare
  b bigint := t.brand('bulk', array['telegram']);
  m bigint;
  part bigint;
  r jsonb;
  bad int[] := array[50, 150, 250, 350, 450, 99, 199, 299];
begin
  perform t.user(4201, b, 'author');
  insert into t.table_rows select 'bulk.csv', jsonb_agg(case
      when i = any(bad[1:5]) then jsonb_build_object('brand', 'nope', 'text', 'Row ' || i)
      when i = any(bad[6:8]) then jsonb_build_object('brand', 'bulk', 'text', '')
      else jsonb_build_object('brand', 'bulk', 'text', 'Topic ' || i || ': ' || md5(i::text)) end order by i)
    from generate_series(1, 500) i;
  perform t.msg(4201, null, jsonb_build_object('document', jsonb_build_object('file_id', 'B1', 'file_unique_id', 'BU1', 'file_name', 'bulk.csv',
                     'mime_type', 'text/csv', 'file_size', 40000)));
  perform t.work(20000);
  m := t.last_material(4201);
  part := (select id from material_parts where material_id = m);
  perform t.age(m);
  perform t.work(20000);
  perform t.no_errors();
  perform t.eq((select count(*) from materials where parent_material_id = m)::int, 492, '492 valid rows -> 492 materials');
  perform t.eq((select count(distinct row_number) from materials where parent_material_id = m)::int, 492, 'no duplicated rows');
  perform t.eq((select count(*) from packages p join materials c on c.id = p.material_id where c.parent_material_id = m)::int, 492, 'every row has its package');
  perform t.ok((select max(j.priority) from jobs j join materials c on c.id = j.material_id where c.parent_material_id = m) < 0,
               'row jobs yield to live materials');
  r := (select payload from outbox where dedupe_key = 'table_report:' || m);
  perform t.ok((select bool_and(r ->> 'text' like '%row ' || (x + 1) || ': %') from unnest(bad) x), 'every bad row listed with its number');
  perform t.ok(r ->> 'text' like '%492%', 'accepted count reported');
  perform t.eq((table_split(part, (select rows from t.table_rows where file_name = 'bulk.csv'))) ->> 'already', 'true', 're-split adds nothing');
  perform table_rows_start(m);
  perform t.work(2000);
  perform t.eq((select count(*) from packages p join materials c on c.id = p.material_id where c.parent_material_id = m)::int, 492, 'restart adds nothing');
end $$;

-- email intake: personal address -> material with parts, ack by email; strangers get one polite reply
do $$
declare
  u users;
  ev bigint;
  m bigint;
  r jsonb;
begin
  u := (select x from users x where tg_user_id = 4101);
  update users set email = 'author@example.com' where id = u.id;
  r := resend_ingest(jsonb_build_object('type', 'email.received', 'data', jsonb_build_object('email_id', 'em-1')), 'svix-1');
  perform t.eq(r ->> 'new', 'true', 'webhook recorded');
  perform t.eq(resend_ingest(jsonb_build_object('type', 'email.received', 'data', jsonb_build_object('email_id', 'em-1')), 'svix-1') ->> 'new', 'false', 'duplicate webhook ignored');
  ev := (select id from inbound_events where external_key = 'svix-1');
  perform t.eq((email_fetch_context(ev) ->> 'done')::boolean, false, 'fetch context');
  perform intake_email(ev, jsonb_build_object('id', 'em-1', 'from', 'Author <Author@Example.com>', 'to', jsonb_build_array('in+' || u.intake_token || '@in.example.com'),
    'subject', 'Board game night', 'text', 'Friday 19:00, bring friends.',
    'attachments', jsonb_build_array(jsonb_build_object('id', 'att1', 'filename', 'poster.jpg', 'content_type', 'image/jpeg', 'size', 1000, 's3_key', 'm/x/poster.jpg', 'sha256', 'abc'))));
  m := (select max(id) from materials where source = 'email');
  perform t.eq((select count(*) from material_parts where material_id = m)::int, 2, 'text + attachment parts');
  perform t.ok((select asset_id from material_parts where material_id = m and kind = 'image') is not null, 'attachment asset linked');
  perform t.ok(exists (select 1 from outbox where channel = 'email' and email_to = 'author@example.com' and dedupe_key = 'email_ack:' || m), 'ack by email');
  perform intake_email(ev, '{}');
  perform t.eq((select count(*) from materials where source = 'email')::int, 1, 'second fetch of the same event does nothing');
  perform t.work();
  perform t.no_errors();
  perform t.eq((select status from materials where id = m), 'routed', 'email material processed');

  perform resend_ingest(jsonb_build_object('type', 'email.received', 'data', jsonb_build_object('email_id', 'em-2')), 'svix-2');
  ev := (select id from inbound_events where external_key = 'svix-2');
  perform intake_email(ev, jsonb_build_object('from', 'stranger@evil.test', 'to', jsonb_build_array('in+0000000000000000@in.example.com'), 'text', 'hi'));
  perform t.eq((select status from inbound_events where id = ev), 'ignored', 'stranger ignored');
  perform t.eq((select count(*) from outbox where email_to = 'stranger@evil.test')::int, 1, 'one reply to the stranger');
end $$;

-- invites and immediate revocation (AD-2)
do $$
declare
  b bigint := t.brand('club');
  mgr bigint := t.user(4201, b, 'manager');
  tok text;
begin
  perform t.msg(4201, '/invite editor club');
  perform t.work();
  perform t.no_errors();
  tok := substring(t.last_text(4201) from 'start=([a-f0-9]{32})');
  perform t.ok(tok is not null, 'invite link');
  perform t.msg(4202, '/start ' || tok);
  perform t.work();
  perform t.eq(user_role(t.uid(4202), b), 'editor', 'invite accepted');
  perform t.msg(4203, '/start ' || tok);
  perform t.work();
  perform t.eq(user_role(t.uid(4203), b), null::text, 'invite is single-use');
  perform t.msg(4202, '/invite manager club');
  perform t.work();
  perform t.ok(t.last_text(4202) like '⚠️%', 'editor cannot invite');
  perform bot_session_set(t.uid(4202), 'edit_text', '{"variant_id": 1}');
  perform t.msg(4201, '/revoke @u4202 club');
  perform t.work();
  perform t.eq(user_role(t.uid(4202), b), null::text, 'revoked');
  perform t.ok(not exists (select 1 from bot_sessions where user_id = t.uid(4202)), 'open dialog dropped');
  perform t.ok(exists (select 1 from audit_log where action = 'access.revoked' and entity_id = t.uid(4202)), 'revocation audited');
end $$;

rollback;
