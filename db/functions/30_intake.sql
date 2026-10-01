-- Intake (IN-1..IN-9): Telegram messages and emails -> materials and parts; gluing; limits; acks; tables.

create or replace function url_regex() returns text language sql immutable as $$ select 'https?://[^\s<>"'']+' $$;

-- Map a file to a part kind by MIME type / extension. null = unsupported.
create or replace function file_kind(p_mime text, p_name text) returns text
language sql immutable as $$
  select case
    when lower(coalesce(p_mime, '')) = 'application/pdf' or lower(coalesce(p_name, '')) ~ '\.pdf$' then 'pdf'
    when lower(coalesce(p_mime, '')) = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
         or lower(coalesce(p_name, '')) ~ '\.docx$' then 'docx'
    when lower(coalesce(p_mime, '')) in ('application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'text/csv', 'application/csv')
         or lower(coalesce(p_name, '')) ~ '\.(xlsx|csv)$' then 'table'
    when lower(coalesce(p_mime, '')) in ('image/jpeg', 'image/png', 'image/webp')
         or lower(coalesce(p_name, '')) ~ '\.(jpe?g|png|webp)$' then 'image'
    when lower(coalesce(p_mime, '')) like 'audio/%' or lower(coalesce(p_name, '')) ~ '\.(mp3|m4a|ogg|oga|opus|wav|flac|aac)$' then 'audio'
  end
$$;

-- Split text into url parts (when the message is essentially links) or one text part.
create or replace function text_parts(p_text text, p_ref text) returns jsonb
language plpgsql immutable as $$
declare
  v_urls text[];
  v_rest text;
  v_parts jsonb := '[]';
  i int := 0;
  u text;
begin
  if coalesce(trim(p_text), '') = '' then
    return v_parts;
  end if;
  select array_agg(m[1]) into v_urls from regexp_matches(p_text, '(' || url_regex() || ')', 'g') as m;
  v_rest := trim(regexp_replace(p_text, url_regex(), '', 'g'));
  if coalesce(cardinality(v_urls), 0) > 0 and char_length(v_rest) < 40 then
    foreach u in array v_urls[1:3] loop
      i := i + 1;
      v_parts := v_parts || jsonb_build_object('kind', 'url', 'source_ref', p_ref || ':url:' || i, 'url', rtrim(u, '.,;:!?)'), 'input_text', u);
    end loop;
    if v_rest <> '' then
      v_parts := v_parts || jsonb_build_object('kind', 'text', 'source_ref', p_ref || ':text', 'input_text', v_rest);
    end if;
  else
    v_parts := v_parts || jsonb_build_object('kind', 'text', 'source_ref', p_ref || ':text', 'input_text', p_text);
  end if;
  return v_parts;
end $$;

-- Telegram message -> part descriptors (pure). Unsupported content -> {"unsupported": "..."}.
create or replace function tg_message_parts(p_msg jsonb) returns jsonb
language plpgsql immutable as $$
declare
  v_ref text := 'tg:' || (p_msg ->> 'message_id');
  v_parts jsonb := '[]';
  v_doc jsonb := p_msg -> 'document';
  v_kind text;
  v_photo jsonb;
  k text;
begin
  foreach k in array array['video', 'video_note', 'animation', 'sticker', 'location', 'contact', 'poll', 'dice', 'venue', 'game'] loop
    if p_msg ? k then
      return jsonb_build_array(jsonb_build_object('unsupported', replace(k, '_', ' ')));
    end if;
  end loop;
  if p_msg ? 'voice' then
    v_parts := v_parts || jsonb_build_object('kind', 'voice', 'source_ref', v_ref || ':voice',
      'tg_file_id', p_msg #>> '{voice,file_id}', 'tg_file_unique_id', p_msg #>> '{voice,file_unique_id}',
      'mime', coalesce(p_msg #>> '{voice,mime_type}', 'audio/ogg'), 'file_name', 'voice.ogg',
      'size_bytes', (p_msg #>> '{voice,file_size}')::bigint, 'duration_s', (p_msg #>> '{voice,duration}')::int);
  end if;
  if p_msg ? 'audio' then
    v_parts := v_parts || jsonb_build_object('kind', 'audio', 'source_ref', v_ref || ':audio',
      'tg_file_id', p_msg #>> '{audio,file_id}', 'tg_file_unique_id', p_msg #>> '{audio,file_unique_id}',
      'mime', coalesce(p_msg #>> '{audio,mime_type}', 'audio/mpeg'), 'file_name', coalesce(p_msg #>> '{audio,file_name}', 'audio'),
      'size_bytes', (p_msg #>> '{audio,file_size}')::bigint, 'duration_s', (p_msg #>> '{audio,duration}')::int);
  end if;
  if jsonb_typeof(p_msg -> 'photo') = 'array' then
    v_photo := p_msg -> 'photo' -> -1;
    v_parts := v_parts || jsonb_build_object('kind', 'image', 'source_ref', v_ref || ':photo',
      'tg_file_id', v_photo ->> 'file_id', 'tg_file_unique_id', v_photo ->> 'file_unique_id',
      'mime', 'image/jpeg', 'file_name', 'photo.jpg', 'size_bytes', (v_photo ->> 'file_size')::bigint);
  end if;
  if v_doc is not null then
    v_kind := file_kind(v_doc ->> 'mime_type', v_doc ->> 'file_name');
    if v_kind is null then
      return jsonb_build_array(jsonb_build_object('unsupported', coalesce(v_doc ->> 'file_name', v_doc ->> 'mime_type', 'file')));
    end if;
    v_parts := v_parts || jsonb_build_object('kind', v_kind, 'source_ref', v_ref || ':doc',
      'tg_file_id', v_doc ->> 'file_id', 'tg_file_unique_id', v_doc ->> 'file_unique_id',
      'mime', v_doc ->> 'mime_type', 'file_name', v_doc ->> 'file_name', 'size_bytes', (v_doc ->> 'file_size')::bigint);
  end if;
  v_parts := v_parts || text_parts(coalesce(p_msg ->> 'text', p_msg ->> 'caption'), v_ref);
  return (select coalesce(jsonb_agg(p || jsonb_build_object('media_group_id', p_msg ->> 'media_group_id')), '[]') from jsonb_array_elements(v_parts) p);
end $$;

-- IN-2 limits checked before downloading (Telegram reports size and duration). Returns a reason or null.
create or replace function parts_limit_error(p_parts jsonb, p_existing_images int default 0) returns text
language plpgsql stable as $$
declare
  p jsonb;
  v_images int := p_existing_images;
begin
  for p in select * from jsonb_array_elements(p_parts) loop
    if p ? 'unsupported' then
      return tpl('intake.unsupported', jsonb_build_object('what', p ->> 'unsupported'));
    end if;
    if p ->> 'kind' = 'text' and char_length(p ->> 'input_text') > setting_num('intake.max_text_chars') then
      return tpl('intake.too_long_text', jsonb_build_object('chars', char_length(p ->> 'input_text'), 'limit', setting_num('intake.max_text_chars')));
    end if;
    if p ->> 'kind' in ('voice', 'audio') and coalesce((p ->> 'duration_s')::int, 0) > setting_num('intake.max_audio_seconds') then
      return tpl('intake.too_long_audio', jsonb_build_object('duration', fmt_duration((p ->> 'duration_s')::int),
                                                            'limit', fmt_duration(setting_num('intake.max_audio_seconds')::int)));
    end if;
    if coalesce((p ->> 'size_bytes')::bigint, 0) > setting_num('intake.max_file_bytes') then
      return tpl('intake.too_large', jsonb_build_object('size', fmt_bytes((p ->> 'size_bytes')::bigint),
                                                       'limit', fmt_bytes(setting_num('intake.max_file_bytes')::bigint)));
    end if;
    if p ->> 'kind' = 'image' then
      v_images := v_images + 1;
    end if;
  end loop;
  if v_images > setting_num('intake.max_images') then
    return tpl('intake.too_many_images', jsonb_build_object('limit', setting_num('intake.max_images')));
  end if;
  return null;
end $$;

-- Human-readable "what was recognized" (IN-4).
create or replace function material_parts_summary(p_material bigint) returns text
language sql stable as $$
  select coalesce(string_agg(d, ', ' order by o), 'nothing yet') from (
    select min(ord) as o,
      case kind
        when 'text' then 'text (' || to_char(sum(char_length(input_text)), 'FM999G999') || ' chars)'
        when 'url' then case when count(*) = 1 then 'link' else count(*) || ' links' end
        when 'image' then case when count(*) = 1 then 'image' else count(*) || ' images' end
        when 'voice' then 'voice ' || fmt_duration(sum(duration_s)::int)
        when 'audio' then 'audio ' || fmt_duration(sum(duration_s)::int)
        when 'pdf' then 'PDF ' || string_agg(coalesce(file_name, 'file'), ', ')
        when 'docx' then 'DOCX ' || string_agg(coalesce(file_name, 'file'), ', ')
        when 'table' then 'table ' || string_agg(coalesce(file_name, 'file'), ', ')
        when 'clarification' then 'clarification'
      end as d
    from material_parts where material_id = p_material group by kind
  ) s
$$;

-- The evolving status message for a material (IN-4 ack), one Telegram message edited in place.
create or replace function render_ack(p_material bigint) returns void
language plpgsql as $$
declare
  m materials;
  v_text text;
  v_kb jsonb := null;
  v_brands text;
  v_glue int := coalesce(setting_num('intake.glue_seconds'), 60)::int;
begin
  select * into m from materials where id = p_material;
  if m.chat_id is null or m.source not in ('telegram', 'table_row') or m.parent_material_id is not null then
    return;
  end if;
  select string_agg(b.name, ', ' order by b.name) into v_brands
  from brands b where b.id in (select (jsonb_array_elements_text(coalesce(m.hints -> 'brand_ids', '[]')))::bigint);
  if m.status = 'received' and m.sealed_at is null then
    v_text := tpl('ack.collecting', jsonb_build_object('material', mcode(m.id), 'parts', material_parts_summary(m.id),
                  'seconds', greatest(0, v_glue - extract(epoch from now() - m.last_part_at)::int)));
    v_kb := kb(jsonb_build_array(btn('⚡ Process now', 'mp:' || m.id), btn('✖ Cancel', 'mx:' || m.id)),
               case when not m.is_guest then jsonb_build_array(
                 btn('🏷 Brand' || coalesce(': ' || ellipsis(v_brands, 20), ''), 'mb:' || m.id),
                 btn(case when (m.hints ->> 'digest_only')::boolean then '✅ Digest only' else '📰 Digest only' end, 'md:' || m.id),
                 btn(case when (m.hints ->> 'urgent')::boolean then '✅ Urgent' else '🚨 Urgent' end, 'mu:' || m.id)) end);
  elsif m.status = 'received' then
    v_text := tpl('ack.processing', jsonb_build_object('material', mcode(m.id), 'parts', material_parts_summary(m.id)));
  elsif m.status = 'parsed' then
    v_text := tpl('ack.parsed', jsonb_build_object('material', mcode(m.id),
                  'idea', ellipsis((select summary ->> 'main_idea' from material_extracts where material_id = m.id), 300)));
  elsif m.status = 'awaiting_author' then
    v_text := tpl('ack.waiting', jsonb_build_object('material', mcode(m.id)));
  elsif m.status = 'routed' then
    v_text := tpl('ack.routed', jsonb_build_object('material', mcode(m.id),
                  'brands', (select string_agg(b.name || ' (' || (select count(*) from variants v where v.package_id = p.id) || ')', ', ' order by b.name)
                             from packages p join brands b on b.id = p.brand_id where p.material_id = m.id and p.cancelled_at is null)));
  else
    v_text := tpl('ack.rejected', jsonb_build_object('material', mcode(m.id), 'reason', coalesce(m.reject_reason, '—')));
  end if;
  perform tg_slot('ack:' || m.id, m.chat_id, v_text, coalesce(v_kb, '[]'::jsonb), null, m.author_user_id, m.id, 5);
end $$;

-- Notify the author in the channel the material came from (tz 5.11).
create or replace function author_notify(p_material bigint, p_text text, p_keyboard jsonb default null, p_dedupe text default null) returns void
language plpgsql as $$
declare
  m materials;
begin
  select * into m from materials where id = p_material;
  if m.source = 'email' and m.reply_email is not null and p_keyboard is null then
    perform email_send(m.reply_email, mcode(m.id) || ' — AI Content Factory', replace(p_text, E'\n', '<br>'),
                       regexp_replace(p_text, '<[^>]+>', '', 'g'), p_dedupe, jsonb_build_object('material_id', m.id, 'user_id', m.author_user_id));
  else
    perform tg_send_chat(coalesce(m.chat_id, (select tg_chat_id from users where id = m.author_user_id)),
                         p_text, p_keyboard, p_dedupe, m.author_user_id, m.id);
  end if;
end $$;

create or replace function material_reject(p_material bigint, p_reason text, p_actor bigint default null) returns void
language plpgsql as $$
declare
  m materials;
begin
  select * into m from materials where id = p_material for update;
  if m.status not in ('received', 'parsed', 'awaiting_author') then
    return;
  end if;
  update materials set reject_reason = p_reason, question = null where id = m.id;
  perform transition('material', m.id, 'rejected', p_actor, p_reason);
  update jobs set status = 'cancelled', finished_at = now()
   where material_id = m.id and status in ('queued', 'failed', 'blocked');
  delete from bot_sessions where kind = 'clarify' and (data ->> 'material_id')::bigint = m.id;
  if m.source = 'telegram' then
    perform render_ack(m.id);
  else
    perform author_notify(m.id, tpl('ack.rejected', jsonb_build_object('material', mcode(m.id), 'reason', p_reason)), null, 'reject:' || m.id);
  end if;
end $$;

-- Telegram intake: glue messages of one author within the window (IN-5), check limits (IN-2, IN-7),
-- store parts, start downloads immediately, ack with the material ID (IN-4).
create or replace function intake_tg_message(p_user users, p_msg jsonb, p_event bigint) returns void
language plpgsql as $$
declare
  v_parts jsonb := tg_message_parts(p_msg);
  v_err text;
  v_guest boolean := not has_any_access(p_user.id);
  v_glue int := coalesce(setting_num('intake.glue_seconds'), 60)::int;
  m materials;
  p jsonb;
  v_part_id bigint;
  v_images int := 0;
  v_ord int;
begin
  if jsonb_array_length(v_parts) = 0 then
    return;
  end if;
  if v_guest then
    if (select count(*) from materials where author_user_id = p_user.id and is_guest and created_at > now() - interval '1 day'
        and parent_material_id is null) >= coalesce(setting_num('guest.daily_materials'), 3) then
      perform tg_send(p_user.id, tpl('guest.limit', jsonb_build_object('limit', setting_num('guest.daily_materials'))), null,
                      'guest_limit:' || p_user.id || ':' || current_date);
      return;
    end if;
  end if;

  select * into m from materials
  where author_user_id = p_user.id and source = 'telegram' and status = 'received' and sealed_at is null
    and (last_part_at > now() - make_interval(secs => v_glue)
         or (p_msg ? 'media_group_id' and exists (select 1 from material_parts mp where mp.material_id = materials.id
                                                   and mp.media_group_id = p_msg ->> 'media_group_id')))
  order by id desc limit 1
  for update;
  if m.id is not null then
    select count(*) into v_images from material_parts where material_id = m.id and kind = 'image';
  end if;

  v_err := parts_limit_error(v_parts, v_images);
  if v_err is not null then
    perform tg_send(p_user.id, tpl('intake.rejected', jsonb_build_object('reason', v_err)));
    perform audit(p_user.id, 'intake.rejected', 'inbound_event', p_event, null, m.id, jsonb_build_object('reason', v_err));
    return;
  end if;

  if m.id is null then
    insert into materials (author_user_id, source, is_guest, chat_id)
    values (p_user.id, 'telegram', v_guest, p_user.tg_chat_id)
    returning * into m;
    perform audit(p_user.id, 'material.received', 'material', m.id, null, m.id, jsonb_build_object('source', 'telegram', 'guest', v_guest));
  end if;

  select coalesce(max(ord), 0) into v_ord from material_parts where material_id = m.id;
  for p in select * from jsonb_array_elements(v_parts) loop
    v_ord := v_ord + 1;
    insert into material_parts (material_id, kind, ord, inbound_event_id, source_ref, tg_file_id, tg_file_unique_id,
                                media_group_id, file_name, mime, size_bytes, duration_s, url, input_text,
                                extracted_text, extracted_at)
    values (m.id, p ->> 'kind', v_ord, p_event, p ->> 'source_ref', p ->> 'tg_file_id', p ->> 'tg_file_unique_id',
            p ->> 'media_group_id', p ->> 'file_name', p ->> 'mime', (p ->> 'size_bytes')::bigint, (p ->> 'duration_s')::int,
            p ->> 'url', p ->> 'input_text',
            case when p ->> 'kind' = 'text' then p ->> 'input_text' end,
            case when p ->> 'kind' = 'text' then now() end)
    on conflict (material_id, source_ref) do nothing
    returning id into v_part_id;
    if v_part_id is not null and p ->> 'kind' <> 'text' then
      perform enqueue_job('part.process', jsonb_build_object('part_id', v_part_id), m.id, p_dedupe => 'part:' || v_part_id);
    end if;
  end loop;

  update materials set last_part_at = now() where id = m.id;
  if enqueue_job('material.seal', '{}', m.id, p_run_after => now() + make_interval(secs => v_glue), p_coalesce => 'seal:' || m.id) is null then
    update jobs set run_after = now() + make_interval(secs => v_glue)
     where coalesce_key = 'seal:' || m.id and status in ('queued', 'failed');
  end if;
  perform render_ack(m.id);
end $$;

-- Seal after the glue window (or "Process now"); summarization starts when all parts are extracted.
create or replace function material_seal(p_material bigint, p_force boolean default false) returns void
language plpgsql as $$
declare
  m materials;
  v_glue int := coalesce(setting_num('intake.glue_seconds'), 60)::int;
begin
  select * into m from materials where id = p_material for update;
  if m.id is null or m.sealed_at is not null or m.status <> 'received' then
    return;
  end if;
  if not p_force and m.last_part_at + make_interval(secs => v_glue) > now() then
    perform enqueue_job('material.seal', '{}', m.id, p_run_after => m.last_part_at + make_interval(secs => v_glue), p_coalesce => 'seal:' || m.id);
    return;
  end if;
  update materials set sealed_at = now() where id = m.id;
  update jobs set status = 'cancelled', finished_at = now() where coalesce_key = 'seal:' || m.id and status in ('queued', 'failed');
  perform render_ack(m.id);
  perform material_try_summarize(m.id);
end $$;

-- Fan-in: enqueue summarization exactly once per revision, when sealed and every part is extracted.
create or replace function material_try_summarize(p_material bigint) returns void
language plpgsql as $$
declare
  m materials;
begin
  select * into m from materials where id = p_material for update;
  if m.id is null or m.sealed_at is null or m.is_container or m.status not in ('received', 'awaiting_author') then
    return;
  end if;
  if exists (select 1 from material_parts where material_id = m.id and extracted_at is null and error is null) then
    return;
  end if;
  if exists (select 1 from material_parts where material_id = m.id and error is not null) then
    return;
  end if;
  if not exists (select 1 from material_parts where material_id = m.id and coalesce(trim(extracted_text), '') <> '') then
    perform material_reject(m.id, tpl('intake.empty', '{}'));
    return;
  end if;
  perform enqueue_job('material.summarize', '{}', m.id, p_dedupe => 'summarize:' || m.id || ':' || m.revision);
end $$;

-- Everything the part handler (PIPE · Part) needs in one call.
create or replace function part_context(p_part bigint) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'part_id', p.id, 'material_id', p.material_id, 'kind', p.kind, 'tg_file_id', p.tg_file_id,
    'file_name', coalesce(p.file_name, p.kind), 'mime', p.mime, 'size_bytes', p.size_bytes, 'url', p.url,
    'input_text', p.input_text, 'done', p.extracted_at is not null or p.error is not null,
    'asset_key', a.s3_key, 'asset_id', a.id,
    's3_key', 'm/' || p.material_id || '/' || p.id || '-' || regexp_replace(coalesce(p.file_name, p.kind), '[^A-Za-z0-9._-]', '_', 'g'),
    'bucket', setting_text('s3.bucket'),
    'telegram_base', setting_text('api.telegram_base'),
    'telegram_file_base', setting_text('api.telegram_file_base'),
    'extractor_base', setting_text('api.extractor_base'),
    'max_pages', setting_num('intake.max_doc_pages'),
    'max_rows', setting_num('intake.max_table_rows'),
    'account_type', case when m.is_eval then 'eval' when m.is_guest then 'guest' else 'system' end,
    'is_scan_fallback', true)
  from material_parts p join materials m on m.id = p.material_id
  left join assets a on a.id = p.asset_id
  where p.id = p_part
$$;

create or replace function part_downloaded(p_part bigint, p_s3_key text, p_sha256 text, p_mime text, p_bytes bigint) returns bigint
language plpgsql as $$
declare
  v_asset bigint;
  p material_parts;
begin
  select * into p from material_parts where id = p_part for update;
  if p.asset_id is not null then
    return p.asset_id;
  end if;
  insert into assets (s3_key, sha256, mime, bytes, origin, material_id)
  values (p_s3_key, p_sha256, coalesce(nullif(p_mime, ''), p.mime, 'application/octet-stream'), p_bytes,
          (select case source when 'email' then 'email' else 'telegram' end from materials where id = p.material_id), p.material_id)
  on conflict (s3_key) do update set sha256 = excluded.sha256
  returning id into v_asset;
  update material_parts set asset_id = v_asset where id = p_part;
  return v_asset;
end $$;

-- Part extraction result. An error rejects the material with a clear reason (IN-7).
create or replace function part_extracted(p_part bigint, p_text text, p_meta jsonb default '{}', p_error text default null) returns jsonb
language plpgsql as $$
declare
  p material_parts;
begin
  select * into p from material_parts where id = p_part for update;
  if p.id is null or p.extracted_at is not null then
    return job_flags();
  end if;
  if p_error is not null then
    update material_parts set error = p_error, extract_meta = coalesce(p_meta, '{}') where id = p_part;
    perform material_reject(p.material_id, p_error);
  else
    update material_parts set extracted_text = coalesce(p_text, ''), extract_meta = coalesce(p_meta, '{}'), extracted_at = now()
     where id = p_part;
    perform material_try_summarize(p.material_id);
  end if;
  return job_flags();
end $$;

-- Parse a date cell: Excel serial number, 'YYYY-MM-DD HH:MM' or 'YYYY-MM-DD'. Returns local timestamp or raises.
create or replace function parse_table_date(p jsonb) returns timestamp
language plpgsql immutable as $$
declare
  v text := trim(p #>> '{}');
begin
  if v is null or v = '' then
    return null;
  end if;
  if v ~ '^\d+(\.\d+)?$' then
    return timestamp '1899-12-30' + make_interval(secs => round(v::numeric * 86400)::int);
  end if;
  if v ~ '^\d{4}-\d{2}-\d{2}([ T]\d{1,2}:\d{2})?$' then
    return v::timestamp + case when v ~ '^\d{4}-\d{2}-\d{2}$' then interval '10 hours' else interval '0' end;
  end if;
  raise exception 'bad date';
end $$;

-- Start processing of table row materials (idempotent: dedupe keys).
create or replace function table_rows_start(p_container bigint) returns void
language plpgsql as $$
declare
  r record;
begin
  for r in
    select p.id as part_id, p.material_id from material_parts p join materials c on c.id = p.material_id
    where c.parent_material_id = p_container and p.kind = 'url' and p.extracted_at is null and p.error is null
  loop
    perform enqueue_job('part.process', jsonb_build_object('part_id', r.part_id), r.material_id, p_dedupe => 'part:' || r.part_id);
  end loop;
  for r in select id from materials where parent_material_id = p_container and status = 'received' loop
    perform material_try_summarize(r.id);
  end loop;
end $$;

-- IN-9: split a table into one material per valid row; report invalid rows by number; no losses, no duplicates
-- (unique parent+row). Header row = row 1, so data row i has row_number i + 1.
create or replace function table_split(p_part bigint, p_rows jsonb) returns jsonb
language plpgsql as $$
declare
  p material_parts;
  m materials;
  v_row jsonb;
  v_idx int := 0;
  v_rownum int;
  v_brand brands;
  v_text text;
  v_link text;
  v_platforms text[];
  v_bad_platforms text[];
  v_date timestamp;
  v_err text;
  v_errors text[] := '{}';
  v_ok int := 0;
  v_child bigint;
  v_first bigint;
  v_last bigint;
  v_norm jsonb;
  v_brand_ref text;
  v_max int := coalesce(setting_num('intake.max_table_rows'), 500)::int;
begin
  select * into p from material_parts where id = p_part for update;
  select * into m from materials where id = p.material_id for update;
  if p.extracted_at is not null then
    return jsonb_build_object('already', true);
  end if;
  if jsonb_array_length(coalesce(p_rows, '[]')) > v_max then
    return part_extracted(p_part, null, '{}', tpl('intake.too_many_rows', jsonb_build_object('rows', jsonb_array_length(p_rows), 'limit', v_max)));
  end if;

  for v_row in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    v_idx := v_idx + 1;
    v_rownum := v_idx + 1;
    select coalesce(jsonb_object_agg(case
             when lower(trim(key)) in ('brand', 'бренд') then 'brand'
             when lower(trim(key)) in ('text', 'topic', 'topic or text', 'topic_or_text', 'тема', 'текст', 'тема или текст') then 'text'
             when lower(trim(key)) in ('link', 'url', 'ссылка') then 'link'
             when lower(trim(key)) in ('platforms', 'platform', 'площадки') then 'platforms'
             when lower(trim(key)) in ('date', 'publish_at', 'дата') then 'date'
             else lower(trim(key)) end, value), '{}')
      into v_norm from jsonb_each(v_row);
    v_brand_ref := nullif(trim(v_norm ->> 'brand'), '');
    v_text := nullif(trim(v_norm ->> 'text'), '');
    v_link := nullif(trim(v_norm ->> 'link'), '');
    if v_brand_ref is null and v_text is null and v_link is null and nullif(trim(v_norm ->> 'platforms'), '') is null then
      continue;  -- empty row
    end if;
    v_err := null;
    v_platforms := null;
    v_date := null;
    select b.* into v_brand from brands b
    where b.id in (select brand_id from user_submit_brands(m.author_user_id))
      and (b.slug = lower(v_brand_ref) or lower(b.name) = lower(v_brand_ref))
    limit 1;
    if v_brand_ref is null then
      v_err := 'brand is empty';
    elsif v_brand.id is null then
      v_err := 'unknown brand "' || v_brand_ref || '"';
    elsif v_text is null and v_link is null then
      v_err := 'text and link are both empty';
    elsif v_link is not null and v_link !~ '^https?://\S+$' then
      v_err := 'link is not a valid http(s) URL';
    elsif v_text is not null and char_length(v_text) > setting_num('intake.max_text_chars') then
      v_err := 'text is longer than ' || setting_num('intake.max_text_chars') || ' characters';
    end if;
    if v_err is null and nullif(trim(v_norm ->> 'platforms'), '') is not null then
      select array_agg(distinct bp.platform), array_agg(t.x) filter (where bp.id is null)
        into v_platforms, v_bad_platforms
      from unnest(regexp_split_to_array(lower(v_norm ->> 'platforms'), '\s*[,;]\s*')) as t(x)
      left join brand_platforms bp on bp.brand_id = v_brand.id and bp.is_active
        and (bp.platform = trim(t.x) or lower(platform_label(bp.platform)) = trim(t.x))
      where trim(t.x) <> '';
      if coalesce(cardinality(v_bad_platforms), 0) > 0 then
        v_err := 'unknown platform(s): ' || array_to_string(v_bad_platforms, ', ');
      end if;
    end if;
    if v_err is null then
      begin
        v_date := parse_table_date(v_norm -> 'date');
      exception when others then
        v_err := 'date must be YYYY-MM-DD HH:MM';
      end;
      if v_err is null and v_date is not null and (v_date at time zone v_brand.timezone) < now() then
        v_err := 'date is in the past';
      end if;
    end if;
    if v_err is not null then
      v_errors := v_errors || ('row ' || v_rownum || ': ' || v_err);
      continue;
    end if;

    insert into materials (author_user_id, source, parent_material_id, row_number, chat_id, sealed_at, hints)
    values (m.author_user_id, 'table_row', m.id, v_rownum, m.chat_id, now(),
            jsonb_strip_nulls(jsonb_build_object('brand_ids', jsonb_build_array(v_brand.id),
              'platforms', to_jsonb(v_platforms), 'publish_at_local', to_char(v_date, 'YYYY-MM-DD"T"HH24:MI'))))
    on conflict (parent_material_id, row_number) do nothing
    returning id into v_child;
    if v_child is null then
      select id into v_child from materials where parent_material_id = m.id and row_number = v_rownum;
    else
      if v_text is not null then
        insert into material_parts (material_id, kind, ord, source_ref, input_text, extracted_text, extracted_at)
        values (v_child, 'text', 1, 'row:text', v_text, v_text, now());
      end if;
      if v_link is not null then
        insert into material_parts (material_id, kind, ord, source_ref, url, input_text)
        values (v_child, 'url', 2, 'row:link', v_link, v_link);
      end if;
      perform audit(m.author_user_id, 'material.received', 'material', v_child, v_brand.id, v_child,
                    jsonb_build_object('source', 'table_row', 'parent', m.id, 'row', v_rownum));
    end if;
    v_ok := v_ok + 1;
    v_first := least(coalesce(v_first, v_child), v_child);
    v_last := greatest(coalesce(v_last, v_child), v_child);
  end loop;

  update materials set is_container = true where id = m.id;
  perform transition('material', m.id, 'parsed', null, 'table split');
  update material_parts set extracted_text = '', extracted_at = now(),
         extract_meta = jsonb_build_object('rows', v_idx, 'accepted', v_ok, 'rejected', cardinality(v_errors))
   where id = p_part;
  -- start processing of the new row materials
  perform table_rows_start(m.id);
  perform tg_send_chat(m.chat_id, tpl('table.report', jsonb_build_object(
      'material', mcode(m.id), 'file', coalesce(p.file_name, 'table'), 'accepted', v_ok,
      'range', case when v_ok = 0 then '—' else mcode(v_first) || '…' || mcode(v_last) end,
      'rejected', cardinality(v_errors))) ||
    case when cardinality(v_errors) > 0 then E'\n\n' || h(array_to_string(v_errors[1:60], E'\n')) ||
      case when cardinality(v_errors) > 60 then E'\n… +' || (cardinality(v_errors) - 60) || ' more' else '' end else '' end,
    null, 'table_report:' || m.id, m.author_user_id, m.id);
  return jsonb_build_object('accepted', v_ok, 'rejected', cardinality(v_errors));
end $$;
