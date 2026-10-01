-- Email digest (DG-1..DG-7): plan -> build 2 h before -> approval + test send -> send (idempotent chunks) -> metrics.

create or replace function email_platform(p_brand bigint) returns brand_platforms
language sql stable as $$
  select * from brand_platforms where brand_id = p_brand and platform = 'email' and is_active and mode = 'real' order by id limit 1
$$;

-- Plan the next issue (idempotent by unique (platform, send_at)). p_build_now: build immediately (/digest <brand> now).
create or replace function digest_plan(p_brand bigint, p_build_now boolean default false) returns jsonb
language plpgsql as $$
declare
  bp brand_platforms;
  br brands;
  v_send timestamptz;
  v_prev timestamptz;
  v_issue bigint;
  v_build_h int := coalesce(setting_num('digest.build_hours_before'), 2)::int;
begin
  select * into br from brands where id = p_brand;
  bp := email_platform(p_brand);
  if bp.id is null or br.status <> 'active' or br.is_temporary then
    return job_flags();
  end if;
  select id, send_at into v_issue, v_send from digest_issues
  where brand_platform_id = bp.id and send_at > now() and status in ('draft', 'pending_approval', 'approved', 'scheduled')
  order by send_at limit 1;
  if v_issue is null then
    -- after the latest issue of any status: a skipped or cancelled slot is not planned again
    v_send := digest_next_send(bp.id, greatest(now() + make_interval(hours => case when p_build_now then 0 else v_build_h end) + interval '5 minutes',
                                               (select max(send_at) from digest_issues where brand_platform_id = bp.id)));
    if v_send is null then
      return job_flags();
    end if;
    select max(period_end) into v_prev from digest_issues where brand_platform_id = bp.id and status not in ('cancelled');
    insert into digest_issues (brand_id, brand_platform_id, period_start, period_end, send_at, auto_send)
    values (p_brand, bp.id, coalesce(v_prev, v_send - case when bp.schedule ->> 'frequency' = 'daily' then interval '1 day' else interval '7 days' end),
            v_send, v_send, coalesce((bp.schedule ->> 'auto_send')::boolean, false))
    on conflict (brand_platform_id, send_at) do nothing
    returning id into v_issue;
    if v_issue is null then
      return job_flags();
    end if;
    perform audit(null, 'digest.planned', 'digest_issue', v_issue, p_brand, null, jsonb_build_object('send_at', v_send));
  end if;
  perform enqueue_job('digest.build', jsonb_build_object('issue_id', v_issue), null, null, null, p_brand,
                      p_dedupe => 'digest_build:' || v_issue || case when p_build_now then ':now:' || extract(epoch from now())::bigint else '' end,
                      p_run_after => case when p_build_now then now() else v_send - make_interval(hours => v_build_h) end);
  perform enqueue_job('digest.deadline', jsonb_build_object('issue_id', v_issue), null, null, null, p_brand,
                      p_dedupe => 'digest_deadline:' || v_issue, p_run_after => v_send);
  return job_flags();
end $$;

-- Build input: approved email blocks due for this issue + relevant unused feed items (DG-2).
create or replace function digest_build_context(p_issue bigint) returns jsonb
language plpgsql stable as $$
declare
  di digest_issues;
  br brands;
  prof jsonb;
  v_max int := coalesce(setting_num('digest.max_blocks'), 7)::int;
begin
  select * into di from digest_issues where id = p_issue;
  select * into br from brands where id = di.brand_id;
  prof := active_profile(br.id);
  return jsonb_build_object(
    'skip', di.status <> 'draft',
    'issue_id', di.id, 'brand_id', br.id,
    'variants', (select coalesce(jsonb_agg(jsonb_build_object('variant_id', v.id, 'title', vv.content ->> 'title', 'body', vv.content ->> 'body',
                   'link_label', vv.content ->> 'link_label', 'link_url', digest_link(v.id), 'image_asset_id', variant_visual(v.id)) order by v.scheduled_at), '[]')
                 from (select v.* from variants v
                       where v.brand_platform_id = di.brand_platform_id and v.status in ('scheduled', 'approved')
                         and (v.digest_issue_id is null or v.digest_issue_id = di.id)
                         and coalesce(v.scheduled_at, now()) <= di.send_at
                       order by v.scheduled_at limit v_max) v
                 join variant_versions vv on vv.variant_id = v.id and vv.version = v.current_version),
    'feed_items', (select coalesce(jsonb_agg(jsonb_build_object('feed_item_id', fi.id, 'title', fi.title, 'link', fi.link, 'summary', left(fi.summary, 3000))
                                                order by fi.relevance desc), '[]')
                   from (select fi.* from feed_items fi join feed_sources fs on fs.id = fi.source_id
                         where fs.brand_id = br.id and fs.is_active and fi.used_in_issue_id is null
                           and coalesce(fi.relevance, 0) >= coalesce(setting_num('digest.feed_relevance'), 0.35)
                           and coalesce(fi.published_at, fi.created_at) > di.period_start - interval '7 days'
                         order by fi.relevance desc limit coalesce(setting_num('digest.max_feed_blocks'), 2)::int) fi),
    'vars', jsonb_build_object('brand_name', br.name, 'digest', prof -> 'digest', 'voice', prof -> 'voice',
                               'language', (select language from brand_platforms where id = di.brand_platform_id),
                               'period', to_char(di.period_start at time zone br.timezone, 'DD Mon') || ' – ' || to_char(di.period_end at time zone br.timezone, 'DD Mon YYYY')),
    'template', (select body from templates where key = 'email.digest'),
    'preview_token', di.preview_token,
    'palette', coalesce(prof #> '{visual,palette}', '[]'),
    'web_url', public_web_url(),
    'blog_url', blog_base_url(br.id),
    'account_type', 'brand'
  );
end $$;

-- Link of an email block: the blog post of the same package if published, else the first source link.
create or replace function digest_link(p_variant bigint) returns text
language sql stable as $$
  select coalesce(
    (select b.external_url from variants v join variants b on b.package_id = v.package_id and b.platform = 'blog' and b.status = 'published' where v.id = p_variant limit 1),
    (select e.summary -> 'links' ->> 0 from variants v join packages p on p.id = v.package_id join material_extracts e on e.material_id = p.material_id where v.id = p_variant),
    (select blog_base_url(p.brand_id) from variants v join packages p on p.id = v.package_id where v.id = p_variant))
$$;

-- Composed issue: items + subject/intro; fewer than 2 blocks -> skipped (DG-7); else card to editors (DG-4).
create or replace function digest_save(p_issue bigint, p_compose jsonb, p_items jsonb, p_html text) returns jsonb
language plpgsql as $$
declare
  di digest_issues;
  br brands;
  it jsonb;
  i int := 0;
begin
  select * into di from digest_issues where id = p_issue for update;
  select * into br from brands where id = di.brand_id;
  if di.status <> 'draft' then
    return job_flags();
  end if;
  delete from digest_items where issue_id = di.id;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]')) loop
    i := i + 1;
    insert into digest_items (issue_id, ord, kind, variant_id, feed_item_id, title, body, link_label, link_url, image_asset_id)
    values (di.id, i, case when it ? 'feed_item_id' then 'feed' else 'variant' end, (it ->> 'variant_id')::bigint, (it ->> 'feed_item_id')::bigint,
            coalesce(it ->> 'title', ''), coalesce(it ->> 'body', ''), it ->> 'link_label', it ->> 'link_url', (it ->> 'image_asset_id')::bigint);
    if it ? 'variant_id' then
      update variants set digest_issue_id = di.id where id = (it ->> 'variant_id')::bigint;
    end if;
    if it ? 'feed_item_id' then
      update feed_items set used_in_issue_id = di.id where id = (it ->> 'feed_item_id')::bigint;
    end if;
  end loop;
  if i < coalesce(setting_num('digest.min_blocks'), 2) then
    update variants set digest_issue_id = null where digest_issue_id = di.id;
    update feed_items set used_in_issue_id = null where used_in_issue_id = di.id;
    perform transition('digest_issue', di.id, 'skipped', null, 'fewer than min blocks');
    perform notify_brand(br.id, array['manager', 'editor'], tpl('digest.skipped', jsonb_build_object('brand', br.name, 'blocks', i,
                         'date', fmt_local(di.send_at, br.timezone))), null, 'digest_skipped:' || di.id);
    perform digest_plan(br.id);
    return job_flags();
  end if;
  update digest_issues set subject = p_compose ->> 'subject', preheader = p_compose ->> 'preheader', intro = p_compose ->> 'intro',
                           cta = p_compose -> 'cta', html = p_html
   where id = di.id;
  perform transition('digest_issue', di.id, 'pending_approval', null);
  perform digest_card(di.id);
  return job_flags();
end $$;

create or replace function digest_card(p_issue bigint) returns void
language plpgsql as $$
declare
  di digest_issues;
  br brands;
  u record;
  v_text text;
  v_preview text;
begin
  select * into di from digest_issues where id = p_issue;
  select * into br from brands where id = di.brand_id;
  v_preview := public_web_url() || '/d/' || di.preview_token;
  v_text := tpl('digest.card', jsonb_build_object('brand', br.name, 'subject', coalesce(di.subject, '—'), 'preheader', coalesce(di.preheader, ''),
              'send_at', fmt_local(di.send_at, br.timezone), 'status', status_label(di.status),
              'blocks', (select string_agg(ord || '. ' || title, E'\n' order by ord) from digest_items where issue_id = di.id),
              'subscribers', (select count(*) from subscribers where brand_id = br.id and status = 'confirmed'),
              'approved', coalesce('✅ approved by ' || user_label(di.approved_by), '')));
  for u in select us.id, us.tg_chat_id from memberships m join users us on us.id = m.user_id
           where m.brand_id = br.id and m.role in ('manager', 'editor') and us.status = 'active' and us.tg_chat_id is not null loop
    perform tg_slot('digest:' || di.id || ':' || u.id, u.tg_chat_id, v_text,
      kb(case when di.status = 'pending_approval' then jsonb_build_array(btn('✅ Approve', 'da:' || di.id), btn('⏭ Skip issue', 'dx:' || di.id)) end,
         jsonb_build_array(btn('📧 Test send to me', 'dt:' || di.id)),
         case when url_button_ok(v_preview) then jsonb_build_array(btn_url('👁 Preview', v_preview)) end),
      null, u.id, null, 3);
  end loop;
end $$;

create or replace function digest_approve(p_issue bigint, p_user bigint) returns text
language plpgsql as $$
declare
  di digest_issues;
begin
  select * into di from digest_issues where id = p_issue for update;
  perform require_can(p_user, di.brand_id, 'approve');
  if di.status <> 'pending_approval' then
    raise exception '%', tpl('err.not_pending', '{}');
  end if;
  perform transition('digest_issue', di.id, 'approved', p_user);
  update digest_issues set approved_by = p_user, approved_at = now() where id = di.id;
  perform transition('digest_issue', di.id, 'scheduled', p_user);
  perform digest_card(di.id);
  return 'Approved';
end $$;

create or replace function digest_skip(p_issue bigint, p_user bigint) returns text
language plpgsql as $$
declare
  di digest_issues;
begin
  select * into di from digest_issues where id = p_issue for update;
  perform require_can(p_user, di.brand_id, 'approve');
  if di.status not in ('draft', 'pending_approval') then
    raise exception '%', tpl('err.not_pending', '{}');
  end if;
  update variants set digest_issue_id = null where digest_issue_id = di.id;
  update feed_items set used_in_issue_id = null where used_in_issue_id = di.id;
  perform transition('digest_issue', di.id, 'skipped', p_user);
  perform digest_card(di.id);
  perform digest_plan(di.brand_id);
  return 'Skipped';
end $$;

create or replace function digest_test(p_issue bigint, p_user bigint) returns text
language plpgsql as $$
declare
  di digest_issues;
  v_email text;
begin
  select * into di from digest_issues where id = p_issue;
  perform require_can(p_user, di.brand_id, 'approve');
  select email into v_email from users where id = p_user;
  if v_email is null then
    raise exception '%', tpl('digest.need_email', '{}');
  end if;
  perform enqueue_job('digest.test', jsonb_build_object('issue_id', di.id, 'email', v_email), null, null, null, di.brand_id,
                      p_dedupe => 'digest_test:' || di.id || ':' || p_user || ':' || extract(epoch from date_trunc('minute', now()))::bigint);
  return 'Test email to ' || v_email;
end $$;

-- DG-4 at send time: approved -> send; not approved -> auto-send if enabled, else not sent (editors told).
create or replace function digest_deadline(p_issue bigint) returns jsonb
language plpgsql as $$
declare
  di digest_issues;
  br brands;
begin
  select * into di from digest_issues where id = p_issue for update;
  select * into br from brands where id = di.brand_id;
  if di.status = 'pending_approval' and di.auto_send then
    perform transition('digest_issue', di.id, 'approved', null, 'auto-send');
    update digest_issues set approved_at = now() where id = di.id;
    perform transition('digest_issue', di.id, 'scheduled', null);
    select * into di from digest_issues where id = p_issue;
  end if;
  if di.status = 'scheduled' then
    perform enqueue_job('digest.send', jsonb_build_object('issue_id', di.id), null, null, null, di.brand_id, p_dedupe => 'digest_send:' || di.id);
  elsif di.status in ('draft', 'pending_approval') then
    update variants set digest_issue_id = null where digest_issue_id = di.id;
    update feed_items set used_in_issue_id = null where used_in_issue_id = di.id;
    perform transition('digest_issue', di.id, 'skipped', null, 'not approved in time');
    perform notify_brand(br.id, array['manager', 'editor'], tpl('digest.not_approved', jsonb_build_object('brand', br.name)), null, 'digest_na:' || di.id);
  end if;
  perform digest_plan(br.id);
  return job_flags();
end $$;

create or replace function unsubscribe_url(p_brand bigint, p_token text) returns text
language sql stable as $$ select blog_base_url(p_brand) || '/unsubscribe/' || p_token $$;

-- Assign chunks once (deterministic -> the same Idempotency-Key on retries), return the next unsent chunk.
create or replace function digest_next_chunk(p_issue bigint, p_test_email text default null) returns jsonb
language plpgsql as $$
declare
  di digest_issues;
  br brands;
  bp brand_platforms;
  v_chunk int;
  v_from text;
begin
  select * into di from digest_issues where id = p_issue for update;
  select * into br from brands where id = di.brand_id;
  select * into bp from brand_platforms where id = di.brand_platform_id;
  v_from := coalesce(bp.target ->> 'from_name', br.name) || ' <' ||
            coalesce(substring(setting_text('email.from') from '<([^>]+)>'), setting_text('email.from')) || '>';
  if p_test_email is not null then
    return jsonb_build_object('done', false, 'test', true, 'issue_id', di.id, 'chunk', -1,
      'idempotency_key', 'digest-test-' || di.id || '-' || md5(p_test_email || now()::text),
      'emails', jsonb_build_array(jsonb_build_object('from', v_from, 'to', p_test_email, 'subject', '[TEST] ' || coalesce(di.subject, br.name),
        'html', replace(di.html, '{{unsubscribe_url}}', '#'), 'reply_to', bp.target ->> 'reply_to')),
      'resend_base', setting_text('api.resend_base'));
  end if;
  if di.status = 'scheduled' then
    perform transition('digest_issue', di.id, 'publishing', null);
    insert into digest_deliveries (issue_id, subscriber_id, chunk)
    select di.id, s.id, ((row_number() over (order by s.id)) - 1) / 100
    from subscribers s where s.brand_id = br.id and s.status = 'confirmed'
    on conflict do nothing;
  elsif di.status <> 'publishing' then
    return jsonb_build_object('done', true, 'skip', true);
  end if;
  select min(chunk) into v_chunk from digest_deliveries where issue_id = di.id and status = 'queued';
  if v_chunk is null then
    return digest_finish(di.id);
  end if;
  return jsonb_build_object('done', false, 'issue_id', di.id, 'chunk', v_chunk,
    'idempotency_key', 'digest-' || di.id || '-chunk-' || v_chunk,
    'resend_base', setting_text('api.resend_base'),
    'emails', (select jsonb_agg(jsonb_build_object(
        'from', v_from, 'to', s.email, 'subject', coalesce(di.subject, br.name),
        'html', replace(di.html, '{{unsubscribe_url}}', unsubscribe_url(br.id, s.token)),
        'reply_to', bp.target ->> 'reply_to',
        'headers', jsonb_build_object('List-Unsubscribe', '<' || unsubscribe_url(br.id, s.token) || '>',
                                      'List-Unsubscribe-Post', 'List-Unsubscribe=One-Click'),
        'tags', jsonb_build_array(jsonb_build_object('name', 'issue', 'value', di.id::text))) order by s.id)
      from digest_deliveries d join subscribers s on s.id = d.subscriber_id
      where d.issue_id = di.id and d.chunk = v_chunk and d.status = 'queued'));
end $$;

-- Resend batch response: ids in request order.
create or replace function digest_chunk_result(p_issue bigint, p_chunk int, p_response jsonb, p_error text default null) returns jsonb
language plpgsql as $$
declare
  r record;
begin
  if p_error is not null then
    raise exception 'provider_unavailable: digest chunk % failed: %', p_chunk, left(p_error, 300);
  end if;
  for r in
    select d.subscriber_id, (p_response -> 'data' -> ((row_number() over (order by d.subscriber_id)) - 1)::int ->> 'id') as esp_id
    from digest_deliveries d where d.issue_id = p_issue and d.chunk = p_chunk and d.status = 'queued'
  loop
    update digest_deliveries set status = 'sent', esp_message_id = r.esp_id, sent_at = now(), updated_at = now()
     where issue_id = p_issue and subscriber_id = r.subscriber_id;
  end loop;
  return digest_next_chunk(p_issue);
end $$;

create or replace function digest_finish(p_issue bigint) returns jsonb
language plpgsql as $$
declare
  di digest_issues;
  br brands;
  v record;
  n int;
begin
  select * into di from digest_issues where id = p_issue for update;
  select * into br from brands where id = di.brand_id;
  if di.status = 'publishing' then
    select count(*) into n from digest_deliveries where issue_id = di.id and status <> 'queued';
    update digest_issues set stats = stats || jsonb_build_object('sent', n) where id = di.id;
    perform transition('digest_issue', di.id, 'published', null, null, jsonb_build_object('sent', n));
    for v in select id from variants where digest_issue_id = di.id and status = 'scheduled' loop
      perform transition('variant', v.id, 'publishing', null, 'digest');
      update variants set published_at = now(), external_url = public_web_url() || '/d/' || di.preview_token where id = v.id;
      perform transition('variant', v.id, 'published', null, 'digest', jsonb_build_object('issue', di.id));
    end loop;
    perform notify_brand(br.id, array['manager', 'editor'], tpl('digest.sent', jsonb_build_object('brand', br.name, 'count', n)), null, 'digest_sent:' || di.id);
  end if;
  return jsonb_build_object('done', true);
end $$;

-- DG-6: verified delivery status (fetched from Resend by id) -> deliveries and issue counters.
create or replace function esp_event_apply(p_email_id text, p_last_event text) returns jsonb
language plpgsql as $$
declare
  d digest_deliveries;
  v_status text := case p_last_event when 'delivered' then 'delivered' when 'opened' then 'opened' when 'clicked' then 'clicked'
                                     when 'bounced' then 'bounced' when 'complained' then 'complained' when 'failed' then 'failed' else null end;
begin
  select * into d from digest_deliveries where esp_message_id = p_email_id for update;
  if d.issue_id is null or v_status is null then
    return job_flags();
  end if;
  -- keep the "best" engagement status
  if array_position(array['sent', 'delivered', 'opened', 'clicked'], v_status) > coalesce(array_position(array['sent', 'delivered', 'opened', 'clicked'], d.status), 0)
     or v_status in ('bounced', 'complained', 'failed') then
    update digest_deliveries set status = v_status, updated_at = now() where issue_id = d.issue_id and subscriber_id = d.subscriber_id;
  end if;
  if v_status in ('bounced', 'complained') then
    update subscribers set status = v_status where id = d.subscriber_id and status = 'confirmed';
  end if;
  update digest_issues set stats = stats || (select jsonb_build_object(
      'delivered', count(*) filter (where status in ('delivered', 'opened', 'clicked')),
      'opened', count(*) filter (where status in ('opened', 'clicked')),
      'clicked', count(*) filter (where status = 'clicked'),
      'bounced', count(*) filter (where status = 'bounced'),
      'complained', count(*) filter (where status = 'complained'))
    from digest_deliveries where issue_id = d.issue_id)
  where id = d.issue_id;
  return job_flags();
end $$;

-- esp.event job end: apply the verified status and close the inbound event.
create or replace function esp_event_done(p_event bigint, p_email_id text, p_last_event text) returns jsonb
language plpgsql as $$
begin
  perform esp_event_apply(p_email_id, p_last_event);
  update inbound_events set status = 'processed', processed_at = now() where id = p_event and status = 'new';
  return job_flags();
end $$;

create or replace function digest_status_text(p_brand bigint) returns text
language plpgsql stable as $$
declare
  di digest_issues;
  br brands;
begin
  select * into br from brands where id = p_brand;
  select * into di from digest_issues where brand_id = p_brand order by send_at desc limit 1;
  if di.id is null then
    return tpl('digest.none', jsonb_build_object('brand', br.name));
  end if;
  return tpl('digest.status', jsonb_build_object('brand', br.name, 'send_at', fmt_local(di.send_at, br.timezone), 'status', status_label(di.status),
             'subscribers', (select count(*) from subscribers where brand_id = p_brand and status = 'confirmed'),
             'stats', di.stats::text));
end $$;

-- Feeds (DG-2): upsert fetched items; relevance = cosine similarity of the item to the brand description embedding.
create or replace function feeds_context(p_brand bigint) returns jsonb
language sql stable as $$
  select jsonb_build_object('brand_id', p_brand,
    'sources', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'url', url)), '[]') from feed_sources where brand_id = p_brand and is_active),
    'brand_text', (select concat_ws('. ', profile #>> '{basics,description}', profile #>> '{basics,niche}',
                    (select string_agg(x, ', ') from jsonb_array_elements_text(coalesce(profile #> '{basics,topics}', '[]')) x))
                   from brand_profile_versions where brand_id = p_brand and status = 'active'),
    'account_type', 'brand')
$$;

create or replace function feed_items_save(p_source bigint, p_items jsonb, p_error text default null) returns int
language plpgsql as $$
declare
  n int := 0;
  it jsonb;
begin
  update feed_sources set last_fetched_at = now(), last_error = p_error where id = p_source;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]')) loop
    insert into feed_items (source_id, guid, title, link, summary, published_at, embedding, relevance)
    values (p_source, coalesce(it ->> 'guid', it ->> 'link', md5(it ->> 'title')), left(coalesce(it ->> 'title', ''), 500), it ->> 'link',
            left(it ->> 'summary', 5000), (it ->> 'published_at')::timestamptz,
            nullif(it ->> 'embedding', '')::vector, (it ->> 'relevance')::numeric)
    on conflict (source_id, guid) do nothing;
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- Subscribers (DG-5), called by the web service through the n8n command webhook.
create or replace function sub_subscribe(p_brand_slug text, p_email text) returns jsonb
language plpgsql as $$
declare
  br brands;
  s subscribers;
begin
  select * into br from brands where slug = lower(p_brand_slug) and status = 'active' and not is_temporary;
  if br.id is null or (email_platform(br.id)).id is null then
    return jsonb_build_object('ok', false, 'error', 'unknown newsletter');
  end if;
  if coalesce(p_email, '') !~ '^[^@\s]{1,64}@[^@\s]{1,255}\.[a-zA-Z]{2,}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid email');
  end if;
  insert into subscribers (brand_id, email) values (br.id, lower(trim(p_email)))
  on conflict (brand_id, lower(email)) do update set status = case when subscribers.status = 'confirmed' then 'confirmed' else 'pending' end
  returning * into s;
  if s.status = 'pending' then
    perform email_send(s.email, tpl('email.confirm_subject', jsonb_build_object('brand', br.name)),
                       tpl('email.confirm_html', jsonb_build_object('brand', br.name, 'url', blog_base_url(br.id) || '/confirm/' || s.token)),
                       null, 'confirm:' || s.id || ':' || to_char(now(), 'YYYYMMDDHH24'), jsonb_build_object('brand_id', br.id));
  end if;
  return jsonb_build_object('ok', true, 'status', s.status);
end $$;

create or replace function sub_action(p_action text, p_token text) returns jsonb
language plpgsql as $$
declare
  s subscribers;
begin
  select * into s from subscribers where token = p_token for update;
  if s.id is null then
    return jsonb_build_object('ok', false, 'error', 'not found');
  end if;
  case p_action
    when 'confirm' then
      update subscribers set status = 'confirmed', confirmed_at = now() where id = s.id and status in ('pending', 'unsubscribed');
    when 'unsubscribe' then
      update subscribers set status = 'unsubscribed', unsubscribed_at = now() where id = s.id and status <> 'unsubscribed';
      update digest_issues di set stats = jsonb_set(stats, '{unsubscribed}', to_jsonb(coalesce((stats ->> 'unsubscribed')::int, 0) + 1))
       where di.id = (select issue_id from digest_deliveries where subscriber_id = s.id order by sent_at desc nulls last limit 1);
    when 'resubscribe' then
      update subscribers set status = 'confirmed', unsubscribed_at = null where id = s.id and status = 'unsubscribed';
    when 'delete' then
      delete from subscribers where id = s.id;
      perform audit(null, 'subscriber.deleted', 'subscriber', s.id, s.brand_id, null, '{}');
      return jsonb_build_object('ok', true, 'status', 'deleted');
    else
      return jsonb_build_object('ok', false, 'error', 'unknown action');
  end case;
  return jsonb_build_object('ok', true, 'status', (select status from subscribers where id = s.id),
                            'brand', (select name from brands where id = s.brand_id));
end $$;

-- Single entry for web commands (architecture 3: the web never writes business state itself).
create or replace function web_command(p_action text, p_body jsonb) returns jsonb
language plpgsql as $$
begin
  case p_action
    when 'subscribe' then return sub_subscribe(p_body ->> 'brand', p_body ->> 'email');
    when 'confirm', 'unsubscribe', 'resubscribe', 'delete' then return sub_action(p_action, p_body ->> 'token');
    else return jsonb_build_object('ok', false, 'error', 'unknown command');
  end case;
end $$;
