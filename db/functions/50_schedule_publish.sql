-- Scheduling (PB-1, PB-2), approval (AP-2), deadlines (AP-5), publishing at most once (PB-3..PB-8), stop switch (PB-9).

create or replace function brand_tz(p_brand bigint) returns text
language sql stable as $$ select timezone from brands where id = p_brand $$;

-- Occupied times on a platform: scheduled/published posts (+ soft-reserved proposals of pending variants, 12 #11).
create or replace function slot_taken_times(p_bp bigint, p_from timestamptz, p_to timestamptz, p_include_proposed boolean, p_exclude bigint)
returns setof timestamptz
language sql stable as $$
  select coalesce(v.published_at, v.scheduled_at) from variants v
  where v.brand_platform_id = p_bp and v.id is distinct from p_exclude
    and v.status in ('scheduled', 'publishing', 'published', 'rescheduled')
    and coalesce(v.published_at, v.scheduled_at) between p_from and p_to
  union all
  select v.proposed_at from variants v
  where p_include_proposed and v.brand_platform_id = p_bp and v.id is distinct from p_exclude
    and v.status in ('pending_approval', 'revising', 'approved') and v.proposed_at between p_from and p_to
$$;

-- Is this exact time allowed (daily limit + minimum interval)?
create or replace function slot_ok(p_bp bigint, p_at timestamptz, p_include_proposed boolean default false, p_exclude bigint default null) returns boolean
language plpgsql stable as $$
declare
  bp brand_platforms;
  v_tz text;
  v_day_start timestamptz;
  v_interval interval;
begin
  select * into bp from brand_platforms where id = p_bp;
  v_tz := brand_tz(bp.brand_id);
  v_day_start := date_trunc('day', p_at at time zone v_tz) at time zone v_tz;
  v_interval := make_interval(mins => coalesce((bp.schedule ->> 'min_interval_minutes')::int, 60));
  if (select count(*) from slot_taken_times(p_bp, v_day_start, v_day_start + interval '1 day' - interval '1 second', p_include_proposed, p_exclude))
     >= coalesce((bp.schedule ->> 'max_per_day')::int, 3) then
    return false;
  end if;
  return not exists (select 1 from slot_taken_times(p_bp, p_at - v_interval + interval '1 second', p_at + v_interval - interval '1 second',
                                                    p_include_proposed, p_exclude));
end $$;

-- Next free slot from the platform schedule in the brand time zone (DST handled by AT TIME ZONE).
create or replace function next_free_slot(p_bp bigint, p_after timestamptz, p_include_proposed boolean default false, p_exclude bigint default null)
returns timestamptz
language plpgsql stable as $$
declare
  bp brand_platforms;
  v_tz text;
  v_day date;
  v_slots jsonb;
  v_cand timestamptz;
  d int;
  t text;
begin
  select * into bp from brand_platforms where id = p_bp;
  v_tz := brand_tz(bp.brand_id);
  v_slots := coalesce(nullif(bp.schedule -> 'slots', '[]'::jsonb), '[{"days":[1,2,3,4,5,6,7],"times":["10:00"]}]');
  for d in 0..62 loop
    v_day := (p_after at time zone v_tz)::date + d;
    for t in
      select distinct tm from jsonb_array_elements(v_slots) s, jsonb_array_elements_text(s -> 'times') tm
      where (s -> 'days') @> to_jsonb(extract(isodow from v_day)::int)
      order by tm
    loop
      v_cand := (v_day + t::time) at time zone v_tz;
      continue when v_cand < p_after;
      if slot_ok(p_bp, v_cand, p_include_proposed, p_exclude) then
        return v_cand;
      end if;
    end loop;
  end loop;
  return null;
end $$;

-- Next digest send time for an email platform: {"frequency":"weekly","day":5,"time":"10:00"} or daily.
create or replace function digest_next_send(p_bp bigint, p_after timestamptz) returns timestamptz
language plpgsql stable as $$
declare
  bp brand_platforms;
  v_tz text;
  v_day date;
  v_cand timestamptz;
  d int;
begin
  select * into bp from brand_platforms where id = p_bp;
  v_tz := brand_tz(bp.brand_id);
  for d in 0..14 loop
    v_day := (p_after at time zone v_tz)::date + d;
    continue when coalesce(bp.schedule ->> 'frequency', 'weekly') = 'weekly'
                  and extract(isodow from v_day)::int <> coalesce((bp.schedule ->> 'day')::int, 5);
    v_cand := (v_day + coalesce(bp.schedule ->> 'time', '10:00')::time) at time zone v_tz;
    if v_cand > p_after then
      return v_cand;
    end if;
  end loop;
  return null;
end $$;

-- Soft reservation shown on the card; reminders are anchored to it (AP-5).
create or replace function propose_slot(p_variant bigint) returns timestamptz
language plpgsql as $$
declare
  v variants;
  v_at timestamptz;
  r numeric;
begin
  select * into v from variants where id = p_variant for update;
  if v.status not in ('pending_approval', 'revising') then
    return v.proposed_at;
  end if;
  if v.platform = 'email' then
    v_at := digest_next_send(v.brand_platform_id, now() + make_interval(hours => coalesce(setting_num('digest.build_hours_before'), 2)::int));
  elsif v.slot_hint_at is not null and v.slot_hint_at > now() and slot_ok(v.brand_platform_id, v.slot_hint_at, true, v.id) then
    v_at := v.slot_hint_at;
  else
    v_at := next_free_slot(v.brand_platform_id, greatest(now() + interval '30 minutes', coalesce(v.slot_hint_at, now())), true, v.id);
  end if;
  update variants set proposed_at = v_at where id = v.id;
  if v_at is not null and v.platform <> 'email' then
    for r in select (jsonb_array_elements_text(coalesce(setting('approval.reminder_hours'), '[12,1]')))::numeric loop
      if v_at - make_interval(mins => (r * 60)::int) > now() then
        perform enqueue_job('variant.deadline', jsonb_build_object('kind', 'remind', 'hours', r, 'at', extract(epoch from v_at)::bigint),
                            null, v.package_id, v.id, p_dedupe => 'deadline:' || v.id || ':' || r || ':' || extract(epoch from v_at)::bigint,
                            p_run_after => v_at - make_interval(mins => (r * 60)::int));
      end if;
    end loop;
    perform enqueue_job('variant.deadline', jsonb_build_object('kind', 'missed', 'at', extract(epoch from v_at)::bigint),
                        null, v.package_id, v.id, p_dedupe => 'deadline:' || v.id || ':missed:' || extract(epoch from v_at)::bigint,
                        p_run_after => v_at);
  end if;
  return v_at;
end $$;

-- AP-5: remind at T-12h and T-1h; not approved by the slot -> not published, moved to the next free slot, editors told.
create or replace function variant_deadline(p_variant bigint, p_payload jsonb) returns jsonb
language plpgsql as $$
declare
  v variants;
  p packages;
  br brands;
  v_new timestamptz;
begin
  select * into v from variants where id = p_variant;
  select * into p from packages where id = v.package_id;
  select * into br from brands where id = p.brand_id;
  if v.status not in ('pending_approval', 'revising') or extract(epoch from v.proposed_at)::bigint <> (p_payload ->> 'at')::bigint then
    return job_flags();
  end if;
  if p_payload ->> 'kind' = 'remind' then
    perform notify_brand(br.id, array['manager', 'editor'], tpl('approval.reminder', jsonb_build_object(
      'platform', platform_label(v.platform), 'brand', br.name, 'material', mcode(p.material_id),
      'slot', fmt_local(v.proposed_at, br.timezone), 'hours', p_payload ->> 'hours')),
      kb(jsonb_build_array(btn('✅ Approve', 'ap:' || v.id || ':' || v.current_version), btn('📋 Open card', 'cv:' || p.id || ':' || v.id))),
      'remind:' || v.id || ':' || (p_payload ->> 'hours') || ':' || (p_payload ->> 'at'));
  else
    v_new := propose_slot(v.id);
    perform audit(null, 'variant.slot_missed', 'variant', v.id, br.id, p.material_id,
                  jsonb_build_object('missed', v.proposed_at, 'new', v_new));
    perform notify_brand(br.id, array['manager', 'editor'], tpl('approval.missed', jsonb_build_object(
      'platform', platform_label(v.platform), 'brand', br.name, 'material', mcode(p.material_id),
      'missed', fmt_local(v.proposed_at, br.timezone), 'next', coalesce(fmt_local(v_new, br.timezone), '—'))),
      null, 'missed:' || v.id || ':' || (p_payload ->> 'at'));
    perform package_try_card(p.id);
  end if;
  return job_flags();
end $$;

create or replace function approve_variant(p_variant bigint, p_actor bigint, p_auto boolean default false) returns boolean
language plpgsql as $$
declare
  v variants;
begin
  select * into v from variants where id = p_variant for update;
  if v.status <> 'pending_approval' then
    return false;
  end if;
  perform transition('variant', v.id, 'approved', p_actor, case when p_auto then 'auto' end);
  update variants set approved_by = p_actor, approved_at = now(), auto_approved = p_auto where id = v.id;
  -- AP-4: an approved redo closes the loop "comment -> result" in the brand feedback
  update feedback_examples set after_text = (select plain_text from variant_versions where variant_id = v.id and version = v.current_version)
   where variant_id = v.id and source = 'redo' and after_text is null;
  return true;
end $$;

-- PB-1/PB-2: author time if free, else next free slot; "now" on demand; email variants ride the next digest.
create or replace function schedule_variant(p_variant bigint, p_at timestamptz default null, p_actor bigint default null) returns timestamptz
language plpgsql as $$
declare
  v variants;
  p packages;
  v_at timestamptz;
begin
  select * into v from variants where id = p_variant for update;
  select * into p from packages where id = v.package_id;
  if v.status not in ('approved', 'failed', 'scheduled') then
    return null;
  end if;
  perform pg_advisory_xact_lock(v.brand_platform_id);
  if v.platform = 'email' and not p.is_guest then
    v_at := coalesce(p_at, digest_next_send(v.brand_platform_id, now() + make_interval(hours => coalesce(setting_num('digest.build_hours_before'), 2)::int)));
  elsif p_at is not null then
    v_at := p_at;
  elsif v.urgent then
    v_at := coalesce(next_free_slot(v.brand_platform_id, now(), false, v.id), now());
  elsif v.slot_hint_at is not null and v.slot_hint_at > now() then
    v_at := case when slot_ok(v.brand_platform_id, v.slot_hint_at, false, v.id) then v.slot_hint_at
                 else next_free_slot(v.brand_platform_id, v.slot_hint_at, false, v.id) end;
  elsif v.proposed_at is not null and v.proposed_at > now() and slot_ok(v.brand_platform_id, v.proposed_at, false, v.id) then
    v_at := v.proposed_at;
  else
    v_at := next_free_slot(v.brand_platform_id, now() + interval '2 minutes', false, v.id);
  end if;
  if v_at is null then
    v_at := now() + interval '1 day';
  end if;
  if v.status = 'scheduled' then
    perform transition('variant', v.id, 'rescheduled', p_actor);
  end if;
  update variants set scheduled_at = v_at, proposed_at = null, next_attempt_at = null where id = v.id;
  perform transition('variant', v.id, 'scheduled', p_actor, null, jsonb_build_object('at', v_at));
  return v_at;
end $$;

create or replace function blog_base_url(p_brand bigint) returns text
language sql stable as $$
  select coalesce('https://' || blog_domain, public_web_url() || '/b/' || slug) from brands where id = p_brand
$$;

create or replace function preview_url(p_variant bigint) returns text
language sql stable as $$ select public_web_url() || '/p/' || preview_token from variants where id = p_variant $$;

-- Invariant 9 in one place: preview platforms, guests and eval never reach real publishing adapters.
create or replace function publish_target(p_variant bigint) returns text
language sql stable as $$
  select case
    when p.is_guest or p.is_eval or bp.mode = 'preview' then 'preview'
    when v.platform = 'telegram' then 'telegram'
    when v.platform = 'blog' then 'blog'
    when v.platform = 'email' then 'email'
    else 'preview' end
  from variants v join packages p on p.id = v.package_id join brand_platforms bp on bp.id = v.brand_platform_id
  where v.id = p_variant
$$;

create or replace function is_paused(p_bp bigint) returns boolean
language sql stable as $$
  select exists (
    select 1 from system_pauses sp, brand_platforms bp
    where bp.id = p_bp and sp.resumed_at is null
      and (sp.scope = 'system' or (sp.scope = 'brand' and sp.brand_id = bp.brand_id) or (sp.scope = 'platform' and sp.brand_platform_id = bp.id)))
$$;

-- Publisher tick: due scheduled variants + due retries; pause checked in the same query (PB-9 <= 1 min).
-- Unknown outcomes (pending attempt too old) are surfaced to editors without auto-retry (PB-6).
create or replace function claim_publications(p_limit int default 10)
returns table (attempt_id bigint, variant_id bigint, adapter text, request jsonb)
language plpgsql as $$
declare
  r record;
  v_attempt bigint;
  v_n int := 0;
begin
  for r in
    select a.id as attempt_id, a.variant_id from publish_attempts a
    where a.outcome = 'pending' and a.op = 'publish'
      and a.started_at < now() - make_interval(secs => coalesce(setting_num('publish.unknown_after_seconds'), 180)::int)
    for update skip locked
  loop
    perform publish_result(r.attempt_id, 'unknown', null, null, null, 'no result recorded (crash or timeout)');
  end loop;

  for r in
    select v.id, v.status from variants v
    where ((v.status = 'scheduled' and v.scheduled_at <= now())
           or (v.status = 'publishing' and v.next_attempt_at is not null and v.next_attempt_at <= now()
               and not exists (select 1 from publish_attempts a where a.variant_id = v.id and a.outcome = 'pending')))
      and v.platform <> 'email'
      and not is_paused(v.brand_platform_id)
    order by v.scheduled_at
    limit p_limit
    for update of v skip locked
  loop
    if r.status = 'scheduled' then
      perform transition('variant', r.id, 'publishing', null);
      update variants set publish_first_attempt_at = now(), next_attempt_at = null where id = r.id;
    else
      update variants set next_attempt_at = null where id = r.id;
    end if;
    insert into publish_attempts (variant_id, adapter, idempotency_key)
    values (r.id, publish_target(r.id), 'pub:' || r.id || ':' || (select count(*) + 1 from publish_attempts pa where pa.variant_id = r.id))
    returning id into v_attempt;
    attempt_id := v_attempt;
    variant_id := r.id;
    adapter := publish_target(r.id);
    request := publish_request(r.id);
    v_n := v_n + 1;
    return next;
  end loop;
end $$;

-- What the adapter sends. Telegram: photo + caption (<=1024) or text (<=4096); text is plain, escaped here.
create or replace function publish_request(p_variant bigint) returns jsonb
language plpgsql stable as $$
declare
  v variants;
  vv variant_versions;
  bp brand_platforms;
  a assets;
  v_text text;
begin
  select * into v from variants where id = p_variant;
  select * into vv from variant_versions where variant_id = v.id and version = v.current_version;
  select * into bp from brand_platforms where id = v.brand_platform_id;
  select * into a from assets where id = variant_visual(v.id);
  v_text := coalesce(vv.content ->> 'text', vv.plain_text);
  return jsonb_build_object(
    'api_base', setting_text('api.telegram_base'),
    'bucket', setting_text('s3.bucket'),
    'chat_id', bp.target ->> 'chat_id',
    'method', case when a.id is not null then 'sendPhoto' else 'sendMessage' end,
    'text', h(ellipsis(v_text, case when a.id is not null then 1024 else 4096 end)),
    'photo_file_id', a.tg_file_id,
    'photo_s3_key', a.s3_key,
    'photo_asset_id', a.id,
    'photo_mime', a.mime);
end $$;

create or replace function notify_published(p_variant bigint) returns void
language plpgsql as $$
declare
  v variants;
  p packages;
  br brands;
  m materials;
  v_text text;
begin
  select * into v from variants where id = p_variant;
  select * into p from packages where id = v.package_id;
  select * into br from brands where id = p.brand_id;
  select * into m from materials where id = p.material_id;
  v_text := tpl(case when publish_target(v.id) = 'preview' then 'published.preview' else 'published.real' end,
                jsonb_build_object('platform', platform_label(v.platform), 'brand', br.name, 'material', mcode(m.id),
                                   'url', coalesce(v.external_url, '')));
  if p.is_guest then
    return;  -- guests get their preview card, no notifications
  end if;
  if m.author_user_id is not null and not exists (select 1 from memberships where user_id = m.author_user_id and brand_id = br.id and role in ('manager', 'editor')) then
    perform tg_send(m.author_user_id, v_text, null, 'published:' || v.id || ':author',
                    case when (select notify_published from users where id = m.author_user_id) = 'batch'
                         then jsonb_build_object('batch_key', 'published:' || m.author_user_id,
                                                 'send_after', now() + make_interval(mins => coalesce(setting_num('notify.published_batch_minutes'), 15)::int))
                         else '{}'::jsonb end);
  end if;
  perform notify_brand(br.id, array['manager', 'editor'], v_text, null, 'published:' || v.id, true);
end $$;

-- Adapter result (PB-4..PB-6). failed -> retries with backoff for 30 min, then 'failed' + buttons; unknown -> no auto retry.
create or replace function publish_result(p_attempt bigint, p_outcome text, p_http int, p_external_id text, p_external_url text,
                                          p_error text default null, p_tg_file_id text default null) returns jsonb
language plpgsql as $$
declare
  a publish_attempts;
  v variants;
  p packages;
  br brands;
  v_backoff int[] := array[30, 60, 120, 300, 600];
  v_failures int;
begin
  select * into a from publish_attempts where id = p_attempt for update;
  if a.id is null or a.outcome <> 'pending' then
    return job_flags();
  end if;
  update publish_attempts set outcome = p_outcome, http_status = p_http, external_id = p_external_id,
                              external_url = p_external_url, error = left(p_error, 2000), finished_at = now()
   where id = a.id;
  select * into v from variants where id = a.variant_id for update;
  select * into p from packages where id = v.package_id;
  select * into br from brands where id = p.brand_id;
  if p_tg_file_id is not null then
    update assets set tg_file_id = p_tg_file_id where id = variant_visual(v.id) and tg_file_id is null;
  end if;

  if a.op <> 'publish' then
    return job_flags();
  end if;
  if p_outcome = 'ok' then
    update variants set published_at = now(), external_id = p_external_id, external_url = p_external_url, next_attempt_at = null where id = v.id;
    perform transition('variant', v.id, 'published', null, a.adapter, jsonb_build_object('url', p_external_url));
    perform notify_published(v.id);
    perform package_try_card(p.id);
  elsif p_outcome = 'failed' then
    select count(*) into v_failures from publish_attempts where variant_id = v.id and outcome = 'failed' and op = 'publish';
    if now() - coalesce(v.publish_first_attempt_at, now()) < make_interval(mins => coalesce(setting_num('publish.retry_window_minutes'), 30)::int) then
      update variants set next_attempt_at = now() + make_interval(secs => v_backoff[least(v_failures, 5)]) where id = v.id;
    else
      perform transition('variant', v.id, 'failed', null, p_error);
      perform notify_brand(br.id, array['manager', 'editor'], tpl('publish.failed', jsonb_build_object(
          'platform', platform_label(v.platform), 'brand', br.name, 'material', mcode(p.material_id), 'error', ellipsis(p_error, 300))),
        kb(jsonb_build_array(btn('🔁 Retry', 'pr:' || v.id), btn('🕘 Next slot', 'ps:' || v.id), btn('✖ Cancel', 'pc:' || v.id))),
        'pubfail:' || v.id || ':' || a.id);
      perform package_try_card(p.id);
    end if;
  else  -- unknown
    update variants set next_attempt_at = null where id = v.id;
    perform notify_brand(br.id, array['manager', 'editor'], tpl('publish.unknown', jsonb_build_object(
        'platform', platform_label(v.platform), 'brand', br.name, 'material', mcode(p.material_id),
        'target', coalesce((select target ->> 'chat_id' from brand_platforms where id = v.brand_platform_id), ''))),
      kb(jsonb_build_array(btn('✅ It is published', 'pm:' || v.id), btn('🔁 Publish again', 'pr:' || v.id))),
      'pubunknown:' || v.id || ':' || a.id);
  end if;
  return job_flags();
end $$;

-- Local adapters: blog (the post becomes visible on the brand site — idempotent by construction) and preview.
create or replace function publish_local(p_attempt bigint) returns jsonb
language plpgsql as $$
declare
  a publish_attempts;
  v variants;
  vv variant_versions;
  p packages;
  v_url text;
begin
  select * into a from publish_attempts where id = p_attempt;
  select * into v from variants where id = a.variant_id;
  select * into vv from variant_versions where variant_id = v.id and version = v.current_version;
  select * into p from packages where id = v.package_id;
  v_url := case when a.adapter = 'blog' then blog_base_url(p.brand_id) || '/' || coalesce(vv.content ->> 'slug', 'post-' || v.id)
                else preview_url(v.id) end;
  return publish_result(a.id, 'ok', null, case when a.adapter = 'blog' then vv.content ->> 'slug' else v.preview_token::text end, v_url);
end $$;

-- Stop switch (PB-9).
create or replace function pause_create(p_actor bigint, p_scope text, p_brand bigint, p_bp bigint, p_reason text) returns bigint
language plpgsql as $$
declare
  v_id bigint;
begin
  if (p_scope = 'system' and not can(p_actor, null, 'admin'))
     or (p_scope <> 'system' and not can(p_actor, coalesce(p_brand, (select brand_id from brand_platforms where id = p_bp)), 'pause')) then
    raise exception 'forbidden';
  end if;
  select id into v_id from system_pauses
  where resumed_at is null and scope = p_scope and brand_id is not distinct from p_brand and brand_platform_id is not distinct from p_bp;
  if v_id is null then
    insert into system_pauses (scope, brand_id, brand_platform_id, reason, paused_by)
    values (p_scope, case when p_scope = 'platform' then (select brand_id from brand_platforms where id = p_bp) else p_brand end,
            p_bp, p_reason, p_actor)
    returning id into v_id;
    perform audit(p_actor, 'pause.created', 'pause', v_id, p_brand, null, jsonb_build_object('scope', p_scope, 'brand_platform_id', p_bp));
  end if;
  return v_id;
end $$;

create or replace function pause_resume(p_actor bigint, p_pause bigint, p_mode text) returns int
language plpgsql as $$
declare
  sp system_pauses;
  v record;
  n int := 0;
begin
  select * into sp from system_pauses where id = p_pause for update;
  if sp.id is null or sp.resumed_at is not null then
    return 0;
  end if;
  if (sp.scope = 'system' and not can(p_actor, null, 'admin')) or (sp.scope <> 'system' and not can(p_actor, sp.brand_id, 'pause')) then
    raise exception 'forbidden';
  end if;
  update system_pauses set resumed_at = now(), resumed_by = p_actor, resume_mode = p_mode where id = sp.id;
  if p_mode = 'reschedule' then
    for v in
      select vr.id from variants vr join brand_platforms bp on bp.id = vr.brand_platform_id
      where vr.status = 'scheduled' and vr.scheduled_at < now() and vr.platform <> 'email'
        and (sp.scope = 'system' or (sp.scope = 'brand' and bp.brand_id = sp.brand_id) or (sp.scope = 'platform' and bp.id = sp.brand_platform_id))
        and not is_paused(bp.id)
      order by vr.scheduled_at
    loop
      perform transition('variant', v.id, 'rescheduled', p_actor, 'pause lifted');
      update variants set scheduled_at = coalesce(next_free_slot(brand_platform_id, now() + interval '2 minutes', false, id), now() + interval '1 day') where id = v.id;
      perform transition('variant', v.id, 'scheduled', p_actor);
      n := n + 1;
    end loop;
  end if;
  perform audit(p_actor, 'pause.resumed', 'pause', sp.id, sp.brand_id, null, jsonb_build_object('mode', p_mode, 'rescheduled', n));
  return n;
end $$;

-- PB-7: edit or delete an already published post. Telegram is called by CORE · Post ops; the blog reads the current
-- version, so a blog edit needs no call and a blog delete only hides the post.
create or replace function post_op_context(p_job bigint) returns jsonb
language plpgsql stable as $$
declare
  j jobs;
  v variants;
  vv variant_versions;
  v_target text;
  v_photo bigint;
  v_text text;
begin
  select * into j from jobs where id = p_job;
  select * into v from variants where id = j.variant_id;
  select * into vv from variant_versions where variant_id = v.id and version = v.current_version;
  v_target := publish_target(v.id);
  v_photo := variant_visual(v.id);
  v_text := h(ellipsis(coalesce(vv.content ->> 'text', vv.plain_text), case when v_photo is null then 4096 else 1024 end));
  return jsonb_build_object(
    'skip', v.status <> 'published' or v.external_deleted_at is not null or v_target not in ('telegram', 'blog'),
    'op', j.payload ->> 'op', 'adapter', v_target, 'variant_id', v.id, 'api_base', setting_text('api.telegram_base'),
    'method', case when v_target <> 'telegram' then null
                   when j.payload ->> 'op' = 'delete' then 'deleteMessage'
                   when v_photo is null then 'editMessageText' else 'editMessageCaption' end,
    'body', jsonb_strip_nulls(jsonb_build_object(
      'chat_id', split_part(v.external_id, ':', 1), 'message_id', nullif(split_part(v.external_id, ':', 2), '')::bigint,
      'text', case when j.payload ->> 'op' = 'edit' and v_photo is null then v_text end,
      'caption', case when j.payload ->> 'op' = 'edit' and v_photo is not null then v_text end,
      'parse_mode', case when j.payload ->> 'op' = 'edit' then 'HTML' end)));
end $$;

create or replace function post_op_result(p_job bigint, p_ok boolean, p_http int default null, p_error text default null) returns jsonb
language plpgsql as $$
declare
  j jobs;
  v variants;
  p packages;
  v_op text;
begin
  select * into j from jobs where id = p_job;
  select * into v from variants where id = j.variant_id for update;
  select * into p from packages where id = v.package_id;
  v_op := j.payload ->> 'op';
  insert into publish_attempts (variant_id, op, adapter, idempotency_key, outcome, http_status, error, finished_at)
  values (v.id, v_op, publish_target(v.id), 'postop:' || j.id, case when p_ok then 'ok' else 'failed' end, p_http, left(p_error, 2000), now())
  on conflict (idempotency_key) do nothing;
  if p_ok and v_op = 'delete' then
    update variants set external_deleted_at = now() where id = v.id;
  end if;
  perform audit((j.payload ->> 'user_id')::bigint, 'variant.post_' || v_op, 'variant', v.id, p.brand_id, p.material_id,
                jsonb_build_object('ok', p_ok, 'error', p_error));
  if not p_ok then
    perform notify_brand(p.brand_id, array['manager', 'editor'], tpl('publish.op_failed', jsonb_build_object(
      'op', v_op, 'platform', platform_label(v.platform), 'material', mcode(p.material_id), 'error', ellipsis(coalesce(p_error, ''), 300))),
      null, 'postop_failed:' || j.id);
  end if;
  perform package_try_card(p.id);
  return job_flags();
end $$;
