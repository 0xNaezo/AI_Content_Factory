-- Email intake (IN-1) and Resend events. Webhooks are only notifications: content and statuses are re-fetched
-- from the Resend API with our key, so a forged webhook can't inject data (no signing secret needed in n8n).

create or replace function resend_ingest(p_body jsonb, p_svix_id text) returns jsonb
language plpgsql as $$
declare
  v_type text := p_body ->> 'type';
  v_email text := p_body #>> '{data,email_id}';
  v_id bigint;
begin
  if v_type is null or v_email is null then
    return jsonb_build_object('ok', false);
  end if;
  insert into inbound_events (source, external_key, payload)
  values ('resend', coalesce(nullif(p_svix_id, ''), v_type || ':' || v_email), p_body)
  on conflict (source, external_key) do nothing
  returning id into v_id;
  if v_id is not null then
    if v_type = 'email.received' then
      perform enqueue_job('email.fetch', jsonb_build_object('event_id', v_id, 'email_id', v_email), p_dedupe => 'email_fetch:' || v_email);
    elsif v_type in ('email.delivered', 'email.opened', 'email.clicked', 'email.bounced', 'email.complained', 'email.failed') then
      perform enqueue_job('esp.event', jsonb_build_object('event_id', v_id, 'email_id', v_email),
                          p_coalesce => 'esp:' || v_email);
    else
      update inbound_events set status = 'ignored', processed_at = now() where id = v_id;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'new', v_id is not null);
end $$;

create or replace function email_fetch_context(p_event bigint) returns jsonb
language sql stable as $$
  select jsonb_build_object('event_id', e.id, 'email_id', e.payload #>> '{data,email_id}', 'done', e.status <> 'new',
                            'resend_base', setting_text('api.resend_base'), 'bucket', setting_text('s3.bucket'),
                            'max_bytes', setting_num('intake.max_file_bytes'))
  from inbound_events e where e.id = p_event
$$;

-- p_mail: the email as fetched from GET /emails/receiving/{id} (+ attachments uploaded to S3 by n8n).
create or replace function intake_email(p_event bigint, p_mail jsonb) returns jsonb
language plpgsql as $$
declare
  e inbound_events;
  u users;
  m materials;
  v_token text;
  v_from text := lower(coalesce(substring(p_mail ->> 'from' from '<([^>]+)>'), p_mail ->> 'from'));
  v_text text;
  att jsonb;
  v_kind text;
  v_part bigint;
  v_ord int := 1;
  v_err text;
begin
  select * into e from inbound_events where id = p_event for update;
  if e.status <> 'new' then
    return job_flags();
  end if;
  select substring(lower(x) from 'in\+([a-f0-9]{16})@') into v_token
  from jsonb_array_elements_text(coalesce(p_mail -> 'to', '[]') || coalesce(p_mail -> 'received_for', '[]') || coalesce(p_mail -> 'cc', '[]')) x
  where lower(x) ~ 'in\+[a-f0-9]{16}@' limit 1;
  select * into u from users where intake_token = v_token and status = 'active';
  if u.id is null or not has_any_access(u.id) then
    update inbound_events set status = 'ignored', processed_at = now(), error = 'unknown sender' where id = e.id;
    if v_from is not null and alert_once('email_unknown:' || v_from, interval '1 day') then
      perform email_send(v_from, tpl('email.no_access_subject', '{}'), tpl('email.no_access_html', '{}'), null, 'email_no_access:' || e.id);
      perform notify_admins(tpl('admin.unknown_email', jsonb_build_object('from', v_from)));
    end if;
    return job_flags();
  end if;

  v_text := trim(concat_ws(E'\n\n', nullif(trim(p_mail ->> 'subject'), ''), nullif(trim(p_mail ->> 'text'), '')));
  -- limits (IN-2) before creating the material
  for att in select * from jsonb_array_elements(coalesce(p_mail -> 'attachments', '[]')) loop
    v_kind := file_kind(att ->> 'content_type', att ->> 'filename');
    if v_kind is null then
      v_err := tpl('intake.unsupported', jsonb_build_object('what', coalesce(att ->> 'filename', 'attachment')));
    elsif coalesce((att ->> 'size')::bigint, 0) > setting_num('intake.max_file_bytes') then
      v_err := tpl('intake.too_large', jsonb_build_object('size', fmt_bytes((att ->> 'size')::bigint), 'limit', fmt_bytes(setting_num('intake.max_file_bytes')::bigint)));
    end if;
  end loop;
  if v_err is null and char_length(coalesce(v_text, '')) > setting_num('intake.max_text_chars') then
    v_err := tpl('intake.too_long_text', jsonb_build_object('chars', char_length(v_text), 'limit', setting_num('intake.max_text_chars')));
  end if;
  if v_err is not null then
    update inbound_events set status = 'processed', processed_at = now(), error = v_err where id = e.id;
    perform email_send(v_from, 'Re: ' || coalesce(p_mail ->> 'subject', ''), tpl('intake.rejected', jsonb_build_object('reason', v_err)), null, 'email_reject:' || e.id);
    return job_flags();
  end if;

  insert into materials (author_user_id, source, chat_id, reply_email, sealed_at)
  values (u.id, 'email', u.tg_chat_id, v_from, now())
  returning * into m;
  perform audit(u.id, 'material.received', 'material', m.id, null, m.id, jsonb_build_object('source', 'email', 'email_id', p_mail ->> 'id'));
  if coalesce(v_text, '') <> '' then
    insert into material_parts (material_id, kind, ord, inbound_event_id, source_ref, input_text, extracted_text, extracted_at)
    values (m.id, 'text', v_ord, e.id, 'email:text', v_text, v_text, now());
  end if;
  for att in select * from jsonb_array_elements(coalesce(p_mail -> 'attachments', '[]')) where att ->> 's3_key' is not null loop
    v_ord := v_ord + 1;
    insert into material_parts (material_id, kind, ord, inbound_event_id, source_ref, file_name, mime, size_bytes)
    values (m.id, file_kind(att ->> 'content_type', att ->> 'filename'), v_ord, e.id, 'email:att:' || (att ->> 'id'),
            att ->> 'filename', att ->> 'content_type', (att ->> 'size')::bigint)
    returning id into v_part;
    perform part_downloaded(v_part, att ->> 's3_key', att ->> 'sha256', att ->> 'content_type', (att ->> 'size')::bigint);
    perform enqueue_job('part.process', jsonb_build_object('part_id', v_part), m.id, p_dedupe => 'part:' || v_part);
  end loop;
  update inbound_events set status = 'processed', processed_at = now() where id = e.id;
  -- IN-4 ack in the channel the material came from
  perform email_send(v_from, 'Re: ' || coalesce(nullif(p_mail ->> 'subject', ''), mcode(m.id)),
                     tpl('email.received_html', jsonb_build_object('material', mcode(m.id), 'parts', material_parts_summary(m.id))),
                     null, 'email_ack:' || m.id, jsonb_build_object('material_id', m.id, 'user_id', u.id));
  perform material_try_summarize(m.id);
  return job_flags();
end $$;

create or replace function esp_event_context(p_event bigint) returns jsonb
language sql stable as $$
  select jsonb_build_object('email_id', payload #>> '{data,email_id}', 'resend_base', setting_text('api.resend_base'),
                            'tracked', exists (select 1 from digest_deliveries where esp_message_id = payload #>> '{data,email_id}'))
  from inbound_events where id = p_event
$$;
