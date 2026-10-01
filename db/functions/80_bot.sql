-- Telegram bot: update router, commands, buttons, dialog input (architecture 7.1). One webhook, one job per update.

create or replace function bot_session_set(p_user bigint, p_kind text, p_data jsonb, p_minutes int default 30) returns void
language sql as $$
  insert into bot_sessions (user_id, kind, data, expires_at)
  values (p_user, p_kind, p_data, now() + make_interval(mins => p_minutes))
  on conflict (user_id) do update set kind = excluded.kind, data = excluded.data, expires_at = excluded.expires_at, created_at = now();
$$;

create or replace function bot_help(p_user bigint) returns text
language plpgsql stable as $$
declare
  u users;
  v_roles text[];
begin
  select * into u from users where id = p_user;
  select array_agg(distinct role) into v_roles from memberships where user_id = p_user;
  return tpl('help.author', '{}')
    || case when u.is_admin or v_roles && array['manager', 'editor'] then E'\n\n' || tpl('help.editor', '{}') else '' end
    || case when u.is_admin or v_roles && array['manager'] then E'\n\n' || tpl('help.manager', '{}') else '' end
    || case when u.is_admin then E'\n\n' || tpl('help.admin', '{}') else '' end;
end $$;

create or replace function guest_menu(p_user bigint) returns void
language plpgsql as $$
begin
  perform tg_send(p_user, tpl('guest.menu', '{}'),
    kb_grid((select coalesce(jsonb_agg(btn(name, 'gb:' || id) order by name), '[]') from brands where is_demo and status = 'active'), 1)
    || kb(jsonb_build_array(btn('✍️ Describe my business', 'gn'))));
end $$;

-- Material history and cost by ID (tz section 8 tracing, 11 acceptance).
create or replace function material_trace_text(p_material bigint, p_user bigint) returns text
language plpgsql stable as $$
declare
  m materials;
  v_ok boolean;
  v_cost numeric;
  v_pk text;
  v_log text;
begin
  select * into m from materials where id = p_material;
  if m.id is null then
    return tpl('err.not_found', '{}');
  end if;
  v_ok := m.author_user_id = p_user or can(p_user, null, 'admin')
          or exists (select 1 from packages p where p.material_id = m.id and can(p_user, p.brand_id, 'view'));
  if not v_ok then
    return tpl('err.not_found', '{}');
  end if;
  select coalesce(sum(cost_usd), 0) into v_cost from ai_usage where material_id = m.id;
  select string_agg('• ' || h(b.name) || ' #' || p.id || case when p.cancelled_at is not null then ' (cancelled)' else '' end || E'\n' ||
           (select string_agg('   ' || h(platform_label(v.platform)) || ': ' || status_label(v.status) ||
                   coalesce(' — ' || h(v.external_url), ''), E'\n' order by v.id) from variants v where v.package_id = p.id), E'\n' order by p.id)
    into v_pk
  from packages p join brands b on b.id = p.brand_id where p.material_id = m.id;
  select string_agg(to_char(at, 'DD.MM HH24:MI') || ' ' || h(action || coalesce(' ' || (data ->> 'to'), '')), E'\n' order by id desc)
    into v_log from (select * from audit_log where material_id = m.id order by id desc limit 12) a;
  return tpl('trace', jsonb_build_object('material', mcode(m.id), 'status', m.status, 'source', m.source,
                                         'created', to_char(m.created_at, 'DD Mon YYYY HH24:MI'), 'author', coalesce(user_label(m.author_user_id), '—'),
                                         'parts', material_parts_summary(m.id), 'cost', fmt_usd(v_cost)))
    || E'\n\n' || coalesce(v_pk, '—')
    || E'\n\n<b>Timeline</b>\n' || coalesce(v_log, '—')
    || E'\n\n' || tpl('trace.panel', jsonb_build_object('url', public_web_url() || '/panel/materials/' || m.id));
end $$;

-- Magic link for the read-only panel (tz 7.11): one-time, short-lived; only the hash is stored.
create or replace function panel_link(p_user bigint) returns text
language plpgsql as $$
declare
  v_token text := encode(gen_random_bytes(24), 'hex');
begin
  insert into panel_login_tokens (token_hash, user_id, expires_at)
  values (digest(v_token, 'sha256'), p_user, now() + make_interval(mins => coalesce(setting_num('panel.magic_link_ttl_minutes'), 15)::int));
  return public_web_url() || '/panel/login?token=' || v_token;
end $$;

create or replace function examples_message(p_user bigint, p_brand bigint) returns void
language plpgsql as $$
declare
  v_text text;
  v_kb jsonb;
begin
  select string_agg('#' || id || ' ' || kind || ' (' || source || coalesce(', ' || platform, '') || '): ' ||
                    h(ellipsis(coalesce(comment, after_text, before_text), 140)), E'\n' order by id desc),
         kb_grid(jsonb_agg(btn('🗑 #' || id, 'exd:' || id) order by id desc), 4)
    into v_text, v_kb
  from (select * from feedback_examples where brand_id = p_brand and deleted_at is null order by id desc limit 20) f;
  perform tg_slot('examples:' || p_brand || ':' || p_user, (select tg_chat_id from users where id = p_user),
                  tpl('examples.list', jsonb_build_object('brand', (select name from brands where id = p_brand))) || E'\n\n' || coalesce(v_text, '—'),
                  coalesce(v_kb, '[]'), null, p_user);
end $$;

create or replace function brand_for_command(p_user bigint, p_ref text, p_action text) returns brands
language plpgsql stable as $$
declare
  b brands;
begin
  if coalesce(trim(p_ref), '') = '' then
    select br.* into b from brands br where br.status <> 'archived' and can(p_user, br.id, p_action)
    order by br.id limit 1;
    if (select count(*) from brands br where br.status <> 'archived' and can(p_user, br.id, p_action)) > 1 then
      raise exception '%', tpl('err.brand_required', '{}');
    end if;
  else
    b := brand_by_ref(trim(p_ref));
  end if;
  if b.id is null then
    raise exception '%', tpl('err.unknown_brand', jsonb_build_object('brand', coalesce(p_ref, '')));
  end if;
  perform require_can(p_user, b.id, p_action);
  return b;
end $$;

create or replace function bot_command(u users, p_text text, p_msg jsonb, p_event bigint) returns void
language plpgsql as $$
declare
  v_cmd text := lower(split_part(split_part(trim(p_text), ' ', 1), '@', 1));
  v_args text := trim(substr(trim(p_text), char_length(split_part(trim(p_text), ' ', 1)) + 1));
  v_a text[] := regexp_split_to_array(v_args, '\s+');
  b brands;
  v_res jsonb;
  v_token text;
  v_ids bigint[];
  v_user users;
  v_text text;
  v_id bigint;
  v_bp bigint;
begin
  begin
    case v_cmd
      when '/start' then
        if v_args <> '' and v_args ~ '^[a-f0-9]{32}$' then
          v_res := invite_accept(u.id, v_args);
          if (v_res ->> 'ok')::boolean then
            perform tg_send(u.id, tpl('invite.accepted', jsonb_build_object('role', v_res ->> 'role', 'brands', v_res ->> 'brands')) || E'\n\n' || bot_help(u.id));
          else
            perform tg_send(u.id, tpl('invite.invalid', '{}'));
          end if;
        elsif has_any_access(u.id) then
          perform tg_send(u.id, tpl('start.member', jsonb_build_object('name', u.display_name)) || E'\n\n' || bot_help(u.id));
        else
          perform tg_send(u.id, tpl('start.unknown', '{}'), kb(jsonb_build_array(btn('🔑 Request access', 'ar'), btn('🎮 Try the demo', 'gd'))));
        end if;
      when '/help' then
        perform tg_send(u.id, case when has_any_access(u.id) then bot_help(u.id) else tpl('start.unknown', '{}') end);
      when '/cancel' then
        delete from bot_sessions where user_id = u.id;
        perform tg_send(u.id, tpl('session.cancelled', '{}'));
      when '/demo' then
        update users set guest_enabled = true where id = u.id;
        perform guest_menu(u.id);
      when '/brands' then
        select string_agg('• ' || h(b2.name) || ' (' || b2.slug || ') — ' || coalesce(m.role, 'admin'), E'\n' order by b2.name) into v_text
        from brands b2 left join memberships m on m.brand_id = b2.id and m.user_id = u.id
        where b2.status <> 'archived' and not b2.is_temporary and (u.is_admin or m.user_id is not null);
        perform tg_send(u.id, tpl('brands.list', '{}') || E'\n' || coalesce(v_text, '—'));
      when '/invite' then
        if cardinality(v_a) < 1 or v_args = '' then
          raise exception '%', tpl('usage.invite', '{}');
        end if;
        if lower(v_a[1]) = 'admin' then
          v_ids := '{}';
        else
          select array_agg(br.id) into v_ids from unnest(regexp_split_to_array(coalesce(v_a[2], ''), ',')) r, brands br
          where br.slug = lower(trim(r)) or lower(br.name) = lower(trim(r));
          if coalesce(cardinality(v_ids), 0) = 0 then
            raise exception '%', tpl('usage.invite', '{}');
          end if;
        end if;
        v_token := invite_create(u.id, lower(v_a[1]), v_ids);
        perform tg_send(u.id, tpl('invite.created', jsonb_build_object('role', lower(v_a[1]),
          'link', 'https://t.me/' || coalesce(nullif(setting_text('bot.username'), ''), 'your_bot') || '?start=' || v_token,
          'hours', setting_num('invite.ttl_hours'))));
      when '/revoke' then
        v_user := user_by_ref(coalesce(v_a[1], ''));
        b := brand_for_command(u.id, v_a[2], 'manage_users');
        if v_user.id is null then
          raise exception '%', tpl('err.unknown_user', '{}');
        end if;
        perform tg_send(u.id, case when access_revoke(u.id, v_user.id, b.id) then tpl('access.revoked', jsonb_build_object('user', user_label(v_user.id), 'brand', b.name))
                                   else tpl('access.not_member', '{}') end);
      when '/users' then
        b := brand_for_command(u.id, v_a[1], 'manage_users');
        select string_agg('• ' || h(user_label(m.user_id)) || ' — ' || m.role, E'\n' order by m.role, m.user_id) into v_text
        from memberships m where m.brand_id = b.id;
        perform tg_send(u.id, '<b>' || h(b.name) || E'</b>\n' || coalesce(v_text, '—'));
      when '/panel' then
        if not has_any_access(u.id) then
          raise exception '%', tpl('err.forbidden', '{}');
        end if;
        perform tg_send(u.id, tpl('panel.link', jsonb_build_object('url', panel_link(u.id), 'minutes', setting_num('panel.magic_link_ttl_minutes'))));
      when '/pause' then
        if lower(coalesce(v_a[1], '')) in ('all', 'system') then
          v_id := pause_create(u.id, 'system', null, null, 'bot');
        elsif v_a[2] is not null and v_a[2] <> '' then
          b := brand_for_command(u.id, v_a[1], 'pause');
          select id into v_bp from brand_platforms where brand_id = b.id and (platform = lower(v_a[2]) or lower(platform_label(platform)) = lower(v_a[2])) limit 1;
          if v_bp is null then
            raise exception '%', tpl('err.unknown_platform', '{}');
          end if;
          v_id := pause_create(u.id, 'platform', b.id, v_bp, 'bot');
        else
          b := brand_for_command(u.id, v_a[1], 'pause');
          v_id := pause_create(u.id, 'brand', b.id, null, 'bot');
        end if;
        perform tg_send(u.id, tpl('pause.created', jsonb_build_object('scope', coalesce(nullif(v_args, ''), 'your brand'))));
      when '/resume' then
        select string_agg('#' || sp.id || ' ' || sp.scope || coalesce(' ' || b2.name, '') || coalesce(' ' || platform_label(bp.platform), '') ||
                          ' since ' || to_char(sp.paused_at, 'DD.MM HH24:MI'), E'\n' order by sp.id),
               jsonb_agg(jsonb_build_array(btn('▶ #' || sp.id || ' publish overdue', 'ur:' || sp.id || ':p'),
                                           btn('🗓 #' || sp.id || ' reschedule', 'ur:' || sp.id || ':r')) order by sp.id)
          into v_text, v_res
        from system_pauses sp left join brands b2 on b2.id = sp.brand_id left join brand_platforms bp on bp.id = sp.brand_platform_id
        where sp.resumed_at is null and (sp.scope = 'system' and can(u.id, null, 'admin') or sp.scope <> 'system' and can(u.id, sp.brand_id, 'pause'));
        perform tg_send(u.id, case when v_text is null then tpl('pause.none', '{}') else tpl('pause.list', '{}') || E'\n' || h(v_text) end, v_res);
      when '/profile' then
        b := brand_for_command(u.id, v_a[1], 'configure');
        perform enqueue_job('profile.export', jsonb_build_object('user_id', u.id), null, null, null, b.id);
        perform bot_session_set(u.id, 'profile_upload', jsonb_build_object('brand_id', b.id), 60);
      when '/newbrand' then
        perform require_can(u.id, null, 'admin');
        if coalesce(v_a[1], '') !~ '^[a-z0-9][a-z0-9-]{1,39}$' or coalesce(v_a[2], '') = '' then
          raise exception '%', tpl('usage.newbrand', '{}');
        end if;
        insert into brands (slug, name, status) values (lower(v_a[1]), trim(substr(v_args, char_length(v_a[1]) + 1)), 'draft') returning id into v_id;
        perform audit(u.id, 'brand.created', 'brand', v_id, v_id, null, jsonb_build_object('slug', v_a[1]));
        perform bot_session_set(u.id, 'onboarding', jsonb_build_object('brand_id', v_id), 120);
        perform tg_send(u.id, tpl('onboarding.start', jsonb_build_object('brand', trim(substr(v_args, char_length(v_a[1]) + 1)))));
      when '/onboard' then
        b := brand_for_command(u.id, v_a[1], 'configure');
        perform bot_session_set(u.id, 'onboarding', jsonb_build_object('brand_id', b.id), 120);
        perform tg_send(u.id, tpl('onboarding.start', jsonb_build_object('brand', b.name)));
      when '/done' then
        v_id := (select (data ->> 'brand_id')::bigint from bot_sessions where user_id = u.id and kind = 'onboarding' and expires_at > now());
        if v_id is null then
          raise exception '%', tpl('err.no_onboarding', '{}');
        end if;
        perform require_can(u.id, v_id, 'configure');
        if (select count(*) from onboarding_samples where brand_id = v_id) < 3 then
          raise exception '%', tpl('onboarding.need_more', '{}');
        end if;
        perform enqueue_job('onboarding.draft', jsonb_build_object('user_id', u.id), null, null, null, v_id,
                            p_dedupe => 'onboarding:' || v_id || ':' || (select count(*) from onboarding_samples where brand_id = v_id));
        delete from bot_sessions where user_id = u.id;
        perform bot_session_set(u.id, 'profile_upload', jsonb_build_object('brand_id', v_id), 240);
        perform tg_send(u.id, tpl('onboarding.drafting', '{}'));
      when '/examples' then
        b := brand_for_command(u.id, v_a[1], 'configure');
        perform examples_message(u.id, b.id);
      when '/budget' then
        b := brand_for_command(u.id, v_a[1], 'view');
        if v_a[2] ~ '^\d+(\.\d+)?$' then
          perform require_can(u.id, null, 'admin');
          update brands set monthly_budget_usd = v_a[2]::numeric where id = b.id;
          perform audit(u.id, 'brand.budget_set', 'brand', b.id, b.id, null, jsonb_build_object('usd', v_a[2]::numeric));
          perform unblock_jobs('budget_exceeded:brand:' || b.id || '%');
        end if;
        perform tg_send(u.id, tpl('budget.status', jsonb_build_object('brand', b.name,
          'spent', fmt_usd(budget_spent('brand', b.id)), 'limit', fmt_usd((select monthly_budget_usd from brands where id = b.id)))));
      when '/m', '/status' then
        perform tg_send(u.id, material_trace_text(nullif(regexp_replace(coalesce(v_a[1], ''), '\D', '', 'g'), '')::bigint, u.id));
      when '/intake' then
        perform tg_send(u.id, tpl('intake.address', jsonb_build_object('address', 'in+' || u.intake_token || '@' || setting_text('email.inbound_domain'))));
      when '/myemail' then
        if coalesce(v_a[1], '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
          raise exception '%', tpl('usage.myemail', '{}');
        end if;
        update users set email = lower(v_a[1]) where id = u.id;
        perform tg_send(u.id, tpl('myemail.set', jsonb_build_object('email', lower(v_a[1]))));
      when '/notify' then
        if lower(coalesce(v_a[1], '')) not in ('each', 'batch', 'off') then
          raise exception '%', tpl('usage.notify', '{}');
        end if;
        update users set notify_published = lower(v_a[1]) where id = u.id;
        perform tg_send(u.id, tpl('notify.set', jsonb_build_object('mode', lower(v_a[1]))));
      when '/digest' then
        b := brand_for_command(u.id, v_a[1], 'approve');
        if lower(coalesce(v_a[2], '')) = 'now' then
          perform digest_plan(b.id, true);
          perform tg_send(u.id, tpl('digest.building', jsonb_build_object('brand', b.name)));
        else
          perform tg_send(u.id, digest_status_text(b.id));
        end if;
      when '/report' then
        b := brand_for_command(u.id, v_a[1], 'view');
        perform tg_send(u.id, weekly_report_text(b.id, now() - interval '7 days', now()));
      when '/jobs' then
        perform require_can(u.id, null, 'admin');
        select string_agg('#' || id || ' ' || type || coalesce(' ' || mcode(material_id), '') || ': ' || h(ellipsis(last_error, 120)), E'\n' order by id desc)
          into v_text from (select * from jobs where status = 'dead' order by id desc limit 15) j;
        perform tg_send(u.id, tpl('jobs.dead', '{}') || E'\n' || coalesce(v_text, '—'));
      when '/retry' then
        perform require_can(u.id, null, 'admin');
        perform tg_send(u.id, case when job_retry(nullif(regexp_replace(coalesce(v_a[1], ''), '\D', '', 'g'), '')::bigint)
                                   then tpl('jobs.retried', '{}') else tpl('err.not_found', '{}') end);
      when '/eval' then
        perform require_can(u.id, null, 'admin');
        v_res := eval_start('bot: ' || u.id, case when v_a[1] in ('generation', 'routing') then v_a[1] end);
        perform tg_send(u.id, tpl('eval.started', jsonb_build_object('run', v_res ->> 'run_id', 'cases', v_res ->> 'cases')));
      else
        perform tg_send(u.id, tpl('err.unknown_command', '{}'));
    end case;
  exception when raise_exception then
    perform tg_send(u.id, '⚠️ ' || sqlerrm);
  end;
end $$;

-- Dialog input for an active bot session (edit text, comment, reason, time, uploads, onboarding samples).
create or replace function bot_session_input(u users, s bot_sessions, p_msg jsonb, p_event bigint) returns void
language plpgsql as $$
declare
  v_text text := coalesce(p_msg ->> 'text', p_msg ->> 'caption');
  v_file jsonb := coalesce(p_msg -> 'photo' -> -1, case when file_kind(p_msg #>> '{document,mime_type}', p_msg #>> '{document,file_name}') = 'image' then p_msg -> 'document' end);
  v_id bigint := coalesce((s.data ->> 'variant_id')::bigint, (s.data ->> 'package_id')::bigint, (s.data ->> 'material_id')::bigint, (s.data ->> 'brand_id')::bigint);
  v_at timestamptz;
  v_part bigint;
  m materials;
  n int;
begin
  begin
    case s.kind
      when 'clarify' then
        select * into m from materials where id = v_id for update;
        if m.status <> 'awaiting_author' then
          delete from bot_sessions where user_id = u.id;
          perform intake_tg_message(u, p_msg, p_event);
          return;
        end if;
        if p_msg ? 'voice' or p_msg ? 'audio' then
          insert into material_parts (material_id, kind, ord, inbound_event_id, source_ref, tg_file_id, tg_file_unique_id, mime, file_name, size_bytes, duration_s)
          values (m.id, 'voice', (select coalesce(max(ord), 0) + 1 from material_parts where material_id = m.id), p_event,
                  'tg:' || (p_msg ->> 'message_id') || ':clarify', coalesce(p_msg #>> '{voice,file_id}', p_msg #>> '{audio,file_id}'),
                  coalesce(p_msg #>> '{voice,file_unique_id}', p_msg #>> '{audio,file_unique_id}'), 'audio/ogg', 'voice.ogg',
                  coalesce((p_msg #>> '{voice,file_size}')::bigint, (p_msg #>> '{audio,file_size}')::bigint),
                  coalesce((p_msg #>> '{voice,duration}')::int, (p_msg #>> '{audio,duration}')::int))
          on conflict do nothing returning id into v_part;
          if v_part is not null then
            perform enqueue_job('part.process', jsonb_build_object('part_id', v_part), m.id, p_dedupe => 'part:' || v_part);
          end if;
        elsif coalesce(trim(v_text), '') <> '' then
          insert into material_parts (material_id, kind, ord, inbound_event_id, source_ref, input_text, extracted_text, extracted_at)
          values (m.id, 'clarification', (select coalesce(max(ord), 0) + 1 from material_parts where material_id = m.id), p_event,
                  'tg:' || (p_msg ->> 'message_id') || ':clarify', v_text, v_text, now())
          on conflict do nothing;
        else
          raise exception '%', tpl('session.expected_text', '{}');
        end if;
        update materials set revision = revision + 1 where id = m.id;
        perform close_question(m.id);
        perform material_try_summarize(m.id);
      when 'edit_text' then
        if coalesce(trim(p_msg ->> 'text'), '') = '' then raise exception '%', tpl('session.expected_text', '{}'); end if;
        delete from bot_sessions where user_id = u.id;
        perform human_edit(v_id, p_msg ->> 'text', u.id, 'edit');
        perform tg_send(u.id, tpl('edit.saved', '{}'));
      when 'edit_published' then
        if coalesce(trim(p_msg ->> 'text'), '') = '' then raise exception '%', tpl('session.expected_text', '{}'); end if;
        delete from bot_sessions where user_id = u.id;
        perform human_edit(v_id, p_msg ->> 'text', u.id, 'edit_published');
        perform tg_send(u.id, tpl('edit.published_saved', '{}'));
      when 'redo_comment' then
        if coalesce(trim(p_msg ->> 'text'), '') = '' then raise exception '%', tpl('session.expected_text', '{}'); end if;
        delete from bot_sessions where user_id = u.id;
        perform redo_variant(v_id, p_msg ->> 'text', u.id);
        perform tg_send(u.id, tpl('redo.started', '{}'));
      when 'reject_reason' then
        delete from bot_sessions where user_id = u.id;
        perform reject_variant(v_id, s.data ->> 'reason', v_text, u.id);
        perform tg_send(u.id, tpl('reject.saved', '{}'));
      when 'time_entry' then
        v_at := parse_user_time(coalesce(v_text, ''), brand_tz(variant_brand(v_id)));
        if v_at is null then raise exception '%', tpl('time.bad_format', '{}'); end if;
        delete from bot_sessions where user_id = u.id;
        perform set_variant_time(v_id, v_at, u.id);
        perform tg_send(u.id, tpl('time.set', jsonb_build_object('at', fmt_local(v_at, brand_tz(variant_brand(v_id))))));
      when 'own_visual' then
        if v_file is null then raise exception '%', tpl('session.expected_photo', '{}'); end if;
        perform require_can(u.id, (select brand_id from packages where id = v_id), 'approve');
        delete from bot_sessions where user_id = u.id;
        perform enqueue_job('package.visual', jsonb_build_object('mode', 'upload', 'tg_file_id', v_file ->> 'file_id', 'user_id', u.id,
                                                                 'mime', coalesce(v_file ->> 'mime_type', 'image/jpeg')),
                            (select material_id from packages where id = v_id), v_id, null, (select brand_id from packages where id = v_id),
                            p_dedupe => 'visual:' || v_id || ':upload:' || (p_msg ->> 'message_id'));
        perform tg_send(u.id, tpl('visual.upload_started', '{}'));
      when 'profile_upload' then
        if not (p_msg ? 'document') then
          delete from bot_sessions where user_id = u.id;
          perform bot_message_intake(u, p_msg, p_event);
          return;
        end if;
        perform require_can(u.id, v_id, 'configure');
        perform enqueue_job('profile.import', jsonb_build_object('user_id', u.id, 'tg_file_id', p_msg #>> '{document,file_id}',
                                                                 'file_name', p_msg #>> '{document,file_name}'),
                            null, null, null, v_id, p_dedupe => 'profile_import:' || (p_msg ->> 'message_id') || ':' || u.id);
        perform tg_send(u.id, tpl('profile.import_started', '{}'));
      when 'onboarding' then
        perform require_can(u.id, v_id, 'configure');
        if coalesce(trim(v_text), '') = '' then raise exception '%', tpl('session.expected_text', '{}'); end if;
        if v_text ~ url_regex() and char_length(trim(regexp_replace(v_text, url_regex(), '', 'g'))) < 20 then
          insert into onboarding_samples (brand_id, kind, content, created_by)
          select v_id, 'url', rtrim(mm[1], '.,;)'), u.id from regexp_matches(v_text, '(' || url_regex() || ')', 'g') mm;
        else
          insert into onboarding_samples (brand_id, kind, content, created_by) values (v_id, 'text', trim(v_text), u.id);
        end if;
        select count(*) into n from onboarding_samples where brand_id = v_id;
        perform tg_send(u.id, tpl('onboarding.sample_added', jsonb_build_object('count', n)));
      when 'guest_business' then
        if coalesce(trim(v_text), '') = '' then raise exception '%', tpl('session.expected_text', '{}'); end if;
        delete from bot_sessions where user_id = u.id;
        perform enqueue_job('guest.brand', jsonb_build_object('user_id', u.id, 'description', left(v_text, 500)),
                            p_dedupe => 'guest_brand:' || u.id || ':' || (p_msg ->> 'message_id'));
        perform tg_send(u.id, tpl('guest.brand_building', '{}'));
      else
        delete from bot_sessions where user_id = u.id;
        perform bot_message_intake(u, p_msg, p_event);
    end case;
  exception when raise_exception then
    perform tg_send(u.id, '⚠️ ' || sqlerrm || E'\n' || tpl('session.hint_cancel', '{}'));
  end;
end $$;

-- Plain message: intake for members and guests; unknown senders get "request access / try demo" (IN-8).
create or replace function bot_message_intake(u users, p_msg jsonb, p_event bigint) returns void
language plpgsql as $$
begin
  if has_any_access(u.id) then
    perform intake_tg_message(u, p_msg, p_event);
  elsif u.guest_enabled and u.guest_brand_id is not null then
    perform intake_tg_message(u, p_msg, p_event);
  elsif u.guest_enabled then
    perform guest_menu(u.id);
  else
    perform tg_send(u.id, tpl('start.unknown', '{}'), kb(jsonb_build_array(btn('🔑 Request access', 'ar'), btn('🎮 Try the demo', 'gd'))),
                    'unknown:' || u.id || ':' || current_date);
    if alert_once('unknown_sender:' || u.id, interval '1 day') then
      perform notify_admins(tpl('admin.unknown_sender', jsonb_build_object('user', user_label(u.id), 'tg_id', u.tg_user_id)));
    end if;
    perform audit(u.id, 'intake.refused_unknown', 'inbound_event', p_event, null, null, '{}');
  end if;
end $$;

create or replace function bot_message(p_msg jsonb, p_event bigint) returns void
language plpgsql as $$
declare
  u users;
  s bot_sessions;
  v_text text := p_msg ->> 'text';
begin
  u := tg_user_upsert(p_msg -> 'from', (p_msg #>> '{chat,id}')::bigint);
  if u.status <> 'active' then
    return;
  end if;
  if v_text ~ '^/[a-zA-Z]' then
    perform bot_command(u, v_text, p_msg, p_event);
    return;
  end if;
  select * into s from bot_sessions where user_id = u.id and expires_at > now();
  if s.user_id is not null then
    perform bot_session_input(u, s, p_msg, p_event);
    return;
  end if;
  perform bot_message_intake(u, p_msg, p_event);
end $$;

-- Material owned by the user (author buttons).
create or replace function own_material(p_material bigint, p_user bigint) returns materials
language plpgsql stable as $$
declare
  m materials;
begin
  select * into m from materials where id = p_material;
  if m.id is null or m.author_user_id <> p_user then
    raise exception '%', tpl('err.not_found', '{}');
  end if;
  return m;
end $$;

create or replace function toggle_hint(p_material bigint, p_key text) returns void
language sql as $$
  update materials set hints = jsonb_set(hints, array[p_key], to_jsonb(not coalesce((hints ->> p_key)::boolean, false)))
  where id = p_material and status = 'received' and sealed_at is null
$$;

create or replace function bot_callback(p_cq jsonb) returns void
language plpgsql as $$
declare
  u users;
  v_data text := coalesce(p_cq ->> 'data', '');
  a text[] := string_to_array(v_data, ':');
  v_code text := a[1];
  v_id bigint := case when a[2] ~ '^\d{1,18}$' then a[2]::bigint end;
  v_id2 bigint := case when a[3] ~ '^\d{1,18}$' then a[3]::bigint end;
  v_answer text := null;
  v_alert boolean := false;
  m materials;
  v variants;
  p packages;
  v_res jsonb;
  v_sel jsonb;
  v_kb jsonb;
  v_text text;
  v_kind text;
  v_slots jsonb;
  t timestamptz;
  i int;
begin
  u := tg_user_upsert(p_cq -> 'from', (p_cq #>> '{message,chat,id}')::bigint);
  begin
    if u.status <> 'active' then
      raise exception '%', tpl('err.forbidden', '{}');
    end if;
    case v_code
      -- material author buttons (ack)
      when 'mp' then
        m := own_material(v_id, u.id);
        perform material_seal(m.id, true);
        v_answer := 'Processing…';
      when 'mx' then
        m := own_material(v_id, u.id);
        if m.status not in ('received', 'awaiting_author') then raise exception '%', tpl('err.too_late_cancel', '{}'); end if;
        perform material_reject(m.id, tpl('material.cancelled_by_author', '{}'), u.id);
        v_answer := 'Cancelled';
      when 'md' then
        m := own_material(v_id, u.id);
        perform toggle_hint(m.id, 'digest_only');
        perform render_ack(m.id);
      when 'mu' then
        m := own_material(v_id, u.id);
        perform toggle_hint(m.id, 'urgent');
        perform render_ack(m.id);
      when 'mb' then
        m := own_material(v_id, u.id);
        perform tg_slot('mbrand:' || m.id, m.chat_id, tpl('material.choose_brand', jsonb_build_object('material', mcode(m.id))),
          kb_grid((select jsonb_agg(btn(case when (m.hints -> 'brand_ids') @> to_jsonb(b.brand_id) then '✅ ' else '' end || b.name,
                                        'mbt:' || m.id || ':' || b.brand_id) order by b.name) from user_submit_brands(u.id) b), 2),
          null, u.id, m.id, 10);
      when 'mbt' then
        m := own_material(v_id, u.id);
        if m.status = 'received' and m.sealed_at is null then
          update materials set hints = jsonb_set(hints, '{brand_ids}',
            case when coalesce(hints -> 'brand_ids', '[]') @> to_jsonb(v_id2)
                 then (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(hints -> 'brand_ids') x where x <> to_jsonb(v_id2))
                 else coalesce(hints -> 'brand_ids', '[]') || to_jsonb(v_id2) end)
          where id = m.id and exists (select 1 from user_submit_brands(u.id) b where b.brand_id = v_id2)
          returning * into m;
          perform tg_slot('mbrand:' || m.id, m.chat_id, tpl('material.choose_brand', jsonb_build_object('material', mcode(m.id))),
            kb_grid((select jsonb_agg(btn(case when (m.hints -> 'brand_ids') @> to_jsonb(b.brand_id) then '✅ ' else '' end || b.name,
                                          'mbt:' || m.id || ':' || b.brand_id) order by b.name) from user_submit_brands(u.id) b), 2),
            null, u.id, m.id, 10);
          perform render_ack(m.id);
        end if;
      -- author answers to questions
      when 'qb' then
        m := own_material(v_id, u.id);
        if not exists (select 1 from user_submit_brands(u.id) where brand_id = v_id2) and not m.is_guest then
          raise exception '%', tpl('err.forbidden', '{}');
        end if;
        perform route_apply(m.id, array[v_id2], 'author_choice', u.id);
        v_answer := 'Brand selected';
      when 'qbo' then
        m := own_material(v_id, u.id);
        perform tg_slot('q:' || m.id, m.chat_id, tpl('q.brand_all', jsonb_build_object('material', mcode(m.id))), question_keyboard(m.id, 'brand_all'), null, u.id, m.id, 10);
      when 'qbm' then
        m := own_material(v_id, u.id);
        update materials set question = coalesce(question, '{}') || '{"selected": []}' where id = m.id;
        perform tg_slot('q:' || m.id, m.chat_id, tpl('q.brand_multi', jsonb_build_object('material', mcode(m.id))), question_keyboard(m.id, 'brand_multi'), null, u.id, m.id, 10);
      when 'qbt' then
        m := own_material(v_id, u.id);
        v_sel := coalesce(m.question -> 'selected', '[]');
        v_sel := case when v_sel @> to_jsonb(v_id2) then (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(v_sel) x where x <> to_jsonb(v_id2))
                      else v_sel || to_jsonb(v_id2) end;
        update materials set question = coalesce(question, '{}') || jsonb_build_object('selected', v_sel) where id = m.id;
        perform tg_slot('q:' || m.id, m.chat_id, tpl('q.brand_multi', jsonb_build_object('material', mcode(m.id))), question_keyboard(m.id, 'brand_multi'), null, u.id, m.id, 10);
      when 'qbc' then
        m := own_material(v_id, u.id);
        perform route_apply(m.id, array(select x::bigint from jsonb_array_elements_text(coalesce(m.question -> 'selected', '[]')) x
                                        where x::bigint in (select brand_id from user_submit_brands(u.id))), 'author_choice', u.id);
        v_answer := 'Packages are being created';
      when 'qdn' then
        m := own_material(v_id, u.id);
        perform close_question(m.id);
        perform material_continue(m.id);
        v_answer := 'OK, creating a new one';
      when 'qdx', 'qox' then
        m := own_material(v_id, u.id);
        perform material_reject(m.id, tpl('material.cancelled_by_author', '{}'), u.id);
      when 'qcs' then
        m := own_material(v_id, u.id);
        update materials set low_data = true where id = m.id;
        perform close_question(m.id);
        perform enqueue_job('material.route', '{}', m.id, p_dedupe => 'route:' || m.id || ':' || m.revision);
      -- card navigation
      when 'cv', 'cm', 'cb' then
        select * into p from packages where id = v_id;
        if not exists (select 1 from card_audience(p.id) x where x.id = u.id) then
          raise exception '%', tpl('err.forbidden', '{}');
        end if;
        insert into card_views (package_id, user_id, variant_id, menu)
        values (p.id, u.id, coalesce(v_id2, (select id from variants where package_id = p.id order by id limit 1)), 'main')
        on conflict (package_id, user_id) do update set
          variant_id = case when v_code = 'cv' and excluded.variant_id is not null then excluded.variant_id else card_views.variant_id end,
          menu = case when v_code = 'cm' and card_views.menu = 'main' then 'more' else 'main' end;
        perform card_render_one(p.id, u.id);
      -- approval
      when 'ap' then
        v_res := approve_and_schedule(v_id, u.id, v_id2::int);
        v_answer := 'Approved · ' || coalesce(fmt_local((v_res ->> 'scheduled_at')::timestamptz, brand_tz(variant_brand(v_id))), '');
      when 'aa' then
        select * into p from packages where id = v_id;
        perform require_can(u.id, p.brand_id, 'approve');
        i := 0;
        for v in select * from variants where package_id = p.id and status = 'pending_approval' order by id loop
          perform approve_and_schedule(v.id, u.id);
          i := i + 1;
        end loop;
        v_answer := 'Approved: ' || i;
      when 'rj' then
        perform require_can(u.id, variant_brand(v_id), 'approve');
        perform tg_send(u.id, tpl('reject.choose_reason', '{}'), kb(
          jsonb_build_array(btn('Off-brand', 'rr:' || v_id || ':brand'), btn('Factual error', 'rr:' || v_id || ':facts')),
          jsonb_build_array(btn('Low quality', 'rr:' || v_id || ':quality'), btn('Off-topic', 'rr:' || v_id || ':topic')),
          jsonb_build_array(btn('Duplicate', 'rr:' || v_id || ':duplicate'), btn('Other', 'rr:' || v_id || ':other'))));
      when 'rr' then
        perform require_can(u.id, variant_brand(v_id), 'approve');
        perform bot_session_set(u.id, 'reject_reason', jsonb_build_object('variant_id', v_id, 'reason', a[3]), 15);
        perform tg_send(u.id, tpl('reject.comment', '{}'), kb(jsonb_build_array(btn('⏭ Skip', 'rs:' || v_id))));
      when 'rs' then
        select (data ->> 'reason') into v_text from bot_sessions where user_id = u.id and kind = 'reject_reason' and (data ->> 'variant_id')::bigint = v_id;
        delete from bot_sessions where user_id = u.id;
        perform reject_variant(v_id, coalesce(v_text, 'other'), null, u.id);
        v_answer := 'Rejected';
      when 'ed' then
        select * into v from variants where id = v_id;
        perform require_can(u.id, variant_brand(v.id), 'approve');
        v_kind := variant_kind(v.id);
        perform bot_session_set(u.id, 'edit_text', jsonb_build_object('variant_id', v.id, 'version', v.current_version), 30);
        v_text := content_to_text(v_kind, (select content from variant_versions where variant_id = v.id and version = v.current_version));
        perform tg_send(u.id, tpl('edit.prompt', jsonb_build_object('platform', platform_label(v.platform))) || E'\n\n<code>' || h(ellipsis(v_text, 3800)) || '</code>');
      when 'rd' then
        perform require_can(u.id, variant_brand(v_id), 'approve');
        perform tg_send(u.id, tpl('redo.choose', '{}'), kb(
          jsonb_build_array(btn('✂️ Shorter', 'rq:' || v_id || ':shorter'), btn('🚫 No emoji', 'rq:' || v_id || ':noemoji')),
          jsonb_build_array(btn('🎩 More formal', 'rq:' || v_id || ':formal'), btn('🙂 More casual', 'rq:' || v_id || ':casual')),
          jsonb_build_array(btn('✍️ My comment…', 'rc:' || v_id))));
      when 'rq' then
        perform redo_variant(v_id, tpl('redo.preset.' || a[3], '{}'), u.id);
        v_answer := 'Regenerating…';
      when 'rc' then
        perform require_can(u.id, variant_brand(v_id), 'approve');
        perform bot_session_set(u.id, 'redo_comment', jsonb_build_object('variant_id', v_id), 30);
        perform tg_send(u.id, tpl('redo.prompt', '{}'));
      when 'rv' then
        select * into p from packages where id = v_id;
        perform require_can(u.id, p.brand_id, 'approve');
        perform enqueue_job('package.visual', jsonb_build_object('mode', 'regenerate', 'user_id', u.id), p.material_id, p.id, null, p.brand_id,
                            p_dedupe => 'visual:' || p.id || ':regen:' || p.visual_attempt);
        v_answer := 'Generating a new visual…';
      when 'uv' then
        select * into p from packages where id = v_id;
        perform require_can(u.id, p.brand_id, 'approve');
        perform bot_session_set(u.id, 'own_visual', jsonb_build_object('package_id', p.id), 30);
        perform tg_send(u.id, tpl('visual.upload_prompt', '{}'));
      when 'tm' then
        select * into v from variants where id = v_id;
        perform require_can(u.id, variant_brand(v.id), 'approve');
        v_slots := '[]';
        t := now() + interval '15 minutes';
        for i in 1..3 loop
          t := next_free_slot(v.brand_platform_id, t, true, v.id);
          exit when t is null;
          v_slots := v_slots || btn(fmt_local(t, brand_tz(variant_brand(v.id))), 'ts:' || v.id || ':' || extract(epoch from t)::bigint);
          t := t + interval '1 minute';
        end loop;
        perform tg_send(u.id, tpl('time.choose', jsonb_build_object('platform', platform_label(v.platform))),
                        kb_grid(v_slots, 1) || kb(jsonb_build_array(btn('⌨️ Enter date and time', 'te:' || v.id))));
      when 'ts' then
        perform set_variant_time(v_id, to_timestamp(v_id2), u.id);
        v_answer := 'Time set';
      when 'te' then
        perform require_can(u.id, variant_brand(v_id), 'approve');
        perform bot_session_set(u.id, 'time_entry', jsonb_build_object('variant_id', v_id), 15);
        perform tg_send(u.id, tpl('time.prompt', jsonb_build_object('tz', brand_tz(variant_brand(v_id)))));
      when 'rm' then
        perform require_can(u.id, variant_brand(v_id), 'approve');
        perform tg_send(u.id, tpl('remove.confirm', '{}'), kb(jsonb_build_array(btn('➖ Yes, remove', 'rmy:' || v_id))));
      when 'rmy' then
        perform cancel_variant(v_id, u.id);
        v_answer := 'Removed';
      when 'pn' then
        perform require_can(u.id, variant_brand(v_id), 'approve');
        perform tg_send(u.id, tpl('publish_now.confirm', '{}'), kb(jsonb_build_array(btn('🚀 Yes, publish now', 'pny:' || v_id))));
      when 'pny' then
        perform approve_and_schedule(v_id, u.id, null, true);
        v_answer := 'Publishing…';
      when 'ft' then
        select * into v from variants where id = v_id;
        select * into p from packages where id = v.package_id;
        if not exists (select 1 from card_audience(p.id) x where x.id = u.id) then raise exception '%', tpl('err.forbidden', '{}'); end if;
        v_text := content_to_text(variant_kind(v.id), (select content from variant_versions where variant_id = v.id and version = v.current_version));
        perform tg_send(u.id, '<b>' || h(platform_label(v.platform)) || E'</b>\n\n' || h(ellipsis(v_text, 3900)));
      when 'src' then
        select * into p from packages where id = v_id;
        perform require_can(u.id, p.brand_id, 'approve');
        select tpl('source.view', jsonb_build_object('material', mcode(p.material_id), 'idea', e.summary ->> 'main_idea',
                   'language', e.language, 'facts', (select string_agg('• ' || (f ->> 'fact'), E'\n') from jsonb_array_elements(coalesce(e.summary -> 'facts', '[]')) f)))
               || E'\n\n<i>' || h(ellipsis(e.text, 2500)) || '</i>'
          into v_text from material_extracts e where e.material_id = p.material_id;
        perform tg_send(u.id, v_text);
      when 'hl' then
        select * into v from variants where id = v_id;
        perform require_can(u.id, variant_brand(v.id), 'approve');
        select string_agg((ord - 1) || ') ' || h(x), E'\n' order by ord), jsonb_agg(btn('Use ' || (ord - 1), 'hc:' || v.id || ':' || (ord - 1)) order by ord)
          into v_text, v_kb
        from variant_versions vv, jsonb_array_elements_text(vv.headline_options) with ordinality as t(x, ord)
        where vv.variant_id = v.id and vv.version = v.current_version;
        perform tg_send(u.id, tpl('headlines', '{}') || E'\n' || coalesce(v_text, '—'), case when v_kb is not null then jsonb_build_array(v_kb) end);
      when 'hc' then
        perform choose_headline(v_id, v_id2::int, u.id);
        v_answer := 'Headline applied';
      when 'hs' then
        select * into v from variants where id = v_id;
        perform require_can(u.id, variant_brand(v.id), 'approve');
        select string_agg('v' || version || ' · ' || to_char(created_at, 'DD.MM HH24:MI') || ' · ' || reason || ' · ' ||
                          case when author_kind = 'ai' then 'AI' else h(coalesce(user_label(author_user_id), 'human')) end ||
                          coalesce(' · «' || h(ellipsis(comment, 80)) || '»', ''), E'\n' order by version)
          into v_text from variant_versions where variant_id = v.id;
        perform tg_send(u.id, tpl('history', jsonb_build_object('platform', platform_label(v.platform))) || E'\n' || coalesce(v_text, '—'));
      when 'ro' then
        select * into p from packages where id = v_id;
        perform require_can(u.id, p.brand_id, 'approve');
        perform tg_send(u.id, tpl('redirect.choose', '{}'), kb_grid((select jsonb_agg(btn(b.name, 'rob:' || p.id || ':' || b.id) order by b.name)
          from brands b where b.id <> p.brand_id and b.status = 'active' and can(u.id, b.id, 'approve')), 2));
      when 'rob' then
        perform redirect_package(v_id, v_id2, u.id);
        v_answer := 'Redirected';
      -- after publication (PB-7)
      when 'pe' then
        select * into v from variants where id = v_id;
        perform require_can(u.id, variant_brand(v.id), 'approve');
        perform bot_session_set(u.id, 'edit_published', jsonb_build_object('variant_id', v.id), 30);
        perform tg_send(u.id, tpl('edit.published_prompt', '{}') || E'\n\n<code>' ||
          h(ellipsis(content_to_text(variant_kind(v.id), (select content from variant_versions where variant_id = v.id and version = v.current_version)), 3800)) || '</code>');
      when 'pd' then
        perform require_can(u.id, variant_brand(v_id), 'approve');
        perform tg_send(u.id, tpl('delete.confirm', '{}'), kb(jsonb_build_array(btn('🗑 Yes, delete the post', 'pdy:' || v_id))));
      when 'pdy' then
        select * into v from variants where id = v_id;
        perform require_can(u.id, variant_brand(v.id), 'approve');
        if v.status <> 'published' then raise exception '%', tpl('err.not_published', '{}'); end if;
        perform enqueue_job('post.op', jsonb_build_object('op', 'delete', 'user_id', u.id), null, v.package_id, v.id, variant_brand(v.id),
                            p_dedupe => 'postop:delete:' || v.id);
        v_answer := 'Deleting…';
      when 'pr' then
        perform retry_publish(v_id, u.id);
        v_answer := 'Publishing again…';
      when 'ps' then
        select * into v from variants where id = v_id;
        perform require_can(u.id, variant_brand(v.id), 'approve');
        if v.status <> 'failed' then raise exception '%', tpl('err.not_retryable', '{}'); end if;
        perform schedule_variant(v.id, null, u.id);
        perform package_try_card(v.package_id);
        v_answer := 'Moved to the next slot';
      when 'pc' then
        perform cancel_variant(v_id, u.id, 'cancelled after publishing error');
        v_answer := 'Cancelled';
      when 'pm' then
        perform mark_published(v_id, u.id);
        v_answer := 'Marked as published';
      -- digest issue card
      when 'da' then
        v_answer := digest_approve(v_id, u.id);
      when 'dt' then
        v_answer := digest_test(v_id, u.id);
      when 'dx' then
        v_answer := digest_skip(v_id, u.id);
      -- pauses
      when 'ur' then
        i := pause_resume(u.id, v_id, case when a[3] = 'r' then 'reschedule' else 'publish_overdue' end);
        v_answer := 'Resumed' || case when a[3] = 'r' then ', rescheduled: ' || i else '' end;
      -- access, guests
      when 'ar' then
        if alert_once('access_request:' || u.id, interval '1 day') then
          perform notify_admins(tpl('admin.access_request', jsonb_build_object('user', user_label(u.id), 'tg_id', u.tg_user_id, 'name', u.display_name)));
        end if;
        v_answer := 'Request sent to the administrators';
      when 'gd' then
        update users set guest_enabled = true where id = u.id;
        perform guest_menu(u.id);
      when 'gb' then
        if not exists (select 1 from brands where id = v_id and is_demo and status = 'active') then raise exception '%', tpl('err.not_found', '{}'); end if;
        update users set guest_enabled = true, guest_brand_id = v_id where id = u.id;
        perform tg_send(u.id, tpl('guest.brand_selected', jsonb_build_object('brand', (select name from brands where id = v_id))));
      when 'gn' then
        update users set guest_enabled = true where id = u.id;
        perform bot_session_set(u.id, 'guest_business', '{}', 30);
        perform tg_send(u.id, tpl('guest.describe', '{}'));
      -- feedback examples (AP-4)
      when 'exd' then
        select brand_id into v_id2 from feedback_examples where id = v_id;
        perform require_can(u.id, v_id2, 'configure');
        update feedback_examples set deleted_at = now(), deleted_by = u.id where id = v_id and deleted_at is null;
        perform audit(u.id, 'feedback.deleted', 'feedback_example', v_id, v_id2, null, '{}');
        perform examples_message(u.id, v_id2);
        v_answer := 'Deleted';
      -- brand profile
      when 'pa' then
        v_answer := profile_activate(v_id, v_id2::int, u.id);
      when 'od' then
        perform require_can(u.id, v_id, 'configure');
        perform enqueue_job('onboarding.draft', jsonb_build_object('user_id', u.id), null, null, null, v_id,
                            p_dedupe => 'onboarding:' || v_id || ':' || (select count(*) from onboarding_samples where brand_id = v_id) || ':btn');
        v_answer := 'Drafting the profile…';
      else
        v_answer := 'Unknown action';
    end case;
  exception when raise_exception then
    v_answer := sqlerrm;
    v_alert := true;
  end;
  perform tg_answer_callback(p_cq ->> 'id', v_answer, v_alert);
end $$;

-- Channel reactions (AN-2 platform metrics): message_reaction_count updates for our channel posts.
create or replace function tg_reactions(p_upd jsonb) returns void
language sql as $$
  update variants set metrics = metrics || jsonb_build_object('reactions',
      (select coalesce(sum((r ->> 'total_count')::int), 0) from jsonb_array_elements(coalesce(p_upd -> 'reactions', '[]')) r),
      'reactions_at', now())
  where platform = 'telegram' and external_id = (p_upd #>> '{chat,id}') || ':' || (p_upd ->> 'message_id')
$$;

-- Bot added to a channel/group: tell admins the chat id (used as telegram target).
create or replace function tg_chat_member(p_upd jsonb) returns void
language plpgsql as $$
begin
  if p_upd #>> '{new_chat_member,status}' in ('administrator', 'member') and p_upd #>> '{chat,type}' in ('channel', 'supergroup', 'group') then
    perform notify_admins(tpl('admin.bot_added', jsonb_build_object('title', p_upd #>> '{chat,title}', 'chat_id', p_upd #>> '{chat,id}',
                                                                    'status', p_upd #>> '{new_chat_member,status}')));
  end if;
end $$;

-- tg.update job: one Telegram update, recorded by the webhook before any processing (architecture 4.1).
create or replace function bot_handle_update(p_event bigint) returns jsonb
language plpgsql as $$
declare
  e inbound_events;
  upd jsonb;
begin
  select * into e from inbound_events where id = p_event for update;
  if e.id is null or e.status <> 'new' then
    return job_flags();
  end if;
  upd := e.payload;
  -- one Telegram user at a time: concurrent jobs of the same user would race on the glue window and sessions
  perform pg_advisory_xact_lock(hashtextextended('tg_user:' || coalesce(upd #>> '{message,from,id}', upd #>> '{callback_query,from,id}', ''), 0));
  if upd ? 'message' and upd #>> '{message,chat,type}' = 'private' then
    perform bot_message(upd -> 'message', e.id);
  elsif upd ? 'callback_query' then
    perform bot_callback(upd -> 'callback_query');
  elsif upd ? 'message_reaction_count' then
    perform tg_reactions(upd -> 'message_reaction_count');
  elsif upd ? 'my_chat_member' then
    perform tg_chat_member(upd -> 'my_chat_member');
  end if;
  update inbound_events set status = 'processed', processed_at = now() where id = e.id;
  return job_flags();
end $$;

-- Webhook step: record first, return fast. Duplicate deliveries hit the unique key and create nothing.
create or replace function tg_ingest(p_update jsonb) returns jsonb
language plpgsql as $$
declare
  v_id bigint;
begin
  if p_update ->> 'update_id' is null then
    return jsonb_build_object('ok', false);
  end if;
  insert into inbound_events (source, external_key, payload)
  values ('telegram', p_update ->> 'update_id', p_update)
  on conflict (source, external_key) do nothing
  returning id into v_id;
  if v_id is not null then
    perform enqueue_job('tg.update', jsonb_build_object('event_id', v_id), p_dedupe => 'tg:' || v_id,
                        p_priority => case when p_update ? 'callback_query' then 20 else 10 end);
  end if;
  return jsonb_build_object('ok', true, 'new', v_id is not null);
end $$;
