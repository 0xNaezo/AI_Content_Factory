-- Brand configuration as YAML (decision: YAML round-trip through the bot), versions (BP-2), onboarding (BP-3), guest brands.

-- Default platforms for a new brand: real Telegram/blog/email, preview social networks (tz section 4).
create or replace function default_platforms(p_lang text) returns jsonb
language sql immutable as $$
  select jsonb_build_array(
    jsonb_build_object('platform', 'telegram', 'language', p_lang, 'mode', 'real', 'active', true, 'auto_publish', false,
      'target', jsonb_build_object('chat_id', '@your_channel'),
      'schedule', jsonb_build_object('slots', jsonb_build_array(jsonb_build_object('days', jsonb_build_array(1,2,3,4,5), 'times', jsonb_build_array('09:30', '18:00'))), 'max_per_day', 2, 'min_interval_minutes', 180)),
    jsonb_build_object('platform', 'blog', 'language', p_lang, 'mode', 'real', 'active', true, 'auto_publish', false, 'target', '{}'::jsonb,
      'schedule', jsonb_build_object('slots', jsonb_build_array(jsonb_build_object('days', jsonb_build_array(2,4), 'times', jsonb_build_array('11:00'))), 'max_per_day', 1, 'min_interval_minutes', 720)),
    jsonb_build_object('platform', 'email', 'language', p_lang, 'mode', 'real', 'active', true, 'auto_publish', false,
      'target', jsonb_build_object('from_name', 'Newsletter'), 'schedule', jsonb_build_object('frequency', 'weekly', 'day', 5, 'time', '10:00', 'auto_send', false)),
    jsonb_build_object('platform', 'linkedin', 'language', p_lang, 'mode', 'preview', 'active', true, 'auto_publish', false, 'target', '{}'::jsonb,
      'schedule', jsonb_build_object('slots', jsonb_build_array(jsonb_build_object('days', jsonb_build_array(2,3,4), 'times', jsonb_build_array('08:30'))), 'max_per_day', 1, 'min_interval_minutes', 600)),
    jsonb_build_object('platform', 'instagram', 'language', p_lang, 'mode', 'preview', 'active', true, 'auto_publish', false, 'target', '{}'::jsonb,
      'schedule', jsonb_build_object('slots', jsonb_build_array(jsonb_build_object('days', jsonb_build_array(1,2,3,4,5,6,7), 'times', jsonb_build_array('12:00'))), 'max_per_day', 1, 'min_interval_minutes', 600)),
    jsonb_build_object('platform', 'facebook', 'language', p_lang, 'mode', 'preview', 'active', true, 'auto_publish', false, 'target', '{}'::jsonb,
      'schedule', jsonb_build_object('slots', jsonb_build_array(jsonb_build_object('days', jsonb_build_array(1,3,5), 'times', jsonb_build_array('13:00'))), 'max_per_day', 1, 'min_interval_minutes', 600)),
    jsonb_build_object('platform', 'x', 'language', p_lang, 'mode', 'preview', 'active', true, 'auto_publish', false, 'target', '{}'::jsonb,
      'schedule', jsonb_build_object('slots', jsonb_build_array(jsonb_build_object('days', jsonb_build_array(1,2,3,4,5), 'times', jsonb_build_array('10:00', '16:00'))), 'max_per_day', 2, 'min_interval_minutes', 240)))
$$;

-- The whole brand config for export: brand fields + profile (active or latest draft) + platforms + feeds.
create or replace function brand_config(p_brand bigint, p_version int default null) returns jsonb
language plpgsql stable as $$
declare
  b brands;
  pv brand_profile_versions;
begin
  select * into b from brands where id = p_brand;
  select * into pv from brand_profile_versions where brand_id = p_brand
    and (version = p_version or (p_version is null and status in ('active', 'draft')))
  order by (status = 'draft') desc, version desc limit 1;
  return jsonb_build_object(
    'brand', jsonb_build_object('slug', b.slug, 'name', b.name, 'timezone', b.timezone, 'blog_domain', b.blog_domain,
                                'monthly_budget_usd', b.monthly_budget_usd),
    'profile', pv.profile,
    'platforms', coalesce(nullif(pv.config -> 'platforms', 'null'), (select jsonb_agg(jsonb_build_object(
        'platform', platform, 'language', language, 'mode', mode, 'active', is_active, 'auto_publish', auto_publish,
        'target', target, 'schedule', schedule) order by id) from brand_platforms where brand_id = b.id),
        default_platforms(coalesce(pv.profile #>> '{basics,languages,0}', 'en'))),
    'feeds', coalesce(pv.config -> 'feeds', (select jsonb_agg(url order by id) from feed_sources where brand_id = b.id and is_active), '[]'),
    '_version', pv.version, '_status', pv.status);
end $$;

create or replace function profile_export_context(p_brand bigint, p_user bigint) returns jsonb
language sql stable as $$
  select jsonb_build_object('config', c - '_version' - '_status', 'user_id', p_user, 'brand_id', p_brand,
                            'file_name', b.slug || '-v' || coalesce(c ->> '_version', '0') || '.yaml',
                            'caption', tpl('profile.export_caption', jsonb_build_object('brand', b.name, 'version', coalesce(c ->> '_version', '—'),
                                                                                         'status', coalesce(c ->> '_status', 'new'))),
                            'header', tpl('profile.yaml_header', jsonb_build_object('brand', b.name, 'version', coalesce(c ->> '_version', '—'))),
                            'extractor_base', setting_text('api.extractor_base'),
                            'telegram_base', setting_text('api.telegram_base'), 'telegram_file_base', setting_text('api.telegram_file_base'))
  from brands b, brand_config(p_brand) c where b.id = p_brand
$$;

-- Validation of the operational part (the profile itself is validated against schemas/brand-profile.schema.json by the extractor).
create or replace function config_errors(p_config jsonb) returns text[]
language plpgsql stable as $$
declare
  v_err text[] := '{}';
  pl jsonb;
begin
  if p_config #>> '{brand,timezone}' is not null and not is_timezone(p_config #>> '{brand,timezone}') then
    v_err := v_err || ('brand.timezone: unknown time zone ' || (p_config #>> '{brand,timezone}'));
  end if;
  for pl in select * from jsonb_array_elements(coalesce(p_config -> 'platforms', '[]')) loop
    if pl ->> 'platform' not in ('telegram', 'blog', 'email', 'linkedin', 'instagram', 'facebook', 'x') then
      v_err := v_err || ('platforms: unknown platform ' || coalesce(pl ->> 'platform', '?'));
    elsif pl ->> 'mode' not in ('real', 'preview') then
      v_err := v_err || ('platforms.' || (pl ->> 'platform') || '.mode must be real or preview');
    elsif pl ->> 'platform' not in ('telegram', 'blog', 'email') and pl ->> 'mode' = 'real' then
      v_err := v_err || ('platforms.' || (pl ->> 'platform') || ': real publishing is stage 2 — use mode: preview');
    elsif coalesce(pl ->> 'language', '') !~ '^[a-z]{2}$' then
      v_err := v_err || ('platforms.' || (pl ->> 'platform') || '.language must be an ISO 639-1 code');
    elsif pl ->> 'platform' = 'telegram' and pl ->> 'mode' = 'real' and coalesce(pl #>> '{target,chat_id}', '') !~ '^(@[A-Za-z0-9_]{4,}|-?\d+)$' then
      v_err := v_err || 'platforms.telegram.target.chat_id must be @channel or a numeric chat id'::text;
    end if;
  end loop;
  if jsonb_array_length(coalesce(p_config -> 'feeds', '[]')) > 10 then
    v_err := v_err || 'feeds: at most 10 sources (DG-2)'::text;
  end if;
  return v_err;
end $$;

-- Uploaded YAML (already parsed + schema-validated by the extractor) -> new draft version.
create or replace function profile_import(p_brand bigint, p_user bigint, p_config jsonb, p_schema_errors jsonb) returns jsonb
language plpgsql as $$
declare
  v_errors text[];
  v_version int;
begin
  perform require_can(p_user, p_brand, 'configure');
  v_errors := array(select jsonb_array_elements_text(coalesce(p_schema_errors, '[]'))) || config_errors(p_config);
  if p_config is not null and p_config -> 'profile' is null then  -- null config = the YAML itself did not parse
    v_errors := v_errors || 'profile: section is missing'::text;
  end if;
  if cardinality(v_errors) > 0 then
    perform tg_send(p_user, tpl('profile.invalid', jsonb_build_object('count', cardinality(v_errors))) || E'\n' ||
                            h(array_to_string(v_errors[1:25], E'\n')));
    return jsonb_build_object('ok', false, 'errors', to_jsonb(v_errors));
  end if;
  select coalesce(max(version), 0) + 1 into v_version from brand_profile_versions where brand_id = p_brand;
  update brand_profile_versions set status = 'discarded' where brand_id = p_brand and status = 'draft';
  insert into brand_profile_versions (brand_id, version, profile, config, status, source, created_by)
  values (p_brand, v_version, p_config -> 'profile', jsonb_build_object('brand', p_config -> 'brand', 'platforms', p_config -> 'platforms',
          'feeds', coalesce(p_config -> 'feeds', '[]')), 'draft', 'yaml', p_user);
  perform audit(p_user, 'profile.draft', 'brand', p_brand, p_brand, null, jsonb_build_object('version', v_version));
  perform tg_send(p_user, tpl('profile.draft_saved', jsonb_build_object('brand', (select name from brands where id = p_brand), 'version', v_version)),
                  kb(jsonb_build_array(btn('✅ Activate v' || v_version, 'pa:' || p_brand || ':' || v_version))));
  return jsonb_build_object('ok', true, 'version', v_version);
end $$;

-- Activate a draft: profile version becomes active (packages keep their own version), config applied.
create or replace function profile_activate(p_brand bigint, p_version int, p_user bigint) returns text
language plpgsql as $$
declare
  v_note text;
begin
  perform require_can(p_user, p_brand, 'configure');
  v_note := profile_apply(p_brand, p_version, p_user, can(p_user, null, 'admin'));
  perform tg_send(p_user, tpl('profile.activated', jsonb_build_object('brand', (select name from brands where id = p_brand), 'version', p_version)) || v_note);
  return 'Activated v' || p_version;
end $$;

-- Apply a profile version: status, brand fields, platforms, feeds. Budget changes only when p_budget_ok (admins, seeds).
create or replace function profile_apply(p_brand bigint, p_version int, p_actor bigint, p_budget_ok boolean) returns text
language plpgsql as $$
declare
  pv brand_profile_versions;
  pl jsonb;
  f text;
  v_budget numeric;
  v_note text := '';
begin
  select * into pv from brand_profile_versions where brand_id = p_brand and version = p_version for update;
  if pv.brand_id is null or pv.status not in ('draft', 'superseded') then
    raise exception '%', tpl('err.not_found', '{}');
  end if;
  update brand_profile_versions set status = 'superseded' where brand_id = p_brand and status = 'active';
  update brand_profile_versions set status = 'active' where brand_id = p_brand and version = p_version;
  if pv.config ? 'brand' then
    update brands set name = coalesce(pv.config #>> '{brand,name}', name),
                      timezone = coalesce(pv.config #>> '{brand,timezone}', pv.profile #>> '{basics,timezone}', timezone),
                      blog_domain = nullif(pv.config #>> '{brand,blog_domain}', '')
     where id = p_brand;
    v_budget := (pv.config #>> '{brand,monthly_budget_usd}')::numeric;
    if v_budget is not null and v_budget <> (select monthly_budget_usd from brands where id = p_brand) then
      if p_budget_ok then
        update brands set monthly_budget_usd = v_budget where id = p_brand;
        perform unblock_jobs('budget_exceeded:brand:' || p_brand || '%');
      else
        v_note := E'\n' || tpl('profile.budget_admin_only', '{}');
      end if;
    end if;
  end if;
  if jsonb_array_length(coalesce(pv.config -> 'platforms', '[]')) > 0 then
    update brand_platforms set is_active = false where brand_id = p_brand;
    for pl in select * from jsonb_array_elements(pv.config -> 'platforms') loop
      insert into brand_platforms (brand_id, platform, language, mode, is_active, auto_publish, target, schedule)
      values (p_brand, pl ->> 'platform', pl ->> 'language', pl ->> 'mode', coalesce((pl ->> 'active')::boolean, true),
              coalesce((pl ->> 'auto_publish')::boolean, false), coalesce(pl -> 'target', '{}'), coalesce(pl -> 'schedule', '{}'))
      on conflict (brand_id, platform, language) do update set mode = excluded.mode, is_active = excluded.is_active,
        auto_publish = excluded.auto_publish, target = excluded.target, schedule = excluded.schedule;
    end loop;
  end if;
  if pv.config ? 'feeds' then
    update feed_sources set is_active = false where brand_id = p_brand;
    for f in select jsonb_array_elements_text(pv.config -> 'feeds') loop
      insert into feed_sources (brand_id, url) values (p_brand, f) on conflict (brand_id, url) do update set is_active = true;
    end loop;
  end if;
  update brands set status = 'active' where id = p_brand and status = 'draft';
  perform audit(p_actor, 'profile.activated', 'brand', p_brand, p_brand, null, jsonb_build_object('version', p_version));
  return v_note;
end $$;

-- Seed / demo brand from a config document (same shape as the bot YAML). Idempotent: an unchanged config adds nothing.
create or replace function brand_seed(p_config jsonb, p_demo boolean default false) returns jsonb
language plpgsql as $$
declare
  v_slug text := lower(p_config #>> '{brand,slug}');
  v_brand bigint;
  v_version int;
  v_errors text[] := config_errors(p_config);
  v_cfg jsonb := jsonb_build_object('brand', p_config -> 'brand', 'platforms', p_config -> 'platforms', 'feeds', coalesce(p_config -> 'feeds', '[]'));
begin
  if v_slug is null or p_config -> 'profile' is null or cardinality(v_errors) > 0 then
    raise exception 'bad seed config %: %', coalesce(v_slug, '?'), array_to_string(v_errors || case when p_config -> 'profile' is null then array['profile missing'] else '{}' end, '; ');
  end if;
  insert into brands (slug, name, timezone, is_demo) values (v_slug, coalesce(p_config #>> '{brand,name}', v_slug),
    coalesce(p_config #>> '{brand,timezone}', 'UTC'), p_demo)
  on conflict (slug) do update set is_demo = excluded.is_demo
  returning id into v_brand;
  if exists (select 1 from brand_profile_versions where brand_id = v_brand and status = 'active' and profile = p_config -> 'profile' and config = v_cfg) then
    return jsonb_build_object('brand_id', v_brand, 'changed', false);
  end if;
  select coalesce(max(version), 0) + 1 into v_version from brand_profile_versions where brand_id = v_brand;
  insert into brand_profile_versions (brand_id, version, profile, config, status, source, note)
  values (v_brand, v_version, p_config -> 'profile', v_cfg, 'draft', 'seed', 'seed');
  perform profile_apply(v_brand, v_version, null, true);
  return jsonb_build_object('brand_id', v_brand, 'version', v_version, 'changed', true);
end $$;

create or replace function onboarding_context(p_brand bigint) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'brand_id', b.id, 'slug', b.slug, 'name', b.name,
    'samples', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'content', content, 'text', extracted_text) order by id), '[]')
                from onboarding_samples where brand_id = b.id),
    'extractor_base', setting_text('api.extractor_base'),
    'account_type', 'system')
  from brands b where b.id = p_brand
$$;

create or replace function onboarding_sample_text(p_sample bigint, p_text text) returns void
language sql as $$ update onboarding_samples set extracted_text = left(p_text, 20000) where id = p_sample $$;

-- LLM draft (schema-constrained) -> draft version with default platforms; the manager edits the YAML and activates.
create or replace function onboarding_draft_saved(p_brand bigint, p_user bigint, p_profile jsonb, p_schema_errors jsonb) returns jsonb
language plpgsql as $$
declare
  v_version int;
begin
  select coalesce(max(version), 0) + 1 into v_version from brand_profile_versions where brand_id = p_brand;
  update brand_profile_versions set status = 'discarded' where brand_id = p_brand and status = 'draft';
  insert into brand_profile_versions (brand_id, version, profile, config, status, source, created_by, note)
  values (p_brand, v_version, p_profile,
          jsonb_build_object('brand', jsonb_build_object('name', (select name from brands where id = p_brand), 'timezone', p_profile #>> '{basics,timezone}'),
                             'platforms', coalesce((select jsonb_agg(jsonb_build_object('platform', platform, 'language', language, 'mode', mode, 'active', is_active,
                                                    'auto_publish', auto_publish, 'target', target, 'schedule', schedule)) from brand_platforms where brand_id = p_brand),
                                                   default_platforms(coalesce(p_profile #>> '{basics,languages,0}', 'en'))),
                             'feeds', '[]'::jsonb),
          'draft', 'onboarding', p_user,
          case when jsonb_array_length(coalesce(p_schema_errors, '[]')) > 0 then 'schema warnings: ' || (p_schema_errors::text) end);
  perform audit(p_user, 'profile.onboarding_draft', 'brand', p_brand, p_brand, null, jsonb_build_object('version', v_version));
  perform enqueue_job('profile.export', jsonb_build_object('user_id', p_user, 'note', 'onboarding'), null, null, null, p_brand,
                      p_dedupe => 'profile_export:' || p_brand || ':' || v_version);
  perform tg_send(p_user, tpl('onboarding.draft_ready', jsonb_build_object('brand', (select name from brands where id = p_brand), 'version', v_version)),
                  kb(jsonb_build_array(btn('✅ Activate v' || v_version, 'pa:' || p_brand || ':' || v_version))));
  return jsonb_build_object('version', v_version);
end $$;

-- Guest temporary brand from one sentence (tz section 10): preview-only platforms, auto-deleted.
create or replace function guest_brand_create(p_user bigint, p_profile jsonb) returns jsonb
language plpgsql as $$
declare
  v_brand bigint;
  v_lang text := coalesce(p_profile #>> '{basics,languages,0}', 'en');
  v_name text := left(coalesce(p_profile #>> '{basics,name}', 'My brand'), 60);
  pl jsonb;
begin
  delete from brands where owner_user_id = p_user and is_temporary;
  insert into brands (slug, name, status, timezone, is_temporary, expires_at, owner_user_id, monthly_budget_usd)
  values ('guest-' || p_user || '-' || substr(md5(random()::text), 1, 6), v_name, 'active',
          case when is_timezone(p_profile #>> '{basics,timezone}') then p_profile #>> '{basics,timezone}' else 'UTC' end,
          true, now() + make_interval(hours => coalesce(setting_num('guest.temp_brand_ttl_hours'), 72)::int), p_user, 0)
  returning id into v_brand;
  insert into brand_profile_versions (brand_id, version, profile, status, source)
  values (v_brand, 1, p_profile, 'active', 'guest');
  for pl in select * from jsonb_array_elements(default_platforms(v_lang)) loop
    insert into brand_platforms (brand_id, platform, language, mode, schedule)
    values (v_brand, pl ->> 'platform', v_lang, 'preview', pl -> 'schedule');
  end loop;
  update users set guest_enabled = true, guest_brand_id = v_brand where id = p_user;
  perform audit(p_user, 'guest.brand_created', 'brand', v_brand, v_brand, null, '{}');
  perform tg_send(p_user, tpl('guest.brand_ready', jsonb_build_object('brand', v_name,
                  'hours', setting_num('guest.temp_brand_ttl_hours'))));
  return jsonb_build_object('brand_id', v_brand);
end $$;
