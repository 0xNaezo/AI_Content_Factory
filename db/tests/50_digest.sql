-- Email digest (DG-1..DG-7): plan, build, approval, send in idempotent chunks, delivery events, subscriptions.
begin;
set local role app_n8n;

do $$
declare
  b bigint := t.brand('news', array['email']);
  m bigint;
  di digest_issues;
  s1 subscribers;
  r jsonb;
  n int;
begin
  perform t.user(5001, b, 'editor');
  -- subscriptions through the web command entry (double opt-in)
  r := web_command('subscribe', '{"brand": "news", "email": "Reader@Example.com"}');
  perform t.eq(r ->> 'status', 'pending', 'pending until confirmed');
  perform t.ok(exists (select 1 from outbox where email_to = 'reader@example.com' and payload ->> 'html' like '%/confirm/%'), 'confirmation email');
  select * into s1 from subscribers where email = 'reader@example.com';
  perform t.eq(web_command('confirm', jsonb_build_object('token', s1.token)) ->> 'status', 'confirmed', 'confirmed');
  perform t.eq(web_command('subscribe', '{"brand": "news", "email": "not-an-email"}') ->> 'ok', 'false', 'invalid email refused');
  perform t.eq(web_command('subscribe', '{"brand": "nope", "email": "a@b.cd"}') ->> 'ok', 'false', 'unknown newsletter refused');
  insert into subscribers (brand_id, email, status) select b, 'r' || i || '@example.com', 'confirmed' from generate_series(1, 150) i;
  insert into subscribers (brand_id, email, status) values (b, 'pending@example.com', 'pending');

  -- two approved email blocks
  for n in 1..2 loop
    perform t.msg(5001, case n when 1 then 'Our community garden harvested two hundred kilos of tomatoes this year.'
                               else 'A new bike repair cafe opens every first Saturday at the town hall.' end);
    m := t.flush(5001);
    perform approve_and_schedule((select v.id from variants v join packages p on p.id = v.package_id where p.material_id = m), t.uid(5001));
  end loop;
  perform t.no_errors();
  perform t.eq((select count(*) from variants where platform = 'email' and status = 'scheduled')::int, 2, 'blocks wait for the digest');

  -- build now (/digest news now) -> card with approve / test / preview
  perform t.msg(5001, '/digest news now');
  perform t.work();
  perform t.no_errors();
  select * into di from digest_issues where brand_id = b order by id limit 1;
  perform t.eq(di.status, 'pending_approval', 'issue built and waiting');
  perform t.eq((select count(*) from digest_items where issue_id = di.id)::int, 2, 'two blocks');
  perform t.ok(exists (select 1 from outbox where slot_key = 'digest:' || di.id || ':' || t.uid(5001)), 'digest card');
  perform t.msg(5001, '/myemail editor@example.com');
  perform t.work();
  perform t.cb(5001, 'dt:' || di.id);
  perform t.work();
  perform t.ok(exists (select 1 from jobs where type = 'digest.test' and payload ->> 'email' = 'editor@example.com'), 'test send queued');
  perform t.cb(5001, 'da:' || di.id);
  perform t.work();
  perform t.eq((select status from digest_issues where id = di.id), 'scheduled', 'approved -> scheduled');

  -- send time: chunks of 100, only confirmed subscribers, per-subscriber unsubscribe links, blocks marked published
  update digest_issues set send_at = now() where id = di.id;  -- send time has come
  update jobs set run_after = now() where type = 'digest.deadline' and payload ->> 'issue_id' = di.id::text;
  perform t.work();
  perform t.no_errors();
  select * into di from digest_issues where id = di.id;
  perform t.eq(di.status, 'published', 'issue sent');
  perform t.eq((di.stats ->> 'sent')::int, 151, 'sent to confirmed subscribers only');
  perform t.eq((select count(distinct chunk) from digest_deliveries where issue_id = di.id)::int, 2, 'two chunks');
  perform t.eq((select count(*) from variants where digest_issue_id = di.id and status = 'published')::int, 2, 'blocks published with the issue');
  perform t.eq(digest_next_chunk(di.id) ->> 'skip', 'true', 'nothing left to send (idempotent)');
  perform t.ok(exists (select 1 from digest_issues where brand_id = b and id <> di.id and status = 'draft'), 'next issue planned');

  -- delivery events (DG-6): best engagement status kept, bounce/complaint stop future sends
  perform esp_event_apply('esp-' || di.id || '-reader@example.com', 'opened');
  perform esp_event_apply('esp-' || di.id || '-reader@example.com', 'delivered');
  perform t.eq((select status from digest_deliveries where esp_message_id = 'esp-' || di.id || '-reader@example.com'), 'opened', 'opened is kept');
  perform esp_event_apply('esp-' || di.id || '-r1@example.com', 'bounced');
  perform t.eq((select status from subscribers where email = 'r1@example.com'), 'bounced', 'bounced subscriber disabled');
  perform t.eq((select (stats ->> 'opened')::int from digest_issues where id = di.id), 1, 'opened counter');
  perform t.eq(web_command('unsubscribe', jsonb_build_object('token', s1.token)) ->> 'status', 'unsubscribed', 'unsubscribed');
  perform t.eq((select (stats ->> 'unsubscribed')::int from digest_issues where id = di.id), 1, 'unsubscribe counted on the issue');
  perform t.eq(web_command('delete', jsonb_build_object('token', s1.token)) ->> 'status', 'deleted', 'subscriber data deleted');

  -- DG-7: fewer than two blocks -> skipped, editors told
  select * into di from digest_issues where brand_id = b and status = 'draft';
  update jobs set run_after = now() where type = 'digest.build' and payload ->> 'issue_id' = di.id::text;
  perform t.work();
  perform t.eq((select status from digest_issues where id = di.id), 'skipped', 'empty issue skipped');
  perform t.ok(exists (select 1 from outbox where dedupe_key = 'digest_skipped:' || di.id || ':' || t.uid(5001)), 'skip notice');

  -- DG-4: built but not approved at send time and no auto-send -> not sent
  for n in 3..4 loop
    perform t.msg(5001, case n when 3 then 'Volunteers repainted the old bus stop with a mural of local birds.'
                               else 'The library extends weekend opening hours starting next month.' end);
    m := t.flush(5001);
    perform approve_and_schedule((select v.id from variants v join packages p on p.id = v.package_id where p.material_id = m), t.uid(5001));
  end loop;
  select * into di from digest_issues where brand_id = b and status = 'draft';
  update jobs set run_after = now() where type = 'digest.build' and payload ->> 'issue_id' = di.id::text;
  perform t.work();
  perform t.eq((select status from digest_issues where id = di.id), 'pending_approval', 'built');
  update digest_issues set send_at = now() + interval '1 second' where id = di.id;  -- send time has come (now() is taken)
  update jobs set run_after = now() where type = 'digest.deadline' and payload ->> 'issue_id' = di.id::text;
  perform t.work();
  perform t.no_errors();
  perform t.eq((select status from digest_issues where id = di.id), 'skipped', 'not approved -> not sent');
  perform t.eq((select count(*) from variants where digest_issue_id = di.id)::int, 0, 'blocks released for the next issue');
end $$;

rollback;
