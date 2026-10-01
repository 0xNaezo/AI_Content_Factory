-- Package card (AP-1, AP-7): one compact message per editor, variants switched with buttons, refreshed for everyone.

create or replace function status_label(p_status text) returns text
language sql immutable as $$
  select case p_status
    when 'draft' then '⚙️ Drafting' when 'pending_approval' then '🟡 Awaiting approval' when 'revising' then '🔄 Revising'
    when 'approved' then '✅ Approved' when 'scheduled' then '🗓 Scheduled' when 'rescheduled' then '🗓 Rescheduled'
    when 'publishing' then '📤 Publishing' when 'failed' then '🔴 Publishing failed' when 'published' then '🟢 Published'
    when 'rejected' then '⛔ Rejected' when 'cancelled' then '➖ Removed' when 'skipped' then '⏭ Skipped' else p_status end
$$;

create or replace function check_label(p_status text) returns text
language sql immutable as $$
  select case p_status when 'passed' then '✔ checks passed' when 'warned' then '⚠️ warnings' when 'failed' then '❗ checks failed' else '… checking' end
$$;

-- Human-readable check problems for the card (red = required failed, yellow = advisory).
create or replace function check_problems(p_variant bigint, p_version int) returns text
language sql stable as $$
  select string_agg(case when c.required and c.status = 'fail' then '🔴 ' else '🟡 ' end ||
    case c.check_name
      when 'length' then 'Length: ' || coalesce(c.details ->> 'chars', c.details ->> 'words', c.details ->> 'posts') || ' (limit ' ||
                         coalesce(c.details ->> 'limit', (c.details ->> 'min') || '–' || (c.details ->> 'max'), c.details ->> 'max_posts') || ')'
      when 'forbidden_words' then 'Forbidden words: ' || (select string_agg(x, ', ') from jsonb_array_elements_text(c.details -> 'found') x)
      when 'required_elements' then 'Missing: ' || (select string_agg(x, ', ') from jsonb_array_elements_text(c.details -> 'missing') x)
      when 'facts' then 'Unsupported claims: ' || coalesce((select string_agg('«' || ellipsis(x ->> 'claim', 80) || '»', '; ') from jsonb_array_elements(c.details -> 'unsupported') x), c.details ->> 'summary', '?')
      when 'language' then 'Language ' || coalesce(c.details ->> 'detected', '?') || ', expected ' || (c.details ->> 'expected')
      when 'forbidden_topics' then 'Forbidden topics: ' || (select string_agg(x, ', ') from jsonb_array_elements_text(c.details -> 'found') x)
      when 'links' then 'Broken links: ' || (select string_agg(x ->> 'url', ', ') from jsonb_array_elements(c.details -> 'broken') x)
      when 'repeat_topic' then 'Similar post published ' || to_char((c.details ->> 'published_at')::timestamptz, 'DD Mon')
      else c.check_name end, E'\n' order by c.required desc, c.check_name)
  from check_results c
  where c.variant_id = p_variant and c.version = p_version and c.status <> 'pass'
$$;

create or replace function card_keyboard(p_package bigint, p_variant bigint, p_user bigint, p_menu text) returns jsonb
language plpgsql stable as $$
declare
  p packages;
  v variants;
  v_nav jsonb;
  v_n int;
  v_idx int;
  v_prev bigint;
  v_next bigint;
  v_pending int;
  v_url text;
  v_preview text;
begin
  select * into p from packages where id = p_package;
  select * into v from variants where id = p_variant;
  select count(*), max(case when id = v.id then rn end) into v_n, v_idx from (
    select id, row_number() over (order by id) rn from variants where package_id = p.id) s;
  select id into v_prev from variants where package_id = p.id and id < v.id order by id desc limit 1;
  select id into v_next from variants where package_id = p.id and id > v.id order by id limit 1;
  if v_prev is null then select id into v_prev from variants where package_id = p.id order by id desc limit 1; end if;
  if v_next is null then select id into v_next from variants where package_id = p.id order by id limit 1; end if;
  v_nav := case when v_n > 1 then jsonb_build_array(btn('◀', 'cv:' || p.id || ':' || v_prev),
                                                    btn(platform_label(v.platform) || ' ' || v_idx || '/' || v_n, 'cm:' || p.id),
                                                    btn('▶', 'cv:' || p.id || ':' || v_next)) end;
  v_preview := preview_url(v.id);

  if p.is_guest then
    return kb(v_nav, jsonb_build_array(btn('📄 Full text', 'ft:' || v.id)),
              case when url_button_ok(v_preview) then jsonb_build_array(btn_url('👁 Preview', v_preview)) end);
  end if;
  if p_menu = 'more' then
    return kb(v_nav,
      jsonb_build_array(btn('📄 Full text', 'ft:' || v.id), btn('📜 Source', 'src:' || p.id)),
      jsonb_build_array(btn('🔤 Headlines', 'hl:' || v.id), btn('🗂 History', 'hs:' || v.id)),
      case when p.cancelled_at is null and v.status not in ('published', 'publishing') then jsonb_build_array(btn('↪️ Other brand', 'ro:' || p.id)) end,
      case when url_button_ok(v_preview) then jsonb_build_array(btn_url('👁 Preview', v_preview)) end,
      jsonb_build_array(btn('« Back', 'cb:' || p.id)));
  end if;
  select count(*) into v_pending from variants where package_id = p.id and status = 'pending_approval';
  v_url := v.external_url;
  return case v.status
    when 'pending_approval' then kb(v_nav,
      btn_row(btn('✅ Approve', 'ap:' || v.id || ':' || v.current_version),
              case when v_pending > 1 then btn('✅ Approve all (' || v_pending || ')', 'aa:' || p.id) end),
      jsonb_build_array(btn('✏️ Edit', 'ed:' || v.id), btn('🔁 Redo…', 'rd:' || v.id), btn('❌ Reject', 'rj:' || v.id)),
      jsonb_build_array(btn('🖼 New visual', 'rv:' || p.id), btn('📤 My visual', 'uv:' || p.id), btn('🕘 Time', 'tm:' || v.id)),
      jsonb_build_array(btn('🚀 Publish now', 'pn:' || v.id), btn('➖ Remove', 'rm:' || v.id), btn('⋯ More', 'cm:' || p.id)))
    when 'revising' then kb(v_nav, jsonb_build_array(btn('⋯ More', 'cm:' || p.id)))
    when 'approved' then kb(v_nav, jsonb_build_array(btn('🕘 Time', 'tm:' || v.id), btn('🚀 Publish now', 'pn:' || v.id)),
                            jsonb_build_array(btn('✏️ Edit', 'ed:' || v.id), btn('➖ Cancel', 'rm:' || v.id), btn('⋯ More', 'cm:' || p.id)))
    when 'scheduled' then kb(v_nav, jsonb_build_array(btn('🕘 Time', 'tm:' || v.id), btn('🚀 Publish now', 'pn:' || v.id)),
                             jsonb_build_array(btn('✏️ Edit', 'ed:' || v.id), btn('➖ Cancel', 'rm:' || v.id), btn('⋯ More', 'cm:' || p.id)))
    when 'failed' then kb(v_nav, jsonb_build_array(btn('🔁 Retry', 'pr:' || v.id), btn('🕘 Next slot', 'ps:' || v.id), btn('✖ Cancel', 'pc:' || v.id)))
    when 'published' then kb(v_nav,
      case when url_button_ok(v_url) then jsonb_build_array(btn_url('🔗 Open', v_url)) end,
      case when publish_target(v.id) in ('telegram', 'blog') and v.external_deleted_at is null
           then jsonb_build_array(btn('✏️ Edit post', 'pe:' || v.id), btn('🗑 Delete post', 'pd:' || v.id)) end,
      jsonb_build_array(btn('⋯ More', 'cm:' || p.id)))
    else kb(v_nav, jsonb_build_array(btn('⋯ More', 'cm:' || p.id)))
  end;
end $$;

create or replace function render_card(p_package bigint, p_user bigint) returns jsonb
language plpgsql stable as $$
declare
  p packages;
  br brands;
  v variants;
  vv variant_versions;
  cv card_views;
  v_head text;
  v_meta text;
  v_problems text;
  v_extra text := '';
  v_body text;
  v_budget int;
  v_when text;
begin
  select * into p from packages where id = p_package;
  select * into br from brands where id = p.brand_id;
  select * into cv from card_views where package_id = p.id and user_id = p_user;
  select * into v from variants where id = cv.variant_id and package_id = p.id;
  if v.id is null then
    select * into v from variants where package_id = p.id order by (status in ('cancelled', 'rejected')), id limit 1;
  end if;
  select * into vv from variant_versions where variant_id = v.id and version = v.current_version;

  v_head := tpl('card.header', jsonb_build_object('brand', br.name, 'material', mcode(p.material_id), 'package', p.id));
  v_when := case
    when v.status = 'published' then 'published ' || fmt_local(v.published_at, br.timezone)
    when v.scheduled_at is not null and v.status in ('scheduled', 'rescheduled', 'publishing') then 'at ' || fmt_local(v.scheduled_at, br.timezone)
    when v.proposed_at is not null then 'proposed ' || fmt_local(v.proposed_at, br.timezone)
    else null end;
  v_meta := '<b>' || h(platform_label(v.platform)) || '</b>' ||
            case when publish_target(v.id) = 'preview' then ' (preview)' else '' end ||
            ' · ' || status_label(v.status) || ' · ' || check_label(v.check_status) ||
            coalesce(' · 🕘 ' || v_when, '');
  v_problems := check_problems(v.id, v.current_version);
  if p.low_data then
    v_extra := v_extra || E'\n' || tpl('card.low_data', '{}');
  end if;
  if jsonb_array_length(coalesce(vv.uncertain, '[]')) > 0 then
    v_extra := v_extra || E'\n🟡 ' || h(ellipsis('Check: ' || (select string_agg(x, '; ') from jsonb_array_elements_text(vv.uncertain) x), 200));
  end if;
  if v.approved_by is not null or v.auto_approved then
    v_extra := v_extra || E'\n✅ ' || case when v.auto_approved then 'auto-approved (checks passed)' else 'approved by ' || h(user_label(v.approved_by)) end;
  end if;
  if p.visual_status = 'failed' then
    v_extra := v_extra || E'\n🟡 ' || h(ellipsis('Visual: ' || coalesce(p.visual_note, 'failed'), 120));
  end if;
  if p.cancelled_at is not null then
    v_extra := v_extra || E'\n➖ Package cancelled (redirected to another brand)';
  end if;
  v_budget := 1000 - char_length(v_head) - char_length(v_meta) - char_length(coalesce(v_problems, '')) - char_length(v_extra) - 20;
  v_body := h(ellipsis(case when vv.variant_id is null then '…' else
                         coalesce(vv.content ->> 'title' || E'\n', '') || coalesce(vv.content ->> 'text', vv.content ->> 'lead', vv.plain_text) end,
                       greatest(v_budget, 120)));
  return jsonb_build_object(
    'text', v_head || E'\n' || v_meta || E'\n\n' || v_body ||
            case when v_problems is not null then E'\n\n' || h(v_problems) else '' end || v_extra,
    'keyboard', card_keyboard(p.id, v.id, p_user, coalesce(cv.menu, 'main')),
    'photo_asset_id', variant_visual(v.id));
end $$;

-- Who sees the card: brand editors and managers (guest packages: only the guest).
create or replace function card_audience(p_package bigint) returns setof users
language sql stable as $$
  select u.* from packages p
  join materials m on m.id = p.material_id
  join users u on (p.is_guest and u.id = m.author_user_id)
               or (not p.is_guest and u.id in (select user_id from memberships where brand_id = p.brand_id and role in ('manager', 'editor')))
  where p.id = p_package and u.status = 'active' and u.tg_chat_id is not null
$$;

create or replace function card_render_all(p_package bigint) returns int
language plpgsql as $$
declare
  u users;
  c jsonb;
  n int := 0;
  p packages;
begin
  select * into p from packages where id = p_package;
  for u in select * from card_audience(p_package) loop
    insert into card_views (package_id, user_id, variant_id)
    values (p.id, u.id, (select id from variants where package_id = p.id order by id limit 1))
    on conflict do nothing;
    c := render_card(p.id, u.id);
    perform tg_slot('card:' || p.id || ':' || u.id, u.tg_chat_id, c ->> 'text', c -> 'keyboard',
                    (c ->> 'photo_asset_id')::bigint, u.id, p.material_id, 3);
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function card_render_one(p_package bigint, p_user bigint) returns void
language plpgsql as $$
declare
  c jsonb;
  u users;
  p packages;
begin
  select * into u from users where id = p_user;
  select * into p from packages where id = p_package;
  c := render_card(p_package, p_user);
  perform tg_slot('card:' || p_package || ':' || p_user, u.tg_chat_id, c ->> 'text', c -> 'keyboard',
                  (c ->> 'photo_asset_id')::bigint, u.id, p.material_id, 10);
end $$;

-- package.card job: propose slots, send cards (AP-1), tell nobody else (the author sees progress on the ack).
create or replace function package_card(p_package bigint) returns jsonb
language plpgsql as $$
declare
  p packages;
  v record;
  n int;
begin
  select * into p from packages where id = p_package for update;
  if p.cancelled_at is not null or p.card_sent_at is not null then
    return job_flags();
  end if;
  for v in select id from variants where package_id = p.id and status = 'pending_approval' loop
    perform propose_slot(v.id);
  end loop;
  n := card_render_all(p.id);
  update packages set card_sent_at = now() where id = p.id;
  perform audit(null, 'package.card_sent', 'package', p.id, p.brand_id, p.material_id, jsonb_build_object('recipients', n));
  if n = 0 and not p.is_guest then
    perform notify_admins(tpl('admin.no_editors', jsonb_build_object('brand', (select name from brands where id = p.brand_id), 'material', mcode(p.material_id))));
  end if;
  return job_flags();
end $$;

create or replace function card_refresh(p_package bigint) returns jsonb
language plpgsql as $$
begin
  perform card_render_all(p_package);
  return job_flags();
end $$;
