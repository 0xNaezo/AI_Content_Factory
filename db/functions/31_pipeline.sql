-- Pipeline decisions: summary -> duplicates/clarification -> brand -> packages -> generation -> checks -> visuals.
-- n8n handlers call these once per step; each call is idempotent and enqueues the next step.

create or replace function active_profile(p_brand bigint) returns jsonb
language sql stable as $$
  select profile from brand_profile_versions where brand_id = p_brand and status = 'active'
$$;

-- Which AI budget pays (architecture 7.13, 12 #10): eval / guest / brand after routing / system before routing.
create or replace function account_of(p_material bigint, p_brand bigint default null) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'account_type', case when m.is_eval then 'eval' when m.is_guest then 'guest' when p_brand is not null then 'brand' else 'system' end,
    'brand_id', p_brand)
  from materials m where m.id = p_material
$$;

-- Source text assembled from parts with labels (the summary and generation see the same text).
create or replace function material_text(p_material bigint) returns text
language sql stable as $$
  select string_agg(
    '[' || case kind
      when 'text' then 'Text'
      when 'voice' then 'Voice message transcript'
      when 'audio' then 'Audio transcript'
      when 'image' then 'Image description (the image itself is available as a visual)'
      when 'pdf' then 'PDF ' || coalesce(file_name, '')
      when 'docx' then 'Document ' || coalesce(file_name, '')
      when 'url' then 'Web page ' || coalesce(url, '')
      when 'clarification' then 'Author clarification'
      else kind end || ']' || E'\n' || trim(extracted_text),
    E'\n\n' order by ord)
  from material_parts where material_id = p_material and coalesce(trim(extracted_text), '') <> ''
$$;

create or replace function normalize_text(p text) returns text
language sql immutable as $$ select regexp_replace(lower(coalesce(p, '')), '[^[:alnum:]]+', ' ', 'g') $$;

create or replace function summarize_context(p_material bigint) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'material_id', m.id, 'revision', m.revision, 'skip', m.status not in ('received', 'awaiting_author'),
    'vars', jsonb_build_object(
      'source_text', left(material_text(m.id), 120000),
      'author_brands', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'slug', slug)) from user_submit_brands(m.author_user_id)), '[]'),
      'today_utc', to_char(now() at time zone 'UTC', 'YYYY-MM-DD Dy HH24:MI')),
    'material_id_ref', m.id) || account_of(m.id)
  from materials m where m.id = p_material
$$;

-- IN-6: exact (text hash, same file) or near (trigram) duplicate among the author's and their brands' materials.
create or replace function find_duplicate(p_material bigint) returns bigint
language plpgsql as $$
declare
  m materials;
  e material_extracts;
  v_dup bigint;
  v_days int := coalesce(setting_num('intake.duplicate_days'), 30)::int;
begin
  select * into m from materials where id = p_material;
  select * into e from material_extracts where material_id = p_material;
  perform set_config('pg_trgm.similarity_threshold', coalesce(setting_text('intake.duplicate_similarity'), '0.85'), true);
  select o.id into v_dup
  from materials o
  left join material_extracts oe on oe.material_id = o.id
  where o.id <> m.id and o.created_at > now() - make_interval(days => v_days)
    and o.status <> 'rejected' and not o.is_container and not o.is_eval and o.duplicate_of is null
    and (o.author_user_id = m.author_user_id
         or exists (select 1 from packages pk where pk.material_id = o.id
                    and pk.brand_id in (select brand_id from user_submit_brands(m.author_user_id))))
    and (o.text_hash = m.text_hash
         or exists (select 1 from material_parts a join material_parts b on a.tg_file_unique_id = b.tg_file_unique_id
                    where a.material_id = m.id and b.material_id = o.id)
         or (oe.text_prefix % e.text_prefix))
  order by o.id desc limit 1;
  return v_dup;
end $$;

create or replace function question_keyboard(p_material bigint, p_type text) returns jsonb
language plpgsql stable as $$
declare
  m materials;
  v_buttons jsonb;
begin
  select * into m from materials where id = p_material;
  if p_type = 'duplicate' then
    return kb(jsonb_build_array(btn('➕ Create new', 'qdn:' || m.id), btn('✖ Cancel', 'qdx:' || m.id)));
  elsif p_type = 'clarify' then
    return kb(jsonb_build_array(btn('⏭ Skip — use what I sent', 'qcs:' || m.id)));
  elsif p_type = 'brand_multi' then
    select jsonb_agg(btn(case when (m.question -> 'selected') @> to_jsonb(b.brand_id) then '✅ ' else '▫️ ' end || b.name,
                         'qbt:' || m.id || ':' || b.brand_id) order by b.name)
      into v_buttons from user_submit_brands(m.author_user_id) b;
    return kb_grid(v_buttons, 2) || kb(jsonb_build_array(btn('✔ Create packages', 'qbc:' || m.id), btn('✖ Cancel', 'qox:' || m.id)));
  elsif p_type = 'brand_all' or p_type = 'offtopic' then
    select jsonb_agg(btn(b.name, 'qb:' || m.id || ':' || b.brand_id) order by b.name) into v_buttons from user_submit_brands(m.author_user_id) b;
    return kb_grid(v_buttons, 2) || kb(jsonb_build_array(btn('➕ Several brands', 'qbm:' || m.id), btn('✖ Cancel', 'qox:' || m.id)));
  else -- brand: top-3 + other + several + cancel (RT-2)
    select jsonb_agg(btn(b.name || ' · ' || round(coalesce((r ->> 'confidence')::numeric, 0) * 100) || '%', 'qb:' || m.id || ':' || b.id) order by ord)
      into v_buttons
    from jsonb_array_elements(coalesce(m.question -> 'top', '[]')) with ordinality as t(r, ord)
    join brands b on b.slug = r ->> 'brand';
    return kb_grid(coalesce(v_buttons, '[]'), 1)
        || kb(jsonb_build_array(btn('Other…', 'qbo:' || m.id), btn('➕ Several', 'qbm:' || m.id), btn('✖ Cancel', 'qox:' || m.id)));
  end if;
end $$;

-- One question at a time; the question message is new (so the author gets a notification), the ack shows "waiting".
create or replace function ask_author(p_material bigint, p_question jsonb) returns void
language plpgsql as $$
declare
  m materials;
  v_text text;
  v_type text := p_question ->> 'type';
begin
  select * into m from materials where id = p_material for update;
  update materials set question = p_question || jsonb_build_object('asked_at', now(), 'revision', m.revision),
                       hints = jsonb_set(hints, '{asked}', coalesce(hints -> 'asked', '[]') || to_jsonb(v_type))
   where id = m.id;
  if m.status = 'parsed' then
    perform transition('material', m.id, 'awaiting_author', null, v_type);
  end if;
  v_text := case v_type
    when 'duplicate' then tpl('q.duplicate', jsonb_build_object('material', mcode(m.id), 'original', mcode((p_question ->> 'of')::bigint),
                              'date', to_char((select created_at from materials where id = (p_question ->> 'of')::bigint), 'DD Mon YYYY')))
    when 'clarify' then tpl('q.clarify', jsonb_build_object('material', mcode(m.id), 'question', p_question ->> 'text',
                              'hours', round(coalesce(setting_num('extract.clarify_timeout_minutes'), 120) / 60.0, 1)))
    when 'offtopic' then tpl('q.offtopic', jsonb_build_object('material', mcode(m.id), 'reason', coalesce(p_question ->> 'reason', '')))
    else tpl('q.brand', jsonb_build_object('material', mcode(m.id),
                              'idea', ellipsis((select summary ->> 'main_idea' from material_extracts where material_id = m.id), 200)))
  end;
  if m.source = 'email' then
    v_text := v_text || E'\n\n' || tpl('q.email_note', '{}');
  end if;
  perform tg_slot('q:' || m.id, coalesce(m.chat_id, (select tg_chat_id from users where id = m.author_user_id)), v_text,
                  question_keyboard(m.id, case when v_type in ('offtopic') then 'offtopic' else v_type end), null, m.author_user_id, m.id, 5);
  if v_type = 'clarify' then
    insert into bot_sessions (user_id, kind, data, expires_at)
    values (m.author_user_id, 'clarify', jsonb_build_object('material_id', m.id),
            now() + make_interval(mins => coalesce(setting_num('extract.clarify_timeout_minutes'), 120)::int))
    on conflict (user_id) do update set kind = excluded.kind, data = excluded.data, expires_at = excluded.expires_at, created_at = now();
    perform enqueue_job('material.clarify_timeout', jsonb_build_object('revision', m.revision), m.id,
                        p_dedupe => 'clarify_timeout:' || m.id || ':' || m.revision,
                        p_run_after => now() + make_interval(mins => coalesce(setting_num('extract.clarify_timeout_minutes'), 120)::int));
  end if;
  perform render_ack(m.id);
end $$;

create or replace function close_question(p_material bigint) returns void
language plpgsql as $$
declare
  m materials;
begin
  select * into m from materials where id = p_material;
  update materials set question = null where id = p_material;
  delete from bot_sessions where kind = 'clarify' and (data ->> 'material_id')::bigint = p_material;
  perform tg_slot('q:' || m.id, coalesce(m.chat_id, (select tg_chat_id from users where id = m.author_user_id)),
                  tpl('q.answered', jsonb_build_object('material', mcode(m.id))), '[]'::jsonb, null, m.author_user_id, m.id);
end $$;

-- After questions are resolved: remaining checks in order (duplicate -> sufficiency) then routing.
create or replace function material_continue(p_material bigint) returns void
language plpgsql as $$
declare
  m materials;
  e material_extracts;
  v_dup bigint;
begin
  select * into m from materials where id = p_material for update;
  select * into e from material_extracts where material_id = m.id;
  if m.status not in ('parsed', 'awaiting_author') or e.material_id is null then
    return;
  end if;
  if not m.is_eval and m.source <> 'table_row' and not coalesce(m.hints -> 'asked', '[]') ? 'duplicate' then
    v_dup := find_duplicate(m.id);
    if v_dup is not null then
      perform ask_author(m.id, jsonb_build_object('type', 'duplicate', 'of', v_dup));
      return;
    end if;
  end if;
  if not e.sufficient then
    if not m.is_eval and m.source <> 'table_row' and not coalesce(m.hints -> 'asked', '[]') ? 'clarify'
       and coalesce(e.summary ->> 'clarifying_question', '') <> '' then
      perform ask_author(m.id, jsonb_build_object('type', 'clarify', 'text', e.summary ->> 'clarifying_question'));
      return;
    end if;
    update materials set low_data = true where id = m.id;
  end if;
  perform enqueue_job('material.route', '{}', m.id, p_dedupe => 'route:' || m.id || ':' || m.revision);
end $$;

-- Summary result (EX-2..EX-4). Guest moderation rejects before anything is generated (tz section 10).
create or replace function save_summary(p_material bigint, p_revision int, p_summary jsonb) returns jsonb
language plpgsql as $$
declare
  m materials;
  v_text text := material_text(p_material);
  v_hints jsonb;
begin
  select * into m from materials where id = p_material for update;
  if m.id is null or m.revision <> p_revision or m.status not in ('received', 'awaiting_author') then
    return job_flags();
  end if;
  insert into material_extracts (material_id, revision, text, text_prefix, language, summary, sufficient)
  values (m.id, m.revision, v_text, left(v_text, 4000), p_summary ->> 'language', p_summary,
          coalesce((p_summary ->> 'sufficient')::boolean, true))
  on conflict (material_id) do update set revision = excluded.revision, text = excluded.text, text_prefix = excluded.text_prefix,
    language = excluded.language, summary = excluded.summary, sufficient = excluded.sufficient, created_at = now();
  v_hints := p_summary -> 'hints';
  update materials set
    text_hash = md5(normalize_text(v_text)),
    hints = hints
      || case when not hints ? 'platforms' and jsonb_array_length(coalesce(v_hints -> 'platforms', '[]')) > 0
              then jsonb_build_object('platforms', v_hints -> 'platforms') else '{}' end
      || case when not hints ? 'publish_at_local' and coalesce(v_hints ->> 'publish_at', '') ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}'
              then jsonb_build_object('publish_at_local', left(v_hints ->> 'publish_at', 16)) else '{}' end
      || case when coalesce((v_hints ->> 'digest_only')::boolean, false) then '{"digest_only": true}'::jsonb else '{}'::jsonb end
      || case when coalesce((v_hints ->> 'urgent')::boolean, false) then '{"urgent": true}'::jsonb else '{}'::jsonb end
      || case when coalesce(v_hints ->> 'tone', '') <> '' then jsonb_build_object('tone', v_hints ->> 'tone') else '{}' end
      || case when jsonb_array_length(coalesce(v_hints -> 'brands', '[]')) > 0 then jsonb_build_object('brand_names', v_hints -> 'brands') else '{}' end
  where id = m.id;
  perform audit(null, 'material.summarized', 'material', m.id, null, m.id,
                jsonb_build_object('language', p_summary ->> 'language', 'sufficient', p_summary -> 'sufficient', 'revision', m.revision));

  if m.is_guest and coalesce((p_summary #>> '{moderation,flagged}')::boolean, false) then
    perform material_reject(m.id, tpl('guest.rejected_content', jsonb_build_object('reason', coalesce(p_summary #>> '{moderation,reason}', ''))));
    return job_flags();
  end if;
  if m.status = 'received' then
    perform transition('material', m.id, 'parsed', null, 'summary ready');
  end if;
  perform render_ack(m.id);
  perform material_continue(m.id);
  return job_flags();
end $$;

-- RT-1: explicit hint -> single brand -> classifier. Only the author's brands are candidates (isolation).
create or replace function route_context(p_material bigint) returns jsonb
language plpgsql stable as $$
declare
  m materials;
  e material_extracts;
  v_allowed bigint[];
  v_ids bigint[];
  v_method text;
  v_case eval_cases;
begin
  select * into m from materials where id = p_material;
  select * into e from material_extracts where material_id = m.id;
  if m.status not in ('parsed', 'awaiting_author') then
    return jsonb_build_object('skip', true);
  end if;
  if m.is_guest then
    select array_agg(id) into v_allowed from brands where id = (select guest_brand_id from users where id = m.author_user_id);
  elsif m.is_eval then
    select * into v_case from eval_cases where id = m.eval_case_id;
    select array_agg(id) into v_allowed from brands where is_demo and status = 'active';
  else
    select array_agg(brand_id) into v_allowed from user_submit_brands(m.author_user_id);
  end if;
  if coalesce(cardinality(v_allowed), 0) = 0 then
    return jsonb_build_object('reject', tpl('route.no_brands', '{}'));
  end if;

  if m.is_eval and v_case.kind = 'generation' then
    v_ids := array(select id from brands where slug = v_case.brand_slug);
    v_method := 'eval';
  elsif m.is_guest then
    v_ids := v_allowed;
    v_method := 'guest';
  elsif jsonb_array_length(coalesce(m.hints -> 'brand_ids', '[]')) > 0 then
    v_ids := array(select x::bigint from jsonb_array_elements_text(m.hints -> 'brand_ids') x where x::bigint = any (v_allowed));
    v_method := case when m.source = 'table_row' then 'table' else 'hint' end;
  elsif jsonb_array_length(coalesce(m.hints -> 'brand_names', '[]')) > 0 then
    v_ids := array(select distinct b.id from brands b, jsonb_array_elements_text(m.hints -> 'brand_names') n
                   where b.id = any (v_allowed)
                     and (lower(b.name) = lower(n) or b.slug = lower(n) or similarity(lower(b.name), lower(n)) > 0.6));
    v_method := 'hint';
  end if;
  if coalesce(cardinality(v_ids), 0) = 0 and cardinality(v_allowed) = 1 and not m.is_eval then
    v_ids := v_allowed;
    v_method := 'single_brand';
  end if;
  if coalesce(cardinality(v_ids), 0) > 0 then
    return jsonb_build_object('decided', to_jsonb(v_ids), 'method', v_method);
  end if;

  return jsonb_build_object('classify', true, 'vars', jsonb_build_object(
      'material', jsonb_build_object('main_idea', e.summary -> 'main_idea', 'key_points', e.summary -> 'key_points',
                                     'excerpt', left(e.text, 3000)),
      'brands', (select jsonb_agg(jsonb_build_object(
                    'slug', b.slug, 'name', b.name,
                    'niche', pv.profile #>> '{basics,niche}', 'description', pv.profile #>> '{basics,description}',
                    'audience', pv.profile #>> '{basics,audience}', 'topics', pv.profile #> '{basics,topics}',
                    'examples', (select coalesce(jsonb_agg(ex ->> 'text'), '[]') from (
                        select ex from jsonb_array_elements(coalesce(pv.profile #> '{examples,good}', '[]')) ex limit 2) s))
                  order by b.slug)
                 from brands b join brand_profile_versions pv on pv.brand_id = b.id and pv.status = 'active'
                 where b.id = any (v_allowed))))
    || account_of(m.id);
end $$;

-- RT-2/RT-4 decision from the classifier ranking.
create or replace function route_decide(p_material bigint, p_result jsonb) returns jsonb
language plpgsql as $$
declare
  m materials;
  v_threshold numeric := coalesce(setting_num('route.confidence_threshold'), 0.75);
  v_top jsonb;
  v_ranking jsonb;
  v_brand bigint;
begin
  select * into m from materials where id = p_material for update;
  if m.status not in ('parsed', 'awaiting_author') then
    return job_flags();
  end if;
  select coalesce(jsonb_agg(r order by (r ->> 'confidence')::numeric desc), '[]') into v_ranking
  from jsonb_array_elements(coalesce(p_result -> 'ranking', '[]')) r
  where exists (select 1 from brands b where b.slug = r ->> 'brand');
  v_top := v_ranking -> 0;

  if m.is_eval then
    update eval_results set metrics = metrics || jsonb_build_object('routed_to', v_top ->> 'brand',
             'confidence', v_top -> 'confidence', 'off_topic', p_result -> 'off_topic')
     where material_id = m.id;
    perform material_reject(m.id, 'eval routing case finished');
    perform eval_try_finalize(m.id);
    return job_flags();
  end if;

  if coalesce((p_result ->> 'off_topic')::boolean, false) and coalesce((v_top ->> 'confidence')::numeric, 0) < v_threshold then
    perform ask_author(m.id, jsonb_build_object('type', 'offtopic', 'reason', p_result ->> 'reason', 'ranking', v_ranking));
  elsif coalesce((v_top ->> 'confidence')::numeric, 0) >= v_threshold then
    select id into v_brand from brands where slug = v_top ->> 'brand';
    perform route_apply(m.id, array[v_brand], 'classifier', null, (v_top ->> 'confidence')::numeric, v_ranking);
  else
    perform ask_author(m.id, jsonb_build_object('type', 'brand', 'top', (select jsonb_agg(x) from (
      select x from jsonb_array_elements(v_ranking) x limit 3) s), 'ranking', v_ranking));
  end if;
  return job_flags();
end $$;

-- Material -> one package per brand (RT-3), variants per active platform (GN-1).
create or replace function route_apply(p_material bigint, p_brands bigint[], p_method text, p_actor bigint default null,
                                       p_confidence numeric default null, p_ranking jsonb default null) returns jsonb
language plpgsql as $$
declare
  m materials;
  b bigint;
begin
  select * into m from materials where id = p_material for update;
  if m.status not in ('parsed', 'awaiting_author') or coalesce(cardinality(p_brands), 0) = 0 then
    return job_flags();
  end if;
  if m.question is not null then
    perform close_question(m.id);
  end if;
  perform transition('material', m.id, 'routed', p_actor, p_method, jsonb_build_object('brands', p_brands));
  foreach b in array p_brands loop
    insert into material_routes (material_id, brand_id, method, confidence, decided_by, ranking)
    values (m.id, b, p_method, p_confidence, p_actor, p_ranking) on conflict do nothing;
    perform create_package(m.id, b);
  end loop;
  perform render_ack(m.id);
  return job_flags();
end $$;

create or replace function local_to_tz(p_local text, p_tz text) returns timestamptz
language sql immutable as $$
  select case when p_local ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}' then (left(p_local, 16)::timestamp at time zone p_tz) end
$$;

create or replace function create_package(p_material bigint, p_brand bigint, p_redirected_from bigint default null) returns bigint
language plpgsql as $$
declare
  m materials;
  br brands;
  v_version int;
  v_pkg bigint;
  v_variant bigint;
  bp brand_platforms;
  v_platforms jsonb;
  v_n int := 0;
begin
  select * into m from materials where id = p_material;
  select * into br from brands where id = p_brand;
  select version into v_version from brand_profile_versions where brand_id = p_brand and status = 'active';
  if v_version is null then
    perform author_notify(m.id, tpl('route.brand_not_ready', jsonb_build_object('brand', br.name)));
    return null;
  end if;
  insert into packages (material_id, brand_id, profile_version, is_guest, is_eval, low_data, redirected_from)
  values (m.id, p_brand, v_version, m.is_guest, m.is_eval, m.low_data, p_redirected_from)
  on conflict (material_id, brand_id) where cancelled_at is null do nothing
  returning id into v_pkg;
  if v_pkg is null then
    return null;
  end if;
  v_platforms := coalesce(m.hints -> 'platforms', '[]');
  for bp in
    select * from brand_platforms
    where brand_id = p_brand and is_active
      and (not coalesce((m.hints ->> 'digest_only')::boolean, false) or platform = 'email')
      and (jsonb_array_length(v_platforms) = 0 or v_platforms ? platform or coalesce((m.hints ->> 'digest_only')::boolean, false))
    order by array_position(array['telegram', 'blog', 'email', 'linkedin', 'instagram', 'facebook', 'x'], platform), language
  loop
    insert into variants (package_id, brand_platform_id, platform, slot_hint_at, urgent)
    values (v_pkg, bp.id, bp.platform, local_to_tz(m.hints ->> 'publish_at_local', br.timezone),
            coalesce((m.hints ->> 'urgent')::boolean, false))
    returning id into v_variant;
    perform enqueue_job('variant.generate', jsonb_build_object('mode', 'generate'), m.id, v_pkg, v_variant, p_brand,
                        p_dedupe => 'gen:' || v_variant || ':1', p_priority => case when m.is_guest then 0 else 1 end);
    v_n := v_n + 1;
  end loop;
  perform audit(null, 'package.created', 'package', v_pkg, p_brand, m.id,
                jsonb_build_object('variants', v_n, 'profile_version', v_version, 'redirected_from', p_redirected_from));
  if v_n = 0 then
    update packages set cancelled_at = now(), visual_status = 'skipped' where id = v_pkg;
    perform author_notify(m.id, tpl('route.no_platforms', jsonb_build_object('brand', br.name, 'material', mcode(m.id))));
    return v_pkg;
  end if;
  perform enqueue_job('package.visual', jsonb_build_object('mode', 'auto'), m.id, v_pkg, null, p_brand, p_dedupe => 'visual:' || v_pkg || ':auto');
  return v_pkg;
end $$;

-- Platform format = config/platforms.json merged with the brand profile override (tz section 6).
create or replace function platform_format(p_brand bigint, p_platform text, p_profile jsonb default null) returns jsonb
language sql stable as $$
  select f.spec
    || case when o ->> 'max_chars' is not null then jsonb_build_object('max_chars', (o ->> 'max_chars')::int) else '{}' end
    || case when o ->> 'notes' is not null then jsonb_build_object('brand_notes', o ->> 'notes') else '{}' end
    || case when o ->> 'image_aspect' is not null then jsonb_build_object('image', (f.spec -> 'image') || jsonb_build_object('default', o ->> 'image_aspect')) else '{}' end
  from platform_formats f
  left join lateral (select coalesce(p_profile, active_profile(p_brand)) #> array['platforms', p_platform] as o) x on true
  where f.platform = p_platform
$$;

create or replace function variant_aspect(p_variant bigint) returns text
language sql stable as $$
  select platform_format(p.brand_id, v.platform, pv.profile) #>> '{image,default}'
  from variants v join packages p on p.id = v.package_id
  join brand_profile_versions pv on pv.brand_id = p.brand_id and pv.version = p.profile_version
  where v.id = p_variant
$$;

-- Exact strings a variant must contain for its platform (tz BP-1 required elements), with UTM links resolved.
create or replace function required_elements(p_profile jsonb, p_platform text) returns jsonb
language sql stable as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'cta_phrases', case when (p_profile #> '{required_elements,cta,platforms}') ? p_platform then p_profile #> '{required_elements,cta,phrases}' end,
    'links', (select jsonb_agg(jsonb_build_object('label', l ->> 'label', 'url',
                (l ->> 'url') || case when l -> 'utm' ->> 'source' is null then '' else
                  (case when l ->> 'url' like '%?%' then '&' else '?' end) || concat_ws('&',
                    'utm_source=' || replace(l -> 'utm' ->> 'source', '{platform}', p_platform),
                    'utm_medium=' || (l -> 'utm' ->> 'medium'),
                    'utm_campaign=' || replace(l -> 'utm' ->> 'campaign', '{date}', to_char(now(), 'YYYYMMDD'))) end))
              from jsonb_array_elements(coalesce(p_profile #> '{required_elements,links}', '[]')) l
              where (l -> 'platforms') ? p_platform),
    'hashtags', case when (p_profile #> '{required_elements,hashtags,platforms}') ? p_platform then jsonb_build_object(
                  'required', p_profile #> '{required_elements,hashtags,required}', 'pool', p_profile #> '{required_elements,hashtags,pool}',
                  'max', p_profile #> '{required_elements,hashtags,max}') end,
    'disclaimers', (select jsonb_agg(d ->> 'text') from jsonb_array_elements(coalesce(p_profile #> '{required_elements,disclaimers}', '[]')) d
                    where (d -> 'platforms') ? p_platform),
    'signature', case when (p_profile #> '{required_elements,signature,platforms}') ? p_platform then p_profile #> '{required_elements,signature,text}' end))
$$;

create or replace function variant_plain_text(p_content jsonb) returns text
language sql immutable as $$
  select trim(concat_ws(E'\n\n',
    p_content ->> 'title', p_content ->> 'lead', p_content ->> 'text',
    (select string_agg(x, E'\n\n') from jsonb_array_elements_text(coalesce(p_content -> 'posts', '[]')) x),
    (select string_agg(concat_ws(E'\n', s ->> 'heading', s ->> 'body_md'), E'\n\n') from jsonb_array_elements(coalesce(p_content -> 'sections', '[]')) s),
    p_content ->> 'body'))
$$;

create or replace function slugify(p text) returns text
language sql immutable as $$
  select left(trim(both '-' from regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+', '-', 'g')), 80)
$$;

-- Everything the generation prompt needs (architecture 7.5: stable brand block first, volatile source last).
-- Facts the editor gave in redo comments count as sources for the fact check and for fixes (they confirmed them).
create or replace function editor_notes(p_variant bigint) returns text
language sql stable as $$
  select E'[Editor comments: facts stated here are confirmed by the editor]\n' || string_agg(comment, E'\n' order by version)
  from variant_versions where variant_id = p_variant and reason = 'redo' and nullif(trim(comment), '') is not null
$$;

create or replace function gen_context(p_variant bigint, p_mode text, p_comment text default null) returns jsonb
language plpgsql stable as $$
declare
  v variants;
  p packages;
  bp brand_platforms;
  br brands;
  m materials;
  e material_extracts;
  prof jsonb;
  fmt jsonb;
  cur variant_versions;
  v_kind text;
  v_failed jsonb;
begin
  select * into v from variants where id = p_variant;
  select * into p from packages where id = v.package_id;
  select * into bp from brand_platforms where id = v.brand_platform_id;
  select * into br from brands where id = p.brand_id;
  select * into m from materials where id = p.material_id;
  select * into e from material_extracts where material_id = m.id;
  select profile into prof from brand_profile_versions where brand_id = p.brand_id and version = p.profile_version;
  fmt := platform_format(p.brand_id, v.platform, prof);
  v_kind := fmt ->> 'kind';
  select * into cur from variant_versions where variant_id = v.id and version = v.current_version;
  select coalesce(jsonb_agg(jsonb_build_object('check', check_name, 'details', details)), '[]') into v_failed
  from check_results where variant_id = v.id and version = v.current_version and status = 'fail' and required;

  return jsonb_build_object(
    'skip', p.cancelled_at is not null or v.status not in ('draft', 'pending_approval', 'revising')
            or (p_mode = 'generate' and v.current_version > 0),
    'route', case when p_mode = 'fix' then 'fix.variant' else 'gen.variant' end,
    'schema_name', 'gen.' || v_kind,
    'kind', v_kind,
    'variant_id', v.id, 'package_id', p.id, 'material_id', m.id, 'brand_id', br.id,
    'vars', jsonb_build_object(
      'brand_name', br.name,
      'brand_profile', jsonb_build_object('basics', prof -> 'basics', 'voice', prof -> 'voice'),
      'examples', jsonb_build_object(
        'good', (select coalesce(jsonb_agg(x), '[]') from (select x from jsonb_array_elements(coalesce(prof #> '{examples,good}', '[]')) x
                  where x ->> 'platform' in (v.platform, 'any') limit 6) s),
        'bad', coalesce(prof #> '{examples,bad}', '[]')),
      'feedback', (select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'comment', comment, 'before', left(before_text, 1500),
                     'after', left(after_text, 1500)) order by created_at desc), '[]')
                   from (select * from feedback_examples f where f.brand_id = br.id and f.deleted_at is null
                           and (f.platform is null or f.platform = v.platform)
                         order by f.created_at desc limit coalesce(setting_num('gen.feedback_examples'), 6)::int) f),
      'platform', v.platform,
      'platform_label', fmt ->> 'label',
      'format', fmt,
      'language', bp.language,
      'required_elements', required_elements(prof, v.platform),
      'source_summary', e.summary - 'hints' - 'moderation',
      'source_text', concat_ws(E'\n\n', left(e.text, 60000), editor_notes(v.id),
        case when p_mode = 'redo' and nullif(trim(p_comment), '') is not null
             then E'[Editor comment for this rewrite: facts stated here are confirmed by the editor]\n' || p_comment end),
      'low_data', p.low_data,
      'tone_hint', m.hints ->> 'tone',
      'mode', p_mode,
      'comment', p_comment,
      'previous', case when p_mode in ('fix', 'redo') then cur.content end,
      'failed_checks', case when p_mode = 'fix' then v_failed end,
      'today', to_char(now() at time zone br.timezone, 'YYYY-MM-DD Dy'))
  ) || account_of(m.id, br.id);
end $$;

-- Save a generated/fixed/redone version (AP-3: every change is a new version) and queue the checks.
create or replace function save_generated(p_variant bigint, p_mode text, p_output jsonb, p_comment text default null) returns jsonb
language plpgsql as $$
declare
  v variants;
  p packages;
  v_kind text;
  v_content jsonb;
  v_version int;
begin
  select * into v from variants where id = p_variant for update;
  select * into p from packages where id = v.package_id;
  if p.cancelled_at is not null or v.status not in ('draft', 'pending_approval', 'revising') then
    return job_flags();
  end if;
  if p_mode = 'generate' and v.current_version > 0 then
    return job_flags();
  end if;
  v_kind := platform_format(p.brand_id, v.platform) ->> 'kind';
  v_content := case v_kind
    when 'thread' then jsonb_build_object('posts', coalesce(p_output -> 'posts', '[]'))
    when 'article' then jsonb_build_object('title', p_output ->> 'title', 'slug', slugify(coalesce(nullif(p_output ->> 'slug', ''), p_output ->> 'title')),
                                           'lead', p_output ->> 'lead', 'sections', coalesce(p_output -> 'sections', '[]'),
                                           'seo_description', p_output ->> 'seo_description')
    when 'email_block' then jsonb_build_object('title', p_output ->> 'title', 'body', p_output ->> 'body', 'link_label', p_output ->> 'link_label')
    else jsonb_build_object('text', p_output ->> 'text')
  end;
  v_version := v.current_version + 1;
  insert into variant_versions (variant_id, version, content, plain_text, headline_options, image_brief, used_facts, uncertain,
                                author_kind, reason, comment)
  values (v.id, v_version, v_content, variant_plain_text(v_content), coalesce(p_output -> 'headline_options', '[]'),
          p_output ->> 'image_brief', coalesce(p_output -> 'used_facts', '[]'), coalesce(p_output -> 'uncertain', '[]'),
          'ai', p_mode, p_comment);
  update variants set current_version = v_version, check_status = 'pending',
                      fix_attempts = case when p_mode = 'fix' then fix_attempts + 1 when p_mode = 'redo' then 0 else fix_attempts end
   where id = v.id;
  if p.image_brief is null and coalesce(p_output ->> 'image_brief', '') <> '' then
    update packages set image_brief = jsonb_build_object('brief', p_output ->> 'image_brief', 'from_variant', v.id) where id = p.id;
    -- a visual step waiting for this brief (visual_wait) runs now instead of at its next look
    update jobs set run_after = now()
     where type = 'package.visual' and package_id = p.id and status = 'queued' and run_after > now();
  end if;
  perform audit(null, 'variant.generated', 'variant', v.id, p.brand_id, p.material_id, jsonb_build_object('version', v_version, 'mode', p_mode));
  perform enqueue_job('variant.check', '{}', p.material_id, p.id, v.id, p.brand_id, p_dedupe => 'check:' || v.id || ':' || v_version);
  return job_flags();
end $$;

-- Data for the LLM/link checks (deterministic checks run in save_checks).
create or replace function check_context(p_variant bigint) returns jsonb
language plpgsql stable as $$
declare
  v variants;
  p packages;
  vv variant_versions;
  prof jsonb;
  bp brand_platforms;
begin
  select * into v from variants where id = p_variant;
  select * into p from packages where id = v.package_id;
  select * into vv from variant_versions where variant_id = v.id and version = v.current_version;
  select * into bp from brand_platforms where id = v.brand_platform_id;
  select profile into prof from brand_profile_versions where brand_id = p.brand_id and version = p.profile_version;
  return jsonb_build_object(
    'skip', vv.variant_id is null or p.cancelled_at is not null,
    'variant_id', v.id, 'version', vv.version, 'package_id', p.id, 'material_id', p.material_id, 'brand_id', p.brand_id,
    'text', vv.plain_text,
    'links', (select coalesce(jsonb_agg(distinct rtrim(u[1], '.,;:!?)')), '[]') from regexp_matches(vv.plain_text, '(' || url_regex() || ')', 'g') u),
    'extractor_base', setting_text('api.extractor_base'),
    'vars', jsonb_build_object(
      'variant_text', vv.plain_text,
      'platform', v.platform,
      'expected_language', bp.language,
      -- editor input is a source too: facts from a redo comment or typed in a manual edit are confirmed by the editor
      'source_text', concat_ws(E'\n\n',
        left((select text from material_extracts where material_id = p.material_id), 60000),
        editor_notes(v.id),
        case when vv.author_kind = 'human' then E'[Text written by the editor: facts in it are confirmed by the editor]\n' || vv.plain_text end),
      'brand_facts', coalesce(prof #> '{basics,facts}', '[]'),
      'brand_name', prof #>> '{basics,name}',
      'required_elements', required_elements(prof, v.platform),
      'forbidden_topics', coalesce(prof #> '{voice,forbidden_topics}', '[]'))
  ) || account_of(p.material_id, p.brand_id);
end $$;

-- Deterministic checks: length, forbidden words, required elements (cheap before expensive, architecture 7.5).
create or replace function basic_checks(p_variant bigint) returns jsonb
language plpgsql stable as $$
declare
  v variants;
  p packages;
  vv variant_versions;
  prof jsonb;
  fmt jsonb;
  req jsonb;
  v_text text;
  v_lower text;
  v_len int;
  v_words int;
  v_res jsonb := '[]';
  v_missing text[] := '{}';
  v_found text[];
  v_limit int;
  v_has_image boolean;
  v_bad_posts int;
  x text;
begin
  select * into v from variants where id = p_variant;
  select * into p from packages where id = v.package_id;
  select * into vv from variant_versions where variant_id = v.id and version = v.current_version;
  select profile into prof from brand_profile_versions where brand_id = p.brand_id and version = p.profile_version;
  fmt := platform_format(p.brand_id, v.platform, prof);
  req := required_elements(prof, v.platform);
  v_text := vv.plain_text;
  v_lower := lower(v_text);
  v_has_image := true;

  -- length
  if fmt ->> 'kind' = 'post' then
    v_len := char_length(vv.content ->> 'text');
    v_limit := case when v_has_image then (fmt ->> 'max_chars')::int else coalesce((fmt ->> 'max_chars_without_image')::int, (fmt ->> 'max_chars')::int) end;
    v_res := v_res || jsonb_build_object('check', 'length', 'required', true, 'status', case when v_len <= v_limit and v_len > 0 then 'pass' else 'fail' end,
                                         'details', jsonb_build_object('chars', v_len, 'limit', v_limit));
  elsif fmt ->> 'kind' = 'thread' then
    select count(*) filter (where char_length(post) > (fmt ->> 'max_chars_per_post')::int), count(*) into v_bad_posts, v_len
    from jsonb_array_elements_text(coalesce(vv.content -> 'posts', '[]')) as posts(post);
    v_res := v_res || jsonb_build_object('check', 'length', 'required', true,
      'status', case when v_bad_posts = 0 and v_len between 1 and (fmt ->> 'max_posts')::int then 'pass' else 'fail' end,
      'details', jsonb_build_object('posts', v_len, 'too_long_posts', v_bad_posts, 'limit_per_post', fmt -> 'max_chars_per_post', 'max_posts', fmt -> 'max_posts'));
  else
    v_words := coalesce(array_length(regexp_split_to_array(trim(case when fmt ->> 'kind' = 'email_block' then vv.content ->> 'body' else v_text end), '\s+'), 1), 0);
    v_res := v_res || jsonb_build_object('check', 'length', 'required', true,
      'status', case when v_words between (fmt ->> 'min_words')::int and (fmt ->> 'max_words')::int then 'pass' else 'fail' end,
      'details', jsonb_build_object('words', v_words, 'min', fmt -> 'min_words', 'max', fmt -> 'max_words'));
  end if;

  -- forbidden words
  select array_agg(w) into v_found from jsonb_array_elements_text(coalesce(prof #> '{voice,forbidden_words}', '[]')) w
  where v_lower ~ ('(^|[^[:alnum:]])' || regexp_replace(lower(w), '([.*+?^${}()|\[\]\\])', '\\\1', 'g') || '($|[^[:alnum:]])');
  v_res := v_res || jsonb_build_object('check', 'forbidden_words', 'required', true,
    'status', case when coalesce(cardinality(v_found), 0) = 0 then 'pass' else 'fail' end,
    'details', jsonb_build_object('found', coalesce(to_jsonb(v_found), '[]')));

  -- required elements
  if jsonb_array_length(coalesce(req -> 'cta_phrases', '[]')) > 0
     and not exists (select 1 from jsonb_array_elements_text(req -> 'cta_phrases') c where position(lower(c) in v_lower) > 0) then
    v_missing := v_missing || 'CTA'::text;
  end if;
  for x in select l ->> 'url' from jsonb_array_elements(coalesce(req -> 'links', '[]')) l loop
    if position(x in v_text) = 0 and position(split_part(x, '?', 1) in v_text) = 0 then
      v_missing := v_missing || ('link ' || split_part(x, '?', 1));
    end if;
  end loop;
  for x in select jsonb_array_elements_text(coalesce(req #> '{hashtags,required}', '[]')) loop
    if position(lower(x) in v_lower) = 0 then
      v_missing := v_missing || x;
    end if;
  end loop;
  for x in select jsonb_array_elements_text(coalesce(req -> 'disclaimers', '[]')) loop
    if position(lower(x) in v_lower) = 0 then
      v_missing := v_missing || ('disclaimer "' || ellipsis(x, 40) || '"');
    end if;
  end loop;
  if req ->> 'signature' is not null and position(lower(req ->> 'signature') in v_lower) = 0 then
    v_missing := v_missing || 'signature'::text;
  end if;
  if req -> 'hashtags' ? 'max' and (select count(*) from regexp_matches(v_text, '#[[:alnum:]_]+', 'g')) > (req #>> '{hashtags,max}')::int then
    v_missing := v_missing || ('at most ' || (req #>> '{hashtags,max}') || ' hashtags');
  end if;
  v_res := v_res || jsonb_build_object('check', 'required_elements', 'required', true,
    'status', case when cardinality(v_missing) = 0 then 'pass' else 'fail' end,
    'details', jsonb_build_object('missing', to_jsonb(v_missing)));
  return v_res;
end $$;

-- All check results for the current version; decides fix (GN-6) or finalization.
create or replace function save_checks(p_variant bigint, p_version int, p_links jsonb, p_facts jsonb, p_embedding text) returns jsonb
language plpgsql as $$
declare
  v variants;
  p packages;
  vv variant_versions;
  bp brand_platforms;
  r jsonb;
  v_checks jsonb;
  v_unsupported jsonb;
  v_broken jsonb;
  v_similar record;
  v_required_fail boolean;
  v_warn boolean;
  v_max_fix int := coalesce(setting_num('gen.max_fix_attempts'), 2)::int;
begin
  select * into v from variants where id = p_variant for update;
  if v.current_version <> p_version then
    return job_flags();
  end if;
  select * into p from packages where id = v.package_id;
  select * into vv from variant_versions where variant_id = v.id and version = p_version;
  select * into bp from brand_platforms where id = v.brand_platform_id;
  if p_embedding is not null and p_embedding <> '' then
    update variants set embedding = p_embedding::vector where id = v.id;
  end if;

  v_checks := basic_checks(v.id);
  select coalesce(jsonb_agg(c), '[]') into v_unsupported
  from jsonb_array_elements(coalesce(p_facts -> 'claims', '[]')) c where c ->> 'status' <> 'supported';
  v_checks := v_checks || jsonb_build_object('check', 'facts', 'required', true,
    'status', case when p_facts is null then 'warn' when jsonb_array_length(v_unsupported) = 0 then 'pass' else 'fail' end,
    'details', jsonb_build_object('unsupported', v_unsupported, 'summary', p_facts ->> 'summary'));
  v_checks := v_checks || jsonb_build_object('check', 'language', 'required', true,
    'status', case when p_facts is null then 'warn' when lower(coalesce(p_facts ->> 'language', '')) = bp.language then 'pass' else 'fail' end,
    'details', jsonb_build_object('detected', p_facts ->> 'language', 'expected', bp.language));
  v_checks := v_checks || jsonb_build_object('check', 'forbidden_topics', 'required', true,
    'status', case when jsonb_array_length(coalesce(p_facts -> 'forbidden_topics', '[]')) = 0 then 'pass' else 'fail' end,
    'details', jsonb_build_object('found', coalesce(p_facts -> 'forbidden_topics', '[]')));
  select coalesce(jsonb_agg(l), '[]') into v_broken from jsonb_array_elements(coalesce(p_links, '[]')) l where not coalesce((l ->> 'ok')::boolean, false);
  v_checks := v_checks || jsonb_build_object('check', 'links', 'required', false,
    'status', case when jsonb_array_length(v_broken) = 0 then 'pass' else 'warn' end,
    'details', jsonb_build_object('broken', v_broken, 'checked', jsonb_array_length(coalesce(p_links, '[]'))));
  select o.id, 1 - (o.embedding <=> v2.embedding) as sim, o.published_at into v_similar
  from variants v2 join variants o on o.id <> v2.id and o.embedding is not null and o.status = 'published'
  join packages op on op.id = o.package_id and op.brand_id = p.brand_id
  where v2.id = v.id and v2.embedding is not null
    and o.published_at > now() - make_interval(days => coalesce(setting_num('gen.repeat_topic_days'), 14)::int)
  order by o.embedding <=> v2.embedding limit 1;
  v_checks := v_checks || jsonb_build_object('check', 'repeat_topic', 'required', false,
    'status', case when coalesce(v_similar.sim, 0) >= coalesce(setting_num('gen.repeat_topic_similarity'), 0.88) then 'warn' else 'pass' end,
    'details', jsonb_build_object('similar_variant', v_similar.id, 'similarity', round(coalesce(v_similar.sim, 0)::numeric, 3), 'published_at', v_similar.published_at));

  delete from check_results where variant_id = v.id and version = p_version;
  for r in select * from jsonb_array_elements(v_checks) loop
    insert into check_results (variant_id, version, check_name, status, required, details)
    values (v.id, p_version, r ->> 'check', r ->> 'status', (r ->> 'required')::boolean, coalesce(r -> 'details', '{}'));
  end loop;
  v_required_fail := exists (select 1 from jsonb_array_elements(v_checks) c where (c ->> 'required')::boolean and c ->> 'status' = 'fail');
  v_warn := exists (select 1 from jsonb_array_elements(v_checks) c where c ->> 'status' in ('warn', 'fail'));

  if v_required_fail and vv.author_kind = 'ai' and v.fix_attempts < v_max_fix and v.status in ('draft', 'revising') then
    perform enqueue_job('variant.generate', jsonb_build_object('mode', 'fix'), p.material_id, p.id, v.id, p.brand_id,
                        p_dedupe => 'fix:' || v.id || ':' || p_version);
    return job_flags();
  end if;
  update variants set check_status = case when v_required_fail then 'failed' when v_warn then 'warned' else 'passed' end where id = v.id;
  perform audit(null, 'variant.checked', 'variant', v.id, p.brand_id, p.material_id,
                jsonb_build_object('version', p_version, 'required_fail', v_required_fail));
  perform finalize_variant(v.id);
  return job_flags();
end $$;

-- Checked variant -> approval queue; auto-publish (AP-6) and guest preview decided here, in one place.
create or replace function finalize_variant(p_variant bigint) returns void
language plpgsql as $$
declare
  v variants;
  p packages;
  bp brand_platforms;
begin
  select * into v from variants where id = p_variant for update;
  select * into p from packages where id = v.package_id;
  select * into bp from brand_platforms where id = v.brand_platform_id;
  if v.status in ('draft', 'revising') then
    perform transition('variant', v.id, 'pending_approval', null, 'checks done');
  end if;
  if p.is_guest and v.status in ('draft', 'revising', 'pending_approval') then
    perform approve_variant(v.id, null, true);
    perform schedule_variant(v.id, now());
  elsif not p.is_eval and bp.auto_publish and v.check_status = 'passed' and v.status in ('draft', 'revising', 'pending_approval') then
    perform approve_variant(v.id, null, true);
    perform schedule_variant(v.id);
  end if;
  perform package_try_card(p.id);
  if p.is_eval then
    perform eval_try_finalize(p.material_id);
  end if;
end $$;

-- Fan-in (architecture 4.3): the step that finishes the last part of a package queues the card exactly once.
create or replace function package_try_card(p_package bigint) returns void
language plpgsql as $$
declare
  p packages;
begin
  select * into p from packages where id = p_package for update;
  if p.cancelled_at is not null or p.is_eval then
    return;
  end if;
  if p.card_sent_at is null then
    if p.visual_status <> 'pending'
       and not exists (select 1 from variants where package_id = p.id and status in ('draft', 'revising')) then
      perform enqueue_job('package.card', '{}', p.material_id, p.id, null, p.brand_id, p_dedupe => 'card:' || p.id, p_priority => 5);
    end if;
  else
    perform enqueue_job('card.refresh', '{}', p.material_id, p.id, null, p.brand_id, p_coalesce => 'card:' || p.id, p_priority => 5);
  end if;
end $$;

-- Visual step input (GN-3). The brief usually comes from the first generated variant (no extra AI call).
create or replace function visual_context(p_package bigint, p_mode text default 'auto', p_wait int default 0) returns jsonb
language plpgsql stable as $$
declare
  p packages;
  br brands;
  prof jsonb;
  v_src record;
begin
  select * into p from packages where id = p_package;
  select * into br from brands where id = p.brand_id;
  select profile into prof from brand_profile_versions where brand_id = p.brand_id and version = p.profile_version;
  -- source image of the material (auto mode only); zero rows still assign the record (all nulls)
  select a.s3_key, a.id, a.mime into v_src from material_parts mp join assets a on a.id = mp.asset_id
  where mp.material_id = p.material_id and mp.kind = 'image' and p_mode = 'auto' order by mp.ord limit 1;
  return jsonb_build_object(
    'skip', p.cancelled_at is not null or (p_mode = 'auto' and p.visual_status <> 'pending'),
    'package_id', p.id, 'material_id', p.material_id, 'brand_id', p.brand_id, 'mode', p_mode,
    'aspects', (select coalesce(jsonb_agg(distinct variant_aspect(v.id)), '[]') from variants v
                where v.package_id = p.id and v.status not in ('cancelled', 'rejected')),
    'source', case when v_src.id is not null then jsonb_build_object('asset_id', v_src.id, 's3_key', v_src.s3_key, 'mime', v_src.mime) end,
    'brief', p.image_brief ->> 'brief',
    'wait_for_brief', p.image_brief is null and v_src.id is null and p_mode = 'auto' and p_wait < 3
                      and exists (select 1 from variants v where v.package_id = p.id and v.current_version = 0 and v.status = 'draft'),
    'logo', prof #> '{visual,logo}',
    's3_prefix', 'b/' || p.brand_id || '/p/' || p.id || '/',
    'bucket', setting_text('s3.bucket'),
    'extractor_base', setting_text('api.extractor_base'),
    'telegram_base', setting_text('api.telegram_base'),
    'telegram_file_base', setting_text('api.telegram_file_base'),
    'vars', jsonb_build_object(
      'brand_name', br.name,
      'image_style', prof #>> '{visual,image_style}',
      'palette', coalesce(prof #> '{visual,palette}', '[]'),
      'forbidden', coalesce(prof #> '{visual,forbidden}', '[]'),
      'summary', (select summary -> 'main_idea' from material_extracts where material_id = p.material_id)),
    'system_forbidden', 'No people or human faces, no text or letters, no logos, trademarks or brand names, no watermarks.'
  ) || account_of(p.material_id, p.brand_id);
end $$;

-- The first variant usually brings the image brief: look again in a minute instead of paying for a separate brief call.
create or replace function visual_wait(p_package bigint, p_wait int) returns jsonb
language plpgsql as $$
declare
  p packages;
begin
  select * into p from packages where id = p_package;
  perform enqueue_job('package.visual', jsonb_build_object('mode', 'auto', 'wait', p_wait + 1), p.material_id, p.id, null, p.brand_id,
                      p_dedupe => 'visual:' || p.id || ':auto:wait' || (p_wait + 1), p_run_after => now() + interval '60 seconds');
  return job_flags();
end $$;

create or replace function save_visual_brief(p_package bigint, p_brief text) returns void
language sql as $$ update packages set image_brief = jsonb_build_object('brief', p_brief, 'from', 'image.brief') where id = p_package and image_brief is null $$;

create or replace function save_visual(p_package bigint, p_aspect text, p_s3_key text, p_sha256 text, p_mime text, p_bytes bigint,
                                       p_width int, p_height int, p_origin text, p_check jsonb default null, p_ok boolean default true) returns bigint
language plpgsql as $$
declare
  p packages;
  v_asset bigint;
begin
  select * into p from packages where id = p_package;
  insert into assets (s3_key, sha256, mime, bytes, width, height, origin, brand_id, material_id, aspect)
  values (p_s3_key, p_sha256, coalesce(p_mime, 'image/png'), p_bytes, p_width, p_height,
          case when p_origin = 'generated' then 'generated' when p_origin = 'upload' then 'upload' else 'derived' end,
          p.brand_id, p.material_id, p_aspect)
  on conflict (s3_key) do update set sha256 = excluded.sha256, bytes = excluded.bytes
  returning id into v_asset;
  insert into package_visuals (package_id, aspect, asset_id, origin, check_result, ok)
  values (p.id, p_aspect, v_asset, p_origin, p_check, coalesce(p_ok, true))
  on conflict (package_id, aspect) do update set asset_id = excluded.asset_id, origin = excluded.origin,
    check_result = excluded.check_result, ok = excluded.ok, created_at = now();
  return v_asset;
end $$;

-- Visual step finished. For editor-requested regenerations/uploads every affected variant gets a new version (AP-3).
create or replace function visual_done(p_package bigint, p_mode text, p_ok boolean, p_note text default null, p_actor bigint default null) returns jsonb
language plpgsql as $$
declare
  p packages;
  v record;
begin
  select * into p from packages where id = p_package for update;
  update packages set visual_status = case when p_ok then 'done' else 'failed' end,
                      visual_note = p_note, visual_attempt = visual_attempt + 1
   where id = p.id;
  if p_mode in ('regenerate', 'upload') then
    for v in
      select vr.id, vr.current_version, pv.asset_id
      from variants vr join package_visuals pv on pv.package_id = vr.package_id and pv.aspect = variant_aspect(vr.id)
      where vr.package_id = p.id and vr.status in ('pending_approval', 'approved', 'scheduled', 'rescheduled') and vr.current_version > 0
    loop
      insert into variant_versions (variant_id, version, content, plain_text, headline_options, image_brief, visual_asset_id,
                                    used_facts, uncertain, author_kind, author_user_id, reason, comment)
      select variant_id, version + 1, content, plain_text, headline_options, image_brief, v.asset_id, used_facts, uncertain,
             case when p_actor is null then 'ai' else 'human' end, p_actor, 'visual', p_mode
      from variant_versions where variant_id = v.id and version = v.current_version;
      update variants set current_version = current_version + 1 where id = v.id;
      insert into check_results (variant_id, version, check_name, status, required, details)
      select variant_id, version + 1, check_name, status, required, details from check_results
      where variant_id = v.id and version = v.current_version;
    end loop;
  end if;
  perform audit(p_actor, 'package.visual', 'package', p.id, p.brand_id, p.material_id, jsonb_build_object('mode', p_mode, 'ok', p_ok, 'note', p_note));
  perform package_try_card(p.id);
  return job_flags();
end $$;

-- Visual of a variant for cards/publishing: explicit version visual, else the package visual for its aspect.
create or replace function variant_visual(p_variant bigint) returns bigint
language sql stable as $$
  select coalesce(vv.visual_asset_id, pv.asset_id)
  from variants v
  join variant_versions vv on vv.variant_id = v.id and vv.version = v.current_version
  left join package_visuals pv on pv.package_id = v.package_id and pv.aspect = variant_aspect(v.id)
  where v.id = p_variant
$$;
