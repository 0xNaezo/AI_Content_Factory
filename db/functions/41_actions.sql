-- Editor actions on variants and packages (AP-2..AP-4, RT-5, PB-7). Called from bot callbacks and dialog input.
-- Every action re-checks permissions; messages to users are rendered from templates.

create or replace function variant_brand(p_variant bigint) returns bigint
language sql stable as $$ select p.brand_id from variants v join packages p on p.id = v.package_id where v.id = p_variant $$;

create or replace function require_can(p_user bigint, p_brand bigint, p_action text) returns void
language plpgsql stable as $$
begin
  if not can(p_user, p_brand, p_action) then
    raise exception '%', tpl('err.forbidden', '{}');
  end if;
end $$;

-- Parse edited text back into the platform structure.
create or replace function content_from_text(p_kind text, p_text text, p_old jsonb) returns jsonb
language plpgsql immutable as $$
declare
  v_lines text[];
  v_sections jsonb := '[]';
  v_title text;
  v_lead text;
  v_chunk text;
  v_heading text;
begin
  if p_kind = 'thread' then
    return jsonb_build_object('posts', (select coalesce(jsonb_agg(trim(x)), '[]') from regexp_split_to_table(p_text, '\n\s*---\s*\n') x where trim(x) <> ''));
  elsif p_kind = 'email_block' then
    v_lines := regexp_split_to_array(trim(p_text), '\n');
    return jsonb_build_object('title', regexp_replace(v_lines[1], '^#+\s*', ''), 'body', trim(array_to_string(v_lines[2:], E'\n')),
                              'link_label', p_old ->> 'link_label');
  elsif p_kind = 'article' then
    v_title := coalesce(substring(p_text from '^\s*#\s+([^\n]+)'), p_old ->> 'title');
    p_text := regexp_replace(p_text, '^\s*#\s+[^\n]+\n?', '');
    v_lead := trim(split_part(regexp_replace(p_text, '\n##\s.*$', '', 's'), E'\n\n', 1));
    for v_chunk in select x from regexp_split_to_table(p_text, '\n(?=##\s)') x loop
      if v_chunk ~ '^\s*##\s' then
        v_heading := substring(v_chunk from '^\s*##\s+([^\n]+)');
        v_sections := v_sections || jsonb_build_object('heading', v_heading, 'body_md', trim(regexp_replace(v_chunk, '^\s*##\s+[^\n]+\n?', '')));
      end if;
    end loop;
    return jsonb_build_object('title', v_title, 'slug', coalesce(p_old ->> 'slug', slugify(v_title)), 'lead', v_lead,
                              'sections', case when jsonb_array_length(v_sections) = 0 then coalesce(p_old -> 'sections', '[]') else v_sections end,
                              'seo_description', p_old ->> 'seo_description');
  end if;
  return jsonb_build_object('text', trim(p_text));
end $$;

-- Text shown to the editor for editing (inverse of content_from_text).
create or replace function content_to_text(p_kind text, p_content jsonb) returns text
language sql immutable as $$
  select case p_kind
    when 'thread' then (select string_agg(x, E'\n---\n' ) from jsonb_array_elements_text(coalesce(p_content -> 'posts', '[]')) x)
    when 'email_block' then concat_ws(E'\n', p_content ->> 'title', p_content ->> 'body')
    when 'article' then concat_ws(E'\n\n', '# ' || (p_content ->> 'title'), p_content ->> 'lead',
                                  (select string_agg('## ' || (s ->> 'heading') || E'\n' || (s ->> 'body_md'), E'\n\n') from jsonb_array_elements(coalesce(p_content -> 'sections', '[]')) s))
    else p_content ->> 'text' end
$$;

create or replace function variant_kind(p_variant bigint) returns text
language sql stable as $$ select platform_format(variant_brand(v.id), v.platform) ->> 'kind' from variants v where v.id = p_variant $$;

-- AP-2 "edit manually" / PB-7 "edit after publishing": new human version, checks re-run, feedback saved (AP-4).
create or replace function human_edit(p_variant bigint, p_text text, p_actor bigint, p_reason text default 'edit') returns jsonb
language plpgsql as $$
declare
  v variants;
  p packages;
  cur variant_versions;
  v_content jsonb;
begin
  select * into v from variants where id = p_variant for update;
  select * into p from packages where id = v.package_id;
  perform require_can(p_actor, p.brand_id, 'approve');
  if v.status not in ('pending_approval', 'approved', 'scheduled', 'rescheduled', 'failed')
     and not (p_reason = 'edit_published' and v.status = 'published') then
    raise exception '%', tpl('err.not_editable', jsonb_build_object('status', status_label(v.status)));
  end if;
  select * into cur from variant_versions where variant_id = v.id and version = v.current_version;
  v_content := content_from_text(variant_kind(v.id), p_text, cur.content);
  insert into variant_versions (variant_id, version, content, plain_text, headline_options, image_brief, visual_asset_id,
                                used_facts, uncertain, author_kind, author_user_id, reason)
  values (v.id, v.current_version + 1, v_content, variant_plain_text(v_content), cur.headline_options, cur.image_brief,
          cur.visual_asset_id, cur.used_facts, '[]', 'human', p_actor, p_reason);
  update variants set current_version = current_version + 1, check_status = 'pending' where id = v.id;
  insert into feedback_examples (brand_id, platform, kind, source, variant_id, before_text, after_text, created_by)
  values (p.brand_id, v.platform, 'example', 'edit', v.id, cur.plain_text, variant_plain_text(v_content), p_actor);
  perform audit(p_actor, 'variant.edited', 'variant', v.id, p.brand_id, p.material_id, jsonb_build_object('version', v.current_version + 1, 'reason', p_reason));
  perform enqueue_job('variant.check', '{}', p.material_id, p.id, v.id, p.brand_id, p_dedupe => 'check:' || v.id || ':' || (v.current_version + 1));
  if p_reason = 'edit_published' then
    perform enqueue_job('post.op', jsonb_build_object('op', 'edit'), p.material_id, p.id, v.id, p.brand_id,
                        p_dedupe => 'postop:edit:' || v.id || ':' || (v.current_version + 1));
  end if;
  perform package_try_card(p.id);
  return job_flags();
end $$;

-- AP-2 "redo with comment": revising -> new AI version with the comment; the comment feeds the brand (AP-4).
create or replace function redo_variant(p_variant bigint, p_comment text, p_actor bigint) returns jsonb
language plpgsql as $$
declare
  v variants;
  p packages;
begin
  select * into v from variants where id = p_variant for update;
  select * into p from packages where id = v.package_id;
  perform require_can(p_actor, p.brand_id, 'approve');
  if v.status <> 'pending_approval' then
    raise exception '%', tpl('err.not_pending', '{}');
  end if;
  perform transition('variant', v.id, 'revising', p_actor, p_comment);
  insert into feedback_examples (brand_id, platform, kind, source, variant_id, before_text, comment, created_by)
  values (p.brand_id, v.platform, 'guidance', 'redo', v.id,
          (select plain_text from variant_versions where variant_id = v.id and version = v.current_version), p_comment, p_actor);
  perform enqueue_job('variant.generate', jsonb_build_object('mode', 'redo', 'comment', p_comment), p.material_id, p.id, v.id, p.brand_id,
                      p_dedupe => 'redo:' || v.id || ':' || v.current_version, p_priority => 5);
  perform package_try_card(p.id);
  return job_flags();
end $$;

create or replace function reject_variant(p_variant bigint, p_reason text, p_comment text, p_actor bigint) returns jsonb
language plpgsql as $$
declare
  v variants;
  p packages;
begin
  select * into v from variants where id = p_variant for update;
  select * into p from packages where id = v.package_id;
  perform require_can(p_actor, p.brand_id, 'approve');
  if v.status <> 'pending_approval' then
    raise exception '%', tpl('err.not_pending', '{}');
  end if;
  perform transition('variant', v.id, 'rejected', p_actor, p_reason, jsonb_build_object('comment', p_comment));
  insert into feedback_examples (brand_id, platform, kind, source, variant_id, before_text, comment, created_by)
  values (p.brand_id, v.platform, 'antiexample', 'reject', v.id,
          (select plain_text from variant_versions where variant_id = v.id and version = v.current_version),
          p_reason || coalesce(': ' || nullif(p_comment, ''), ''), p_actor);
  perform package_try_card(p.id);
  return job_flags();
end $$;

create or replace function cancel_variant(p_variant bigint, p_actor bigint, p_reason text default 'removed by editor') returns jsonb
language plpgsql as $$
declare
  v variants;
  p packages;
begin
  select * into v from variants where id = p_variant for update;
  select * into p from packages where id = v.package_id;
  if p_actor is not null then
    perform require_can(p_actor, p.brand_id, 'approve');
  end if;
  if v.status in ('publishing', 'published', 'rejected', 'cancelled') then
    raise exception '%', tpl('err.not_cancellable', jsonb_build_object('status', status_label(v.status)));
  end if;
  perform transition('variant', v.id, 'cancelled', p_actor, p_reason);
  update jobs set status = 'cancelled', finished_at = now() where variant_id = v.id and status in ('queued', 'failed', 'blocked');
  perform package_try_card(p.id);
  return job_flags();
end $$;

-- Approve (AP-2, AP-7: one approval from any editor is enough) and put into a slot (PB-1).
create or replace function approve_and_schedule(p_variant bigint, p_actor bigint, p_version int default null, p_now boolean default false) returns jsonb
language plpgsql as $$
declare
  v variants;
  p packages;
  v_at timestamptz;
begin
  select * into v from variants where id = p_variant for update;
  select * into p from packages where id = v.package_id;
  perform require_can(p_actor, p.brand_id, 'approve');
  if p_version is not null and v.current_version <> p_version then
    perform card_render_all(p.id);
    raise exception '%', tpl('err.card_outdated', '{}');
  end if;
  if v.status = 'pending_approval' then
    perform approve_variant(v.id, p_actor);
  elsif v.status not in ('approved', 'scheduled', 'failed') then
    raise exception '%', tpl('err.not_pending', '{}');
  end if;
  v_at := schedule_variant(v.id, case when p_now then now() end, p_actor);
  perform package_try_card(p.id);
  return jsonb_build_object('scheduled_at', v_at, 'publish_now', v_at <= now() + interval '1 minute');
end $$;

create or replace function set_variant_time(p_variant bigint, p_at timestamptz, p_actor bigint) returns jsonb
language plpgsql as $$
declare
  v variants;
  p packages;
begin
  select * into v from variants where id = p_variant for update;
  select * into p from packages where id = v.package_id;
  perform require_can(p_actor, p.brand_id, 'approve');
  if p_at < now() - interval '1 minute' then
    raise exception '%', tpl('err.time_in_past', '{}');
  end if;
  if v.status in ('pending_approval', 'revising') then
    update variants set slot_hint_at = p_at where id = v.id;
    perform propose_slot(v.id);
  elsif v.status in ('approved', 'scheduled', 'failed') then
    perform schedule_variant(v.id, p_at, p_actor);
  else
    raise exception '%', tpl('err.not_editable', jsonb_build_object('status', status_label(v.status)));
  end if;
  perform audit(p_actor, 'variant.time_set', 'variant', v.id, p.brand_id, p.material_id, jsonb_build_object('at', p_at));
  perform package_try_card(p.id);
  return job_flags();
end $$;

-- Parse a time typed by the editor in the brand time zone: "2026-10-01 18:00", "01.10 18:00", "18:00", "tomorrow 9:30".
create or replace function parse_user_time(p_text text, p_tz text) returns timestamptz
language plpgsql stable as $$
declare
  t text := lower(trim(p_text));
  v_local timestamp;
  v_now timestamp := now() at time zone p_tz;
  v_hm text;
begin
  if t ~ '^\d{4}-\d{2}-\d{2}[ t]\d{1,2}:\d{2}$' then
    v_local := replace(t, 't', ' ')::timestamp;
  elsif t ~ '^\d{1,2}\.\d{1,2}(\.\d{4})? \d{1,2}:\d{2}$' then
    v_local := to_timestamp(case when t ~ '^\d{1,2}\.\d{1,2} ' then regexp_replace(t, '^(\d{1,2})\.(\d{1,2}) ', '\1.\2.' || extract(year from v_now) || ' ') else t end,
                            'DD.MM.YYYY HH24:MI')::timestamp;
  elsif t ~ '^(tomorrow )?\d{1,2}:\d{2}$' then
    v_hm := regexp_replace(t, '^tomorrow ', '');
    v_local := v_now::date + v_hm::time + case when t like 'tomorrow%' then interval '1 day' else interval '0' end;
    if t not like 'tomorrow%' and v_local < v_now then
      v_local := v_local + interval '1 day';
    end if;
  else
    return null;
  end if;
  return v_local at time zone p_tz;
exception when others then
  return null;
end $$;

-- GN-4: pick one of the three generated first lines/headlines -> new version.
create or replace function choose_headline(p_variant bigint, p_idx int, p_actor bigint) returns jsonb
language plpgsql as $$
declare
  v variants;
  cur variant_versions;
  v_h text;
  v_kind text;
  v_content jsonb;
  v_text text;
begin
  select * into v from variants where id = p_variant for update;
  perform require_can(p_actor, variant_brand(v.id), 'approve');
  select * into cur from variant_versions where variant_id = v.id and version = v.current_version;
  v_h := cur.headline_options ->> p_idx;
  if v_h is null then
    raise exception '%', tpl('err.no_headline', '{}');
  end if;
  v_kind := variant_kind(v.id);
  v_content := case
    when v_kind in ('article', 'email_block') then cur.content || jsonb_build_object('title', v_h)
    when v_kind = 'thread' then jsonb_set(cur.content, '{posts,0}', to_jsonb(v_h))
    else jsonb_build_object('text', v_h || E'\n' || coalesce(nullif(substring(cur.content ->> 'text' from '\n(.*)$'), ''), ''))
  end;
  v_text := content_to_text(v_kind, v_content);
  return human_edit(v.id, v_text, p_actor, 'edit');
end $$;

-- RT-5: redirect before publication = new package in another brand, the old one is cancelled.
create or replace function redirect_package(p_package bigint, p_brand bigint, p_actor bigint) returns jsonb
language plpgsql as $$
declare
  p packages;
  v record;
  v_new bigint;
begin
  select * into p from packages where id = p_package for update;
  perform require_can(p_actor, p.brand_id, 'approve');
  perform require_can(p_actor, p_brand, 'approve');
  if p.cancelled_at is not null then
    raise exception '%', tpl('err.package_cancelled', '{}');
  end if;
  if exists (select 1 from variants where package_id = p.id and status in ('publishing', 'published')) then
    raise exception '%', tpl('err.already_published', '{}');
  end if;
  if exists (select 1 from packages where material_id = p.material_id and brand_id = p_brand and cancelled_at is null) then
    raise exception '%', tpl('err.package_exists', '{}');
  end if;
  update packages set cancelled_at = now() where id = p.id;
  for v in select id from variants where package_id = p.id and status not in ('rejected', 'cancelled', 'published') loop
    perform transition('variant', v.id, 'cancelled', p_actor, 'redirected');
  end loop;
  update jobs set status = 'cancelled', finished_at = now() where package_id = p.id and status in ('queued', 'failed', 'blocked');
  insert into material_routes (material_id, brand_id, method, decided_by) values (p.material_id, p_brand, 'redirect', p_actor)
  on conflict (material_id, brand_id) do update set method = 'redirect', decided_by = p_actor;
  v_new := create_package(p.material_id, p_brand, p.id);
  perform audit(p_actor, 'package.redirected', 'package', p.id, p.brand_id, p.material_id, jsonb_build_object('to_brand', p_brand, 'new_package', v_new));
  perform card_render_all(p.id);
  return jsonb_build_object('package_id', v_new);
end $$;

create or replace function mark_published(p_variant bigint, p_actor bigint) returns jsonb
language plpgsql as $$
declare
  v variants;
begin
  select * into v from variants where id = p_variant for update;
  perform require_can(p_actor, variant_brand(v.id), 'approve');
  if v.status <> 'publishing' then
    raise exception '%', tpl('err.not_publishing', '{}');
  end if;
  update publish_attempts set outcome = 'ok', finished_at = now(), error = coalesce(error, '') || ' | confirmed by editor'
   where variant_id = v.id and outcome in ('unknown', 'pending') and op = 'publish';
  update variants set published_at = now(), next_attempt_at = null where id = v.id;
  perform transition('variant', v.id, 'published', p_actor, 'confirmed manually');
  perform package_try_card(v.package_id);
  return job_flags();
end $$;

-- "Publish again" after an unknown outcome / failure: explicit editor decision, a new attempt (PB-5, PB-6).
create or replace function retry_publish(p_variant bigint, p_actor bigint) returns jsonb
language plpgsql as $$
declare
  v variants;
begin
  select * into v from variants where id = p_variant for update;
  perform require_can(p_actor, variant_brand(v.id), 'approve');
  if v.status = 'failed' then
    perform schedule_variant(v.id, now(), p_actor);
  elsif v.status = 'publishing' and not exists (select 1 from publish_attempts where variant_id = v.id and outcome = 'pending') then
    update variants set next_attempt_at = now(), publish_first_attempt_at = now() where id = v.id;
  else
    raise exception '%', tpl('err.not_retryable', '{}');
  end if;
  perform audit(p_actor, 'variant.publish_retry', 'variant', v.id, variant_brand(v.id), null, '{}');
  return jsonb_build_object('publish_now', true);
end $$;
