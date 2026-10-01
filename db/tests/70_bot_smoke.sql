-- Every bot command and button once: no SQL errors, every update gets an answer. Plus visuals, post edits/deletes, onboarding, feeds.
begin;
set local role app_n8n;

do $$
declare
  b bigint := t.brand('smoke', array['telegram', 'blog', 'email', 'x']);
  m bigint;
  pkg bigint;
  v bigint;
  vx bigint;
  cmd text;
  n_before int;
  j bigint;
  ctx jsonb;
begin
  perform t.user(7001, b, 'manager');
  perform t.user(7002, b, 'author');
  perform t.user(7003, null, null, true);
  perform t.msg(7002, 'Smoke test material about a jazz evening on Thursday at 20:00.');
  m := t.flush(7002);
  perform t.no_errors();
  pkg := (select id from packages where material_id = m);
  v := (select id from variants where package_id = pkg and platform = 'telegram');
  vx := (select id from variants where package_id = pkg and platform = 'x');
  perform t.eq((select check_status from variants where id = vx), 'passed', 'thread variant checked');

  foreach cmd in array array['/start', '/help', '/brands', '/cancel', '/panel', '/intake', '/notify each', '/notify bad',
                             '/myemail boss@example.com', '/budget smoke', '/report smoke', '/digest smoke', '/examples smoke',
                             '/users smoke', '/m ' || m, '/status M-' || m, '/profile smoke', '/onboard smoke', '/pause smoke x',
                             '/resume', '/unknowncmd', '/invite', '/newbrand bad', '/newbrand newco New Company'] loop
    perform t.msg(7001, cmd);
  end loop;
  perform t.msg(7003, '/jobs');
  perform t.msg(7003, '/retry 999999');
  perform t.msg(7003, '/eval routing');
  perform t.msg(7003, '/pause all');
  perform t.msg(7002, '/m ' || m);
  perform t.msg(7002, '/users smoke');
  perform t.work();
  perform t.no_errors();
  perform t.ok(t.last_text(7002) like '⚠️%', 'author cannot list users');
  perform t.ok(exists (select 1 from outbox where chat_id = 7003 and payload ->> 'text' like '🧪 Eval run #%'), 'admin starts eval from the bot');
  perform t.ok((select count(*) from outbox where chat_id = 7001) >= 20, 'every command answered');
  perform t.ok(exists (select 1 from brands where slug = 'newco' and status = 'draft') is false, 'manager cannot create brands');

  -- card buttons
  n_before := (select count(*) from outbox where kind = 'callback_answer');
  foreach cmd in array array['cv:' || pkg || ':' || vx, 'cm:' || pkg, 'cb:' || pkg, 'ft:' || v, 'src:' || pkg, 'hl:' || v, 'hs:' || v,
                             'tm:' || v, 'te:' || v, 'rm:' || v, 'pn:' || v, 'rd:' || v, 'rj:' || v, 'ro:' || pkg, 'uv:' || pkg,
                             'ed:' || v, 'rc:' || v, 'hc:' || v || ':1', 'rv:' || pkg, 'zz:1', 'ap:abc', 'exd:0'] loop
    perform t.cb(7001, cmd);
  end loop;
  perform t.work();
  perform t.no_errors();
  perform t.eq((select count(*) from outbox where kind = 'callback_answer')::int - n_before, 22, 'every button answered');
  perform t.eq((select content ->> 'text' from variant_versions where variant_id = v and version = (select current_version from variants where id = v)) like 'Headline B%', true,
               'headline applied as a new version');
  perform t.eq((select visual_status from packages where id = pkg), 'done', 'visual regenerated');
  perform t.ok((select count(*) from variant_versions where variant_id = v and reason = 'visual') >= 1, 'visual change is a new version');

  -- own visual upload through the dialog
  perform t.cb(7001, 'uv:' || pkg);
  perform t.work();
  perform t.msg(7001, null, jsonb_build_object('photo', jsonb_build_array(jsonb_build_object('file_id', 'P1', 'file_unique_id', 'PU1', 'width', 800, 'height', 600))));
  perform t.work();
  perform t.no_errors();
  perform t.ok(exists (select 1 from package_visuals where package_id = pkg and origin = 'upload'), 'uploaded visual used');

  -- time typed by the editor
  perform t.cb(7001, 'te:' || v);
  perform t.work();
  perform t.msg(7001, 'tomorrow 21:30');
  perform t.work();
  perform t.no_errors();
  perform t.eq(to_char((select slot_hint_at from variants where id = v) at time zone 'Europe/Berlin', 'HH24:MI'), '21:30', 'typed time stored');
  perform t.eq(parse_user_time('2026-13-45 10:00', 'UTC'), null::timestamptz, 'bad date -> null');
  perform t.eq(parse_user_time('01.10 18:00', 'UTC') is not null, true, 'DD.MM HH:MI');

  -- publish, then edit and delete the published post (PB-7)
  perform pause_resume(t.uid(7003), id, 'publish_overdue') from system_pauses where resumed_at is null;
  perform approve_and_schedule(v, t.uid(7001), null, true);
  perform t.publish();
  perform t.eq((select status from variants where id = v), 'published', 'published');
  perform t.cb(7001, 'pe:' || v);
  perform t.work();
  perform t.msg(7001, 'Edited after publishing: jazz evening moved to 21:00.');
  perform t.work();
  perform t.no_errors();
  perform t.ok(exists (select 1 from jobs where type = 'post.op' and variant_id = v and payload ->> 'op' = 'edit'), 'post edit queued');
  perform t.cb(7001, 'pdy:' || v);
  perform t.work();
  perform t.ok(exists (select 1 from jobs where type = 'post.op' and variant_id = v and payload ->> 'op' = 'delete'), 'post delete queued');

  -- what CORE · Post ops sends, and the result bookkeeping
  j := (select id from jobs where type = 'post.op' and variant_id = v and payload ->> 'op' = 'edit');
  ctx := post_op_context(j);
  perform t.eq(ctx ->> 'method', 'editMessageCaption', 'post with a photo: caption edit');
  perform t.ok(ctx #>> '{body,caption}' like 'Edited after publishing%', 'new text');
  perform t.eq(ctx #>> '{body,chat_id}', '@smoke_channel', 'chat from external id');
  perform post_op_result(j, false, 400, 'Bad Request: message can''t be edited');
  perform t.ok(exists (select 1 from outbox where dedupe_key = 'postop_failed:' || j || ':' || t.uid(7001)), 'editor told about the failed edit');
  j := (select id from jobs where type = 'post.op' and variant_id = v and payload ->> 'op' = 'delete');
  perform t.eq(post_op_context(j) ->> 'method', 'deleteMessage', 'delete call');
  perform post_op_result(j, true, 200);
  perform t.ok((select external_deleted_at from variants where id = v) is not null, 'marked deleted');
  perform t.eq(post_op_context(j) ->> 'skip', 'true', 'nothing left to do');

  perform workflow_error_log('{"workflow": {"id": "acfPublisher0001", "name": "CORE · Publisher"}, "execution": {"id": "42", "lastNodeExecuted": "Send", "error": {"message": "boom"}}}');
  perform workflow_error_log('{"workflow": {"id": "acfPublisher0001", "name": "CORE · Publisher"}, "execution": {"id": "43", "error": {"message": "boom again"}}}');
  perform t.eq((select count(*) from workflow_errors where workflow_id = 'acfPublisher0001')::int, 2, 'errors stored');
  perform t.eq((select count(*) from outbox where chat_id = 7003 and payload ->> 'text' like '%Workflow error%')::int, 1, 'one admin alert per 15 minutes');
end $$;

-- onboarding (BP-3): samples -> draft job; feeds (DG-2): items saved once, relevance kept
do $$
declare
  b bigint := (select id from brands where slug = 'smoke');
  src bigint;
  i int;
begin
  perform t.msg(7001, '/onboard smoke');
  perform t.work();
  for i in 1..3 loop
    perform t.msg(7001, 'Sample post number ' || i || ': we love jazz and good coffee on Thursdays.');
  end loop;
  perform t.msg(7001, 'https://example.com/post-4');
  perform t.msg(7001, '/done');
  perform t.work();
  perform t.no_errors();
  perform t.eq((select count(*) from onboarding_samples where brand_id = b)::int, 4, 'samples collected');
  perform t.ok(exists (select 1 from jobs where type = 'onboarding.draft' and brand_id = b), 'draft job queued');
  perform t.eq(jsonb_array_length(onboarding_context(b) -> 'samples'), 4, 'context has the samples');
  perform onboarding_draft_saved(b, t.uid(7001), t.profile('Smoke'), '[]');
  perform t.eq((select status from brand_profile_versions where brand_id = b and version = 2), 'draft', 'onboarding draft saved');

  insert into feed_sources (brand_id, url) values (b, 'https://example.com/feed.xml') returning id into src;
  perform t.eq(jsonb_array_length(feeds_context(b) -> 'sources'), 1, 'feed source listed');
  perform t.eq(feed_items_save(src, '[{"guid": "a", "title": "A", "link": "https://e.com/a", "relevance": 0.5}, {"guid": "b", "title": "B", "relevance": 0.1}]'), 2, 'two items');
  perform t.eq(feed_items_save(src, '[{"guid": "a", "title": "A"}]'), 0, 'same guid is not saved twice');
end $$;

rollback;
