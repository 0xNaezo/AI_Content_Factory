-- Intake -> summary -> routing -> packages -> generation -> checks -> visuals -> card; duplicates, clarification, fix loop.
begin;
set local role app_n8n;

-- A. happy path: single-brand author, text message glued with a second one, processed after the window
do $$
declare
  b bigint := t.brand('cafe');
  author bigint := t.user(2001, b, 'author');
  editor bigint := t.user(2002, b, 'editor');
  m bigint;
  p packages;
  n int;
begin
  perform t.msg(2001, 'We open a new coffee place on Main street next Monday.');
  perform t.msg(2001, 'Opening hours 8-20, first coffee free.');
  perform t.msg(2001, 'We open a new coffee place on Main street next Monday.');  -- webhook redelivery has a new update_id: a new part
  perform t.eq(tg_ingest((select payload from inbound_events order by id desc limit 1)) ->> 'new', 'false', 'same update_id is ignored');
  perform t.work();
  m := t.last_material(2001);
  perform t.eq((select count(*) from materials where author_user_id = author)::int, 1, 'messages glued into one material');
  perform t.eq((select count(*) from material_parts where material_id = m)::int, 3, 'three text parts');
  perform t.eq((select status from materials where id = m), 'received', 'waits for the glue window');
  perform t.ok(t.last_text(2001) like '%M-' || m || '%', 'ack with material code');

  perform t.age(m);
  perform t.work();
  perform t.no_errors();
  perform t.eq((select status from materials where id = m), 'routed', 'routed');
  perform t.eq((select method from material_routes where material_id = m), 'single_brand', 'single brand route');
  select * into p from packages where material_id = m;
  perform t.eq((select count(*) from variants where package_id = p.id)::int, 3, 'variant per active platform');
  perform t.eq((select count(*) from variants where package_id = p.id and status = 'pending_approval' and check_status = 'passed')::int, 3,
               'all variants checked and waiting for approval');
  perform t.eq(p.visual_status, 'done', 'visual done');
  perform t.ok(p.card_sent_at is not null, 'card sent');
  perform t.ok(exists (select 1 from outbox where slot_key = 'card:' || p.id || ':' || editor), 'card slot for the editor');
  perform t.ok(not exists (select 1 from outbox where slot_key = 'card:' || p.id || ':' || author), 'authors get no card');
  perform t.ok((select proposed_at from variants where package_id = p.id and platform = 'telegram') > now(), 'slot proposed');
  perform t.ok(exists (select 1 from jobs where type = 'variant.deadline' and variant_id = (select id from variants where package_id = p.id and platform = 'telegram')),
               'approval deadline jobs');
  perform t.ok((select payload ->> 'text' from outbox where slot_key = 'ack:' || m order by id desc limit 1) like '%Cafe%', 'ack shows the brand');
  select count(*) into n from ai_usage;
  perform t.eq(n, 0, 'fake worker makes no AI calls');
end $$;

-- B. duplicate (IN-6): the same text again -> question -> "create new" continues
do $$
declare
  m bigint;
begin
  perform t.msg(2001, 'Fresh croissants every Sunday at the corner bakery, from 7 am.');
  m := t.flush(2001);
  perform t.eq((select status from materials where id = m), 'routed', 'original routed');
  perform t.msg(2001, 'Fresh croissants every Sunday at the corner bakery, from 7 am!');
  m := t.flush(2001);
  perform t.eq((select status from materials where id = m), 'awaiting_author', 'duplicate question asked');
  perform t.eq((select question ->> 'type' from materials where id = m), 'duplicate', 'question type');
  perform t.cb(2001, 'qdn:' || m);
  perform t.work();
  perform t.no_errors();
  perform t.eq((select status from materials where id = m), 'routed', 'continued after "create new"');
  perform t.eq((select question from materials where id = m), null::jsonb, 'question closed');
end $$;

-- C. insufficient data (EX-3): clarifying question, the answer bumps the revision, then low-data generation
do $$
declare
  m bigint;
begin
  perform t.set('summary.sufficient', 'false');
  perform t.msg(2001, 'Something about an event, details later maybe. Totally different topic here.');
  perform t.work();
  m := t.last_material(2001);
  perform t.cb(2001, 'mp:' || m);  -- "Process now"
  perform t.work();
  perform t.eq((select question ->> 'type' from materials where id = m), 'clarify', 'clarify question');
  perform t.ok(exists (select 1 from bot_sessions where user_id = t.uid(2001) and kind = 'clarify'), 'clarify session');
  perform t.msg(2001, 'It is on Friday at 18:00 in the park.');
  perform t.work();
  perform t.no_errors();
  perform t.eq((select revision from materials where id = m), 2, 'revision bumped');
  perform t.eq((select count(*) from material_parts where material_id = m and kind = 'clarification')::int, 1, 'clarification part');
  perform t.eq((select status from materials where id = m), 'routed', 'routed after clarification');
  perform t.eq((select low_data from packages where material_id = m), true, 'still insufficient -> low data flag');
  perform t.eq((select count(*) from materials where author_user_id = t.uid(2001) and id > m)::int, 0, 'answer did not become a new material');
  delete from t.knobs;
end $$;

-- D. classifier (RT-1/RT-2): confident -> classifier route; unsure -> author picks from the top brands
do $$
declare
  b1 bigint := t.brand('gym');
  b2 bigint := t.brand('saas');
  m bigint;
begin
  perform t.user(2101, b1, 'author');
  perform t.user(2101, b2, 'author');
  perform t.msg(2101, 'Our new HIIT class starts in October, every Tuesday.');
  m := t.flush(2101);
  perform t.no_errors();
  perform t.eq((select method from material_routes where material_id = m), 'classifier', 'confident classifier route');

  perform t.set('route.result', '{"off_topic": false, "reason": "r", "ranking": [{"brand": "saas", "confidence": 0.55, "reason": "r"}, {"brand": "gym", "confidence": 0.4, "reason": "r"}]}');
  perform t.msg(2101, 'A totally ambiguous update about our team offsite and plans.');
  m := t.flush(2101);
  perform t.eq((select question ->> 'type' from materials where id = m), 'brand', 'brand question');
  perform t.ok((select payload::text from outbox where slot_key = 'q:' || m order by id desc limit 1) like '%qb:' || m || ':' || b2 || '%', 'top brand button');
  perform t.cb(2101, 'qb:' || m || ':' || b1);
  perform t.work();
  perform t.no_errors();
  perform t.eq((select brand_id from material_routes where material_id = m), b1, 'author choice');
  perform t.eq((select method from material_routes where material_id = m), 'author_choice', 'author choice method');

  -- an author can't route into a brand they don't belong to (callback data is untrusted)
  perform t.msg(2101, 'Yet another ambiguous thing to post somewhere else entirely.');
  m := t.flush(2101);
  perform t.cb(2101, 'qb:' || m || ':' || (select id from brands where slug = 'cafe'));
  perform t.work();
  perform t.eq((select status from materials where id = m), 'awaiting_author', 'foreign brand refused');
  perform t.eq(t.last_answer(), ellipsis(tpl('err.forbidden', '{}'), 190), 'refusal answered');
  delete from t.knobs;
end $$;

-- E. fix loop (GN-6): a forbidden word keeps failing -> 2 fix attempts -> card with the problem, no endless loop
do $$
declare
  b bigint := t.brand('bakery', array['telegram']);
  m bigint;
  v variants;
begin
  perform t.user(2201, b, 'manager');
  perform t.set('gen.text', '"Our bread is cheap and tasty"');
  perform t.msg(2201, 'Fresh sourdough every morning from 7.');
  m := t.flush(2201);
  perform t.no_errors();
  select v2.* into v from variants v2 join packages p on p.id = v2.package_id where p.material_id = m;
  perform t.eq(v.fix_attempts, 2, 'two fix attempts');
  perform t.eq(v.current_version, 3, 'generate + 2 fixes');
  perform t.eq(v.check_status, 'failed', 'required check failed');
  perform t.eq(v.status, 'pending_approval', 'still goes to the editor');
  perform t.ok(check_problems(v.id, v.current_version) like '%Forbidden words: cheap%', 'problem shown on the card');
  delete from t.knobs;
end $$;

-- F. extraction error (IN-7) rejects the material with a clear reason; empty media -> no material
do $$
declare
  m bigint;
begin
  perform t.set('extract.error', '"The PDF is password protected"');
  perform t.msg(2001, null, jsonb_build_object('document', jsonb_build_object('file_id', 'F1', 'file_unique_id', 'U1', 'file_name', 'a.pdf',
                                                                         'mime_type', 'application/pdf', 'file_size', 1000)));
  m := t.flush(2001);
  perform t.eq((select status from materials where id = m), 'rejected', 'rejected on extraction error');
  perform t.eq((select reject_reason from materials where id = m), 'The PDF is password protected', 'reason kept');
  delete from t.knobs;
  perform t.msg(2001, null, jsonb_build_object('sticker', jsonb_build_object('file_id', 'S')));
  perform t.work();
  perform t.eq(t.last_material(2001), m, 'sticker creates no material');
  perform t.ok(t.last_text(2001) like '%sticker%', 'unsupported content explained');
  perform t.msg(2001, null, jsonb_build_object('voice', jsonb_build_object('file_id', 'V', 'file_unique_id', 'VU', 'duration', 900, 'file_size', 10000)));
  perform t.work();
  perform t.eq(t.last_material(2001), m, 'too long voice creates no material');
end $$;

rollback;
