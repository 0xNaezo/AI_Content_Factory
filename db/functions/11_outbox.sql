-- Outbox: everything the bot says goes through here (throttled, retried, deduplicated) (architecture 7.12).

create or replace function tg_send_chat(p_chat bigint, p_text text, p_keyboard jsonb default null,
                                        p_dedupe text default null, p_user bigint default null,
                                        p_material bigint default null, p_opts jsonb default '{}') returns bigint
language plpgsql as $$
declare
  v_id bigint;
begin
  if p_chat is null then
    return null;
  end if;
  insert into outbox (channel, kind, chat_id, payload, dedupe_key, user_id, material_id, priority, batch_key, send_after)
  values ('telegram', 'message', p_chat,
          jsonb_strip_nulls(jsonb_build_object('text', ellipsis(p_text, 4096), 'keyboard', p_keyboard,
                                               'photo_asset_id', p_opts -> 'photo_asset_id')),
          p_dedupe, p_user, p_material, coalesce((p_opts ->> 'priority')::int, 0), p_opts ->> 'batch_key',
          coalesce((p_opts ->> 'send_after')::timestamptz, now()))
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  return v_id;
end $$;

create or replace function tg_send(p_user bigint, p_text text, p_keyboard jsonb default null,
                                   p_dedupe text default null, p_opts jsonb default '{}') returns bigint
language plpgsql as $$
declare
  u users;
begin
  select * into u from users where id = p_user;
  if u.id is null or u.tg_chat_id is null or u.tg_blocked_bot or u.status <> 'active' then
    return null;
  end if;
  return tg_send_chat(u.tg_chat_id, p_text, p_keyboard, p_dedupe, u.id, (p_opts ->> 'material_id')::bigint, p_opts);
end $$;

-- A message that is sent once and then edited in place (acks, cards, questions).
create or replace function tg_slot(p_slot text, p_chat bigint, p_text text, p_keyboard jsonb default null,
                                   p_photo_asset bigint default null, p_user bigint default null,
                                   p_material bigint default null, p_priority int default 0) returns bigint
language plpgsql as $$
declare
  v_id bigint;
  v_payload jsonb;
begin
  if p_chat is null then
    return null;
  end if;
  v_payload := jsonb_strip_nulls(jsonb_build_object(
    'text', ellipsis(p_text, case when p_photo_asset is null then 4096 else 1024 end),
    'keyboard', coalesce(p_keyboard, '[]'::jsonb), 'photo_asset_id', p_photo_asset));
  insert into outbox (channel, kind, chat_id, slot_key, payload, user_id, material_id, priority)
  values ('telegram', 'slot', p_chat, p_slot, v_payload, p_user, p_material, p_priority)
  on conflict (slot_key) where status = 'queued' and slot_key is not null
  do update set payload = excluded.payload, priority = greatest(outbox.priority, excluded.priority)
  returning id into v_id;
  return v_id;
end $$;

create or replace function tg_document(p_user bigint, p_filename text, p_content text, p_caption text default null,
                                       p_mime text default 'text/yaml') returns bigint
language plpgsql as $$
declare
  u users;
  v_id bigint;
begin
  select * into u from users where id = p_user;
  if u.tg_chat_id is null then
    return null;
  end if;
  insert into outbox (channel, kind, chat_id, payload, user_id)
  values ('telegram', 'document', u.tg_chat_id,
          jsonb_build_object('filename', p_filename, 'content', p_content, 'caption', coalesce(p_caption, ''), 'mime', p_mime), u.id)
  returning id into v_id;
  return v_id;
end $$;

create or replace function tg_answer_callback(p_callback_id text, p_text text default null, p_alert boolean default false) returns void
language sql as $$
  insert into outbox (channel, kind, chat_id, payload, priority, dedupe_key)
  values ('telegram', 'callback_answer', 0,
          jsonb_strip_nulls(jsonb_build_object('callback_query_id', p_callback_id, 'text', ellipsis(p_text, 190),
                                               'show_alert', case when p_alert then true end)),
          100, 'cb:' || p_callback_id)
  on conflict (dedupe_key) do nothing;
$$;

create or replace function email_send(p_to text, p_subject text, p_html text, p_text text default null,
                                      p_dedupe text default null, p_opts jsonb default '{}') returns bigint
language plpgsql as $$
declare
  v_id bigint;
begin
  if p_to is null then
    return null;
  end if;
  insert into outbox (channel, kind, email_to, payload, dedupe_key, user_id, material_id, brand_id)
  values ('email', 'email', p_to,
          jsonb_strip_nulls(jsonb_build_object('from', coalesce(p_opts ->> 'from', setting_text('email.from')), 'to', p_to,
                             'subject', p_subject, 'html', p_html, 'text', p_text, 'reply_to', p_opts ->> 'reply_to',
                             'headers', p_opts -> 'headers')),
          p_dedupe, (p_opts ->> 'user_id')::bigint, (p_opts ->> 'material_id')::bigint, (p_opts ->> 'brand_id')::bigint)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  return v_id;
end $$;

create or replace function notify_admins(p_text text, p_keyboard jsonb default null) returns void
language sql as $$
  select tg_send(u.id, p_text, p_keyboard) from users u where u.is_admin and u.status = 'active';
$$;

-- Notify brand members with given roles (optionally batched: rows with the same batch key merge into one message).
create or replace function notify_brand(p_brand bigint, p_roles text[], p_text text, p_keyboard jsonb default null,
                                        p_dedupe text default null, p_batch boolean default false) returns int
language plpgsql as $$
declare
  n int := 0;
  r record;
begin
  for r in
    select u.id, u.notify_published from memberships m join users u on u.id = m.user_id
    where m.brand_id = p_brand and m.role = any (p_roles) and u.status = 'active'
  loop
    if p_batch and r.notify_published = 'off' then
      continue;
    end if;
    perform tg_send(r.id, p_text, p_keyboard,
                    case when p_dedupe is null then null else p_dedupe || ':' || r.id end,
                    case when p_batch and r.notify_published = 'batch' then
                      jsonb_build_object('batch_key', 'published:' || r.id,
                                         'send_after', now() + make_interval(mins => coalesce(setting_num('notify.published_batch_minutes'), 15)::int))
                    else '{}'::jsonb end);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Build the concrete Bot API call for an outbox row (send vs edit decided at send time from slot state).
create or replace function outbox_request(o outbox) returns jsonb
language plpgsql stable as $$
declare
  p jsonb := o.payload;
  s tg_message_slots;
  a assets;
  v_photo bigint := (p ->> 'photo_asset_id')::bigint;
  v_markup jsonb := case when p ? 'keyboard' then jsonb_build_object('inline_keyboard', p -> 'keyboard') end;
  v_kind text := case when v_photo is null then 'text' else 'photo' end;
begin
  if o.channel = 'email' then
    return jsonb_build_object('method', 'email', 'body', p, 'idempotency_key', 'outbox-' || o.id);
  end if;
  case o.kind
    when 'callback_answer' then
      return jsonb_build_object('method', 'answerCallbackQuery', 'body', p);
    when 'delete' then
      return jsonb_build_object('method', 'deleteMessage', 'body', jsonb_build_object('chat_id', o.chat_id, 'message_id', p -> 'message_id'));
    when 'document' then
      return jsonb_build_object('method', 'sendDocument',
        'body', jsonb_build_object('chat_id', o.chat_id, 'caption', p ->> 'caption', 'parse_mode', 'HTML'),
        'upload', jsonb_build_object('field', 'document', 'text', p ->> 'content', 'filename', p ->> 'filename', 'mime', p ->> 'mime'));
    else
      null;
  end case;

  if v_photo is not null then
    select * into a from assets where id = v_photo;
  end if;
  if o.kind = 'slot' then
    select * into s from tg_message_slots where slot_key = o.slot_key;
  end if;

  if s.message_id is not null and s.content_kind = v_kind then
    if v_photo is null then
      return jsonb_build_object('method', 'editMessageText', 'body', jsonb_strip_nulls(jsonb_build_object(
        'chat_id', o.chat_id, 'message_id', s.message_id, 'text', p ->> 'text', 'parse_mode', 'HTML',
        'link_preview_options', jsonb_build_object('is_disabled', true), 'reply_markup', v_markup)));
    elsif s.photo_asset_id is not distinct from v_photo then
      return jsonb_build_object('method', 'editMessageCaption', 'body', jsonb_strip_nulls(jsonb_build_object(
        'chat_id', o.chat_id, 'message_id', s.message_id, 'caption', p ->> 'text', 'parse_mode', 'HTML', 'reply_markup', v_markup)));
    elsif a.tg_file_id is not null then
      return jsonb_build_object('method', 'editMessageMedia', 'body', jsonb_strip_nulls(jsonb_build_object(
        'chat_id', o.chat_id, 'message_id', s.message_id, 'reply_markup', v_markup,
        'media', jsonb_build_object('type', 'photo', 'media', a.tg_file_id, 'caption', p ->> 'text', 'parse_mode', 'HTML'))));
    else
      return jsonb_build_object('method', 'editMessageMedia', 'body', jsonb_strip_nulls(jsonb_build_object(
        'chat_id', o.chat_id, 'message_id', s.message_id, 'reply_markup', v_markup,
        'media', jsonb_build_object('type', 'photo', 'media', 'attach://file', 'caption', p ->> 'text', 'parse_mode', 'HTML'))),
        'upload', jsonb_build_object('field', 'file', 's3_key', a.s3_key, 'filename', 'image.' || split_part(a.mime, '/', 2), 'mime', a.mime));
    end if;
  end if;

  if v_photo is null then
    return jsonb_build_object('method', 'sendMessage', 'body', jsonb_strip_nulls(jsonb_build_object(
      'chat_id', o.chat_id, 'text', p ->> 'text', 'parse_mode', 'HTML',
      'link_preview_options', jsonb_build_object('is_disabled', true), 'reply_markup', v_markup)));
  elsif a.tg_file_id is not null then
    return jsonb_build_object('method', 'sendPhoto', 'body', jsonb_strip_nulls(jsonb_build_object(
      'chat_id', o.chat_id, 'photo', a.tg_file_id, 'caption', p ->> 'text', 'parse_mode', 'HTML', 'reply_markup', v_markup)));
  else
    return jsonb_build_object('method', 'sendPhoto', 'body', jsonb_strip_nulls(jsonb_build_object(
      'chat_id', o.chat_id, 'caption', p ->> 'text', 'parse_mode', 'HTML', 'reply_markup', v_markup)),
      'upload', jsonb_build_object('field', 'photo', 's3_key', a.s3_key, 'filename', 'image.' || split_part(a.mime, '/', 2), 'mime', a.mime));
  end if;
end $$;

-- Claim sendable rows: one in-flight message per chat (keeps order, respects ~1 msg/s per chat),
-- merges batched rows, returns ready-to-send requests.
create or replace function claim_outbox(p_limit int default 20)
returns table (id bigint, channel text, request jsonb, api_base text, resend_base text, bucket text)
language plpgsql as $$
declare
  r outbox;
  v_taken int := 0;
  v_chats bigint[] := '{}';
  v_text text;
begin
  update outbox o set status = 'queued', locked_until = null
   where o.status = 'sending' and o.locked_until < now();

  for r in
    select * from outbox o
    where o.status = 'queued' and o.send_after <= now()
      and (o.channel = 'email' or o.kind = 'callback_answer' or not exists (
            select 1 from outbox x where x.status = 'sending' and x.chat_id = o.chat_id and x.channel = 'telegram'))
    order by o.priority desc, o.id
    limit p_limit * 4
    for update skip locked
  loop
    exit when v_taken >= p_limit;
    if r.channel = 'telegram' and r.kind <> 'callback_answer' then
      continue when r.chat_id = any (v_chats);
      v_chats := v_chats || r.chat_id;
    end if;
    if r.batch_key is not null then
      select string_agg(x.payload ->> 'text', E'\n\n' order by x.id) into v_text
      from outbox x where x.batch_key = r.batch_key and x.status = 'queued' and x.send_after <= now() + interval '1 day';
      update outbox x set status = 'merged', sent_at = now()
       where x.batch_key = r.batch_key and x.status = 'queued' and x.id <> r.id;
      r.payload := jsonb_set(r.payload, '{text}', to_jsonb(ellipsis(v_text, 4096)));
    end if;
    update outbox o set status = 'sending', attempts = o.attempts + 1, locked_until = now() + interval '90 seconds',
                        payload = r.payload
     where o.id = r.id;
    v_taken := v_taken + 1;
    id := r.id;
    channel := r.channel;
    request := outbox_request(r);
    api_base := setting_text('api.telegram_base');
    resend_base := setting_text('api.resend_base');
    bucket := setting_text('s3.bucket');
    return next;
  end loop;
end $$;

-- Record the Bot API / Resend response. p_http = 0 means network error (no response).
create or replace function outbox_result(p_id bigint, p_http int, p_response jsonb, p_error text default null) returns jsonb
language plpgsql as $$
declare
  o outbox;
  v_ok boolean := p_http between 200 and 299 and coalesce((p_response ->> 'ok')::boolean, true);
  v_desc text := coalesce(p_response ->> 'description', p_response #>> '{error,message}', p_response ->> 'message', p_error, '');
  v_msg jsonb := p_response -> 'result';
  v_photo bigint;
  v_retry int;
begin
  select * into o from outbox where id = p_id for update;
  if o.id is null or o.status <> 'sending' then
    return job_flags();
  end if;
  v_photo := (o.payload ->> 'photo_asset_id')::bigint;

  if v_ok or v_desc ilike '%message is not modified%' then
    update outbox set status = 'sent', sent_at = now(), locked_until = null,
                      result = case when jsonb_typeof(v_msg) = 'object'
                                    then jsonb_build_object('message_id', v_msg -> 'message_id', 'id', p_response -> 'id')
                                    else p_response end
     where id = p_id;
    if o.kind = 'slot' and jsonb_typeof(v_msg) = 'object' then
      insert into tg_message_slots (slot_key, chat_id, message_id, content_kind, photo_asset_id, updated_at)
      values (o.slot_key, o.chat_id, (v_msg ->> 'message_id')::bigint,
              case when v_photo is null then 'text' else 'photo' end, v_photo, now())
      on conflict (slot_key) do update set message_id = excluded.message_id, content_kind = excluded.content_kind,
                                           photo_asset_id = excluded.photo_asset_id, chat_id = excluded.chat_id, updated_at = now();
    end if;
    if v_photo is not null and jsonb_typeof(v_msg -> 'photo') = 'array' then
      update assets set tg_file_id = v_msg -> 'photo' -> -1 ->> 'file_id' where id = v_photo and tg_file_id is null;
    end if;
  elsif o.kind = 'slot' and (v_desc ilike '%message to edit not found%' or v_desc ilike '%message can''t be edited%'
                             or v_desc ilike '%there is no media in the message%' or v_desc ilike '%message_id_invalid%') then
    delete from tg_message_slots where slot_key = o.slot_key;
    update outbox set status = 'queued', locked_until = null, last_error = left(v_desc, 500) where id = p_id;
  elsif p_http = 429 then
    v_retry := coalesce((p_response #>> '{parameters,retry_after}')::int, 5);
    update outbox set status = 'queued', locked_until = null, send_after = now() + make_interval(secs => v_retry),
                      last_error = left(v_desc, 500)
     where id = p_id;
  elsif p_http = 403 and o.channel = 'telegram' then
    update outbox set status = 'failed', locked_until = null, last_error = left(v_desc, 500) where id = p_id;
    update users set tg_blocked_bot = true where tg_chat_id = o.chat_id;
  elsif p_http between 400 and 499 or o.attempts >= 6 then
    update outbox set status = case when p_http between 400 and 499 then 'failed' else 'dead' end,
                      locked_until = null, last_error = left(p_http || ' ' || v_desc, 500)
     where id = p_id;
  else
    update outbox set status = 'queued', locked_until = null, last_error = left(p_http || ' ' || v_desc, 500),
                      send_after = now() + make_interval(secs => (power(2, o.attempts))::int * 5)
     where id = p_id;
  end if;
  return job_flags();
end $$;
