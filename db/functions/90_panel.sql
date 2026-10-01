-- Read models for the web service (architecture 7.9, 7.11). The web role sees only these schemas:
--   site  — public blog data, previews by token, cookie-less counters;
--   panel — read-only panel, rows filtered by current_setting('app.user_id') (brand isolation at the DB level).
-- Views run with owner rights over base tables; security_barrier keeps filters from being bypassed by leaky predicates.

create schema if not exists site;
create schema if not exists panel;

-- Helpers called directly inside the views run as the owner (the web role has no rights on base tables).
alter function blog_base_url(bigint) security definer set search_path = public;
alter function variant_visual(bigint) security definer set search_path = public;
alter function platform_label(text) security definer set search_path = public;
alter function publish_target(bigint) security definer set search_path = public;
alter function user_label(bigint) security definer set search_path = public;
alter function is_paused(bigint) security definer set search_path = public;
alter function material_parts_summary(bigint) security definer set search_path = public;

-- ---------- site ----------
drop view if exists site.brands cascade;
create view site.brands with (security_barrier) as
select b.id, b.slug, b.name, b.blog_domain, blog_base_url(b.id) as blog_url, b.timezone,
       pv.profile #>> '{basics,description}' as description,
       pv.profile #>> '{basics,niche}' as niche,
       coalesce(pv.profile #> '{basics,languages}', '["en"]') as languages,
       coalesce(pv.profile #> '{visual,palette}', '[]') as palette,
       pv.profile #>> '{digest,title}' as digest_title,
       pv.profile #>> '{basics,website}' as website,
       (select a.id from assets a where a.s3_key = pv.profile #>> '{visual,logo,asset_key}') as logo_asset_id,
       exists (select 1 from brand_platforms bp where bp.brand_id = b.id and bp.platform = 'email' and bp.mode = 'real' and bp.is_active) as newsletter,
       (select 'https://t.me/' || substr(bp.target ->> 'chat_id', 2) from brand_platforms bp
        where bp.brand_id = b.id and bp.platform = 'telegram' and bp.mode = 'real' and bp.is_active and bp.target ->> 'chat_id' like '@%'
        limit 1) as telegram_url,
       b.is_demo
from brands b
join brand_profile_versions pv on pv.brand_id = b.id and pv.status = 'active'
where b.status = 'active' and not b.is_temporary;

drop view if exists site.posts cascade;
create view site.posts with (security_barrier) as
select v.id as variant_id, p.brand_id, b.slug as brand_slug,
       coalesce(vv.content ->> 'slug', 'post-' || v.id) as slug,
       vv.content ->> 'title' as title, vv.content ->> 'lead' as lead, vv.content -> 'sections' as sections,
       vv.content ->> 'seo_description' as seo_description,
       variant_visual(v.id) as cover_asset_id, v.published_at, bp.language, v.external_url as url,
       (select count(*) from variants o where o.package_id = p.id and o.status = 'published') as siblings_published
from variants v
join packages p on p.id = v.package_id and not p.is_guest and not p.is_eval
join brands b on b.id = p.brand_id and b.status = 'active' and not b.is_temporary
join brand_platforms bp on bp.id = v.brand_platform_id and bp.mode = 'real'
join variant_versions vv on vv.variant_id = v.id and vv.version = v.current_version
where v.platform = 'blog' and v.status = 'published' and v.external_deleted_at is null;

-- "How it will look" pages (PB-8) and card previews: accessible only by the unguessable token.
drop view if exists site.previews cascade;
create view site.previews with (security_barrier) as
select v.preview_token as token, v.id as variant_id, b.name as brand_name, b.slug as brand_slug, v.platform,
       platform_label(v.platform) as platform_label, bp.mode, publish_target(v.id) as target, v.status, v.published_at,
       v.scheduled_at, v.proposed_at, vv.content, vv.plain_text, vv.version, variant_visual(v.id) as visual_asset_id,
       v.external_url, coalesce(pv.profile #> '{visual,palette}', '[]') as palette, bp.language,
       (select a.width from assets a where a.id = variant_visual(v.id)) as visual_width,
       (select a.height from assets a where a.id = variant_visual(v.id)) as visual_height
from variants v
join packages p on p.id = v.package_id
join brands b on b.id = p.brand_id
join brand_platforms bp on bp.id = v.brand_platform_id
join brand_profile_versions pv on pv.brand_id = p.brand_id and pv.version = p.profile_version
join variant_versions vv on vv.variant_id = v.id and vv.version = v.current_version
where v.current_version > 0;

drop view if exists site.digest_previews cascade;
create view site.digest_previews with (security_barrier) as
select di.preview_token as token, di.id as issue_id, b.name as brand_name, b.slug as brand_slug, di.subject, di.preheader,
       replace(coalesce(di.html, ''), '{{unsubscribe_url}}', '#') as html, di.status, di.send_at
from digest_issues di join brands b on b.id = di.brand_id;

-- Case page (tz 10): live numbers of the demo brands' content flow, aggregates only.
drop view if exists site.case_stats cascade;
create view site.case_stats with (security_barrier) as
with f as (
  select p.id as package_id, p.material_id, p.card_sent_at, m.created_at as received_at
  from packages p
  join brands b on b.id = p.brand_id and b.is_demo and b.status = 'active' and not b.is_temporary
  join materials m on m.id = p.material_id
  where not p.is_guest and not p.is_eval and p.cancelled_at is null
), v as (
  select v.id, v.status, v.approved_at, v.auto_approved, v.published_at, f.received_at
  from variants v join f on f.package_id = v.package_id
)
select
  (select count(*) from brands where is_demo and status = 'active' and not is_temporary) as brands,
  (select count(distinct material_id) from f) as materials,
  (select count(*) from f) as packages,
  (select count(*) from v where status = 'published') as published,
  (select round(100.0 * count(*) filter (where not exists (select 1 from variant_versions vv where vv.variant_id = v.id
                                                           and vv.reason in ('edit', 'redo', 'headline'))) / nullif(count(*), 0))
   from v where approved_at is not null and not auto_approved) as approved_without_edits_pct,
  (select round((percentile_cont(0.5) within group (order by extract(epoch from card_sent_at - received_at)) / 60)::numeric, 1)
   from f where card_sent_at is not null) as median_minutes_to_card,
  (select round((percentile_cont(0.5) within group (order by extract(epoch from published_at - received_at)) / 3600)::numeric, 1)
   from v where status = 'published') as median_hours_to_publish,
  (select round(avg((select coalesce(sum(a.cost_usd), 0) from ai_usage a where a.package_id = f.package_id)
                    + coalesce((select sum(a.cost_usd) from ai_usage a where a.material_id = f.material_id and a.package_id is null), 0)
                      / greatest((select count(*) from packages x where x.material_id = f.material_id), 1))::numeric, 4)
   from f) as avg_package_cost_usd,
  (select min(published_at) from v where status = 'published') as since;

-- Asset access for /media: public if part of published content, or reachable through a preview token.
create or replace function site.asset(p_asset bigint, p_token uuid default null)
returns table (s3_key text, mime text)
language sql stable security definer set search_path = public as $$
  select a.s3_key, a.mime from assets a
  where a.id = p_asset and (
       exists (select 1 from site.posts sp where sp.cover_asset_id = a.id)
    or exists (select 1 from site.brands sb where sb.logo_asset_id = a.id)
    or exists (select 1 from digest_items di join digest_issues i on i.id = di.issue_id where di.image_asset_id = a.id and i.status in ('publishing', 'published'))
    or exists (select 1 from variants v where v.status = 'published' and variant_visual(v.id) = a.id)
    or (p_token is not null and exists (select 1 from variants v where v.preview_token = p_token and variant_visual(v.id) = a.id))
    or (p_token is not null and exists (select 1 from digest_issues i join digest_items di on di.issue_id = i.id where i.preview_token = p_token and di.image_asset_id = a.id)))
$$;

create or replace function site.count_view(p_brand bigint, p_path text, p_variant bigint default null) returns void
language sql security definer set search_path = public as $$
  insert into web_page_views (day, brand_id, path, variant_id, views) values (current_date, p_brand, left(p_path, 300), p_variant, 1)
  on conflict (day, brand_id, path) do update set views = web_page_views.views + 1
$$;

create or replace function site.count_click(p_brand bigint, p_variant bigint, p_url text) returns void
language sql security definer set search_path = public as $$
  insert into web_link_clicks (day, brand_id, variant_id, url, clicks) values (current_date, p_brand, p_variant, left(p_url, 1000), 1)
  on conflict (day, brand_id, url) do update set clicks = web_link_clicks.clicks + 1
$$;

-- ---------- panel: sessions ----------
create or replace function panel.login(p_token text) returns table (session_token text, user_id bigint, expires_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  t panel_login_tokens;
  v_session text := encode(gen_random_bytes(32), 'hex');
  v_exp timestamptz := now() + make_interval(days => coalesce(setting_num('panel.session_days'), 7)::int);
begin
  update panel_login_tokens lt set used_at = now()
   where lt.token_hash = digest(p_token, 'sha256') and lt.used_at is null and lt.expires_at > now()
  returning * into t;
  if t.user_id is null or not has_any_access(t.user_id) then
    return;
  end if;
  insert into web_sessions (token_hash, user_id, expires_at) values (digest(v_session, 'sha256'), t.user_id, v_exp);
  perform audit(t.user_id, 'panel.login', 'user', t.user_id, null, null, '{}');
  return query select v_session, t.user_id, v_exp;
end $$;

-- Every request re-checks the session AND current memberships (revocation is immediate, AD-2).
create or replace function panel.session_user(p_session text) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_user bigint;
begin
  update web_sessions s set last_seen_at = now()
   where s.token_hash = digest(p_session, 'sha256') and s.expires_at > now()
  returning s.user_id into v_user;
  if v_user is null or not has_any_access(v_user) or (select status from users where id = v_user) <> 'active' then
    return null;
  end if;
  return v_user;
end $$;

create or replace function panel.logout(p_session text) returns void
language sql security definer set search_path = public as $$ delete from web_sessions where token_hash = digest(p_session, 'sha256') $$;

create or replace function panel.uid() returns bigint
language sql stable as $$ select nullif(current_setting('app.user_id', true), '')::bigint $$;

-- Brands visible to the current panel user: admins all, others their memberships (viewer/editor/manager/author).
create or replace function panel.visible_brands() returns setof bigint
language sql stable security definer set search_path = public as $$
  select b.id from brands b
  where not b.is_temporary and (
    exists (select 1 from users u where u.id = panel.uid() and u.is_admin and u.status = 'active')
    or exists (select 1 from memberships m where m.user_id = panel.uid() and m.brand_id = b.id))
$$;

-- Brands where the user sees everything (authors only see their own materials, tz section 3).
create or replace function panel.full_brands() returns setof bigint
language sql stable security definer set search_path = public as $$
  select b.id from brands b
  where not b.is_temporary and (
    exists (select 1 from users u where u.id = panel.uid() and u.is_admin and u.status = 'active')
    or exists (select 1 from memberships m where m.user_id = panel.uid() and m.brand_id = b.id and m.role in ('manager', 'editor', 'viewer')))
$$;

drop view if exists panel.me cascade;
create view panel.me with (security_barrier) as
select u.id, coalesce(nullif(u.display_name, ''), u.tg_username, 'user ' || u.id) as name, u.tg_username, u.is_admin
from users u where u.id = panel.uid();

drop view if exists panel.brands cascade;
create view panel.brands with (security_barrier) as
select b.id, b.slug, b.name, b.timezone, b.status, b.monthly_budget_usd,
       case when (select is_admin from users where id = panel.uid()) then 'admin' else m.role end as role,
       b.id in (select panel.full_brands()) as full_access
from brands b left join memberships m on m.brand_id = b.id and m.user_id = panel.uid()
where b.id in (select panel.visible_brands());

drop view if exists panel.platforms cascade;
create view panel.platforms with (security_barrier) as
select bp.id, bp.brand_id, bp.platform, platform_label(bp.platform) as label, bp.language, bp.mode, bp.is_active, bp.auto_publish,
       is_paused(bp.id) as paused
from brand_platforms bp where bp.brand_id in (select panel.full_brands());

-- Materials the user may see: all materials of full-access brands + own materials.
drop view if exists panel.materials cascade;
create view panel.materials with (security_barrier) as
select m.id, 'M-' || m.id as code, m.created_at, m.status, m.source, m.is_guest, m.low_data,
       user_label(m.author_user_id) as author, m.author_user_id = panel.uid() as is_own,
       (select array_agg(p.brand_id order by p.brand_id) from packages p where p.material_id = m.id and p.cancelled_at is null) as brand_ids,
       (select string_agg(b.name, ', ' order by b.name) from packages p join brands b on b.id = p.brand_id where p.material_id = m.id and p.cancelled_at is null) as brands,
       e.summary ->> 'main_idea' as main_idea, e.language, m.reject_reason,
       (select count(*) from variants v join packages p on p.id = v.package_id where p.material_id = m.id) as variants,
       (select count(*) from variants v join packages p on p.id = v.package_id where p.material_id = m.id and v.status = 'published') as published,
       (select coalesce(sum(cost_usd), 0) from ai_usage a where a.material_id = m.id) as cost_usd,
       m.parent_material_id
from materials m
left join material_extracts e on e.material_id = m.id
where not m.is_eval and not m.is_container and (
      m.author_user_id = panel.uid()
   or exists (select 1 from packages p where p.material_id = m.id and p.brand_id in (select panel.full_brands()))
   or (exists (select 1 from users u where u.id = panel.uid() and u.is_admin)));

drop view if exists panel.material_detail cascade;
create view panel.material_detail with (security_barrier) as
select pm.id, pm.code, pm.created_at, pm.status, pm.source, pm.author, pm.brands, pm.cost_usd, pm.reject_reason, pm.low_data,
       e.text as source_text, e.summary, m.hints, material_parts_summary(m.id) as parts
from panel.materials pm join materials m on m.id = pm.id left join material_extracts e on e.material_id = m.id;

-- End-to-end history of a material (tz section 8 tracing): audit + jobs + AI calls + publish attempts.
drop view if exists panel.material_events cascade;
create view panel.material_events with (security_barrier) as
select a.material_id, a.at, 'audit' as kind, a.action as title,
       coalesce(user_label(a.actor_user_id), 'system') as actor, a.entity, a.entity_id, a.data as details, null::numeric as cost_usd
from audit_log a where a.material_id in (select id from panel.materials)
union all
select j.material_id, coalesce(j.started_at, j.created_at), 'job', j.type || ' · ' || j.status, 'system', 'job', j.id,
       jsonb_strip_nulls(jsonb_build_object('attempts', j.attempts, 'error', left(j.last_error, 500), 'blocked', j.blocked_reason,
                                            'finished_at', j.finished_at)), null
from jobs j where j.material_id in (select id from panel.materials)
union all
select u.material_id, u.at, 'ai', u.route || ' · ' || u.model || ' · ' || u.status, 'ai', 'ai_usage', u.id,
       jsonb_strip_nulls(jsonb_build_object('input_tokens', u.input_tokens, 'output_tokens', u.output_tokens,
                                            'cache_read_tokens', u.cache_read_tokens, 'latency_ms', u.latency_ms, 'error', left(u.error, 300),
                                            'package_id', u.package_id, 'variant_id', u.variant_id)), u.cost_usd
from ai_usage u where u.material_id in (select id from panel.materials)
union all
select p.material_id, pa.started_at, 'publish', pa.adapter || ' · ' || pa.op || ' · ' || pa.outcome, 'system', 'variant', pa.variant_id,
       jsonb_strip_nulls(jsonb_build_object('url', pa.external_url, 'error', left(pa.error, 300), 'http', pa.http_status)), null
from publish_attempts pa join variants v on v.id = pa.variant_id join packages p on p.id = v.package_id
where p.material_id in (select id from panel.materials);

drop view if exists panel.variants cascade;
create view panel.variants with (security_barrier) as
select v.id, v.package_id, p.material_id, p.brand_id, b.name as brand_name, v.platform, platform_label(v.platform) as platform_label,
       bp.mode, publish_target(v.id) as target, v.status, v.check_status, v.current_version,
       v.proposed_at, v.scheduled_at, v.published_at, v.external_url, v.preview_token,
       left(vv.plain_text, 400) as excerpt, vv.plain_text as text,
       coalesce(vv.content ->> 'title', split_part(vv.plain_text, E'\n', 1)) as title,
       user_label(v.approved_by) as approved_by, v.auto_approved, v.metrics,
       p.created_at as package_created_at, p.card_sent_at, v.approved_at
from variants v
join packages p on p.id = v.package_id and not p.is_eval
join brands b on b.id = p.brand_id
join brand_platforms bp on bp.id = v.brand_platform_id
left join variant_versions vv on vv.variant_id = v.id and vv.version = v.current_version
where p.brand_id in (select panel.full_brands())
   or p.material_id in (select id from materials where author_user_id = panel.uid());

drop view if exists panel.variant_versions cascade;
create view panel.variant_versions with (security_barrier) as
select vv.variant_id, vv.version, vv.created_at, vv.author_kind, user_label(vv.author_user_id) as author, vv.reason, vv.comment, vv.plain_text,
       (select jsonb_agg(jsonb_build_object('check', c.check_name, 'status', c.status, 'required', c.required, 'details', c.details) order by c.check_name)
        from check_results c where c.variant_id = vv.variant_id and c.version = vv.version) as checks
from variant_versions vv where vv.variant_id in (select id from panel.variants);

-- Calendar (AN-1): scheduled, published, failed, and proposed slots of pending variants.
drop view if exists panel.calendar cascade;
create view panel.calendar with (security_barrier) as
select v.id as variant_id, v.brand_id, v.brand_name, v.platform, v.platform_label, v.target, v.status, v.material_id,
       coalesce(v.published_at, v.scheduled_at, v.proposed_at) as at,
       case when v.status in ('pending_approval', 'revising') then 'proposed' else v.status end as kind,
       v.title, v.external_url, v.preview_token
from panel.variants v
where v.status in ('pending_approval', 'revising', 'approved', 'scheduled', 'rescheduled', 'publishing', 'published', 'failed')
  and coalesce(v.published_at, v.scheduled_at, v.proposed_at) is not null;

drop view if exists panel.queue cascade;
create view panel.queue with (security_barrier) as
select v.id as variant_id, v.package_id, v.material_id, v.brand_id, v.brand_name, v.platform, v.platform_label, v.status, v.check_status,
       v.proposed_at, v.package_created_at as created_at, v.excerpt, v.preview_token,
       now() - v.package_created_at as age
from panel.variants v where v.status in ('pending_approval', 'revising');

drop view if exists panel.digests cascade;
create view panel.digests with (security_barrier) as
select di.id, di.brand_id, b.name as brand_name, di.send_at, di.status, di.subject, di.stats, di.preview_token,
       (select count(*) from digest_items i where i.issue_id = di.id) as blocks
from digest_issues di join brands b on b.id = di.brand_id
where di.brand_id in (select panel.full_brands());

-- Facts for reports (AN-2); the web aggregates with brand/platform/period filters and exports CSV (AN-4).
drop view if exists panel.variant_facts cascade;
create view panel.variant_facts with (security_barrier) as
select v.id as variant_id, p.brand_id, v.platform, p.material_id, m.created_at as received_at, p.created_at as package_at,
       p.card_sent_at as card_at, v.approved_at, v.published_at, v.status, v.auto_approved,
       (select count(*) from variant_versions vv where vv.variant_id = v.id) as versions,
       (select count(*) from variant_versions vv where vv.variant_id = v.id and vv.reason in ('edit', 'redo', 'headline')) as edits,
       (select count(*) from publish_attempts a where a.variant_id = v.id and a.outcome in ('failed', 'unknown')) as publish_errors,
       coalesce((v.metrics ->> 'reactions')::int, 0) as reactions,
       (select coalesce(sum(w.views), 0) from web_page_views w where w.variant_id = v.id) as views,
       (select coalesce(sum(c.clicks), 0) from web_link_clicks c where c.variant_id = v.id) as clicks,
       (select coalesce(sum(cost_usd), 0) from ai_usage a where a.variant_id = v.id) as cost_usd
from variants v
join packages p on p.id = v.package_id and not p.is_eval and not p.is_guest
join materials m on m.id = p.material_id
where p.brand_id in (select panel.full_brands());

drop view if exists panel.package_facts cascade;
create view panel.package_facts with (security_barrier) as
select p.id as package_id, p.brand_id, p.material_id, m.source, m.created_at as received_at, p.created_at, p.card_sent_at,
       p.cancelled_at,
       (select coalesce(sum(cost_usd), 0) from ai_usage a where a.package_id = p.id)
       + coalesce((select sum(cost_usd) from ai_usage a where a.material_id = p.material_id and a.package_id is null), 0)
         / greatest((select count(*) from packages x where x.material_id = p.material_id), 1) as cost_usd
from packages p join materials m on m.id = p.material_id
where not p.is_eval and not p.is_guest and p.brand_id in (select panel.full_brands());

drop view if exists panel.cost_daily cascade;
create view panel.cost_daily with (security_barrier) as
select date_trunc('day', a.at)::date as day, a.brand_id, a.route, sum(a.cost_usd) as cost_usd, count(*) as calls
from ai_usage a where a.account_type = 'brand' and a.brand_id in (select panel.full_brands())
group by 1, 2, 3;

drop view if exists panel.audit cascade;
create view panel.audit with (security_barrier) as
select a.id, a.at, coalesce(user_label(a.actor_user_id), 'system') as actor, a.action, a.entity, a.entity_id, a.brand_id, a.material_id, a.data
from audit_log a
where a.brand_id in (select panel.full_brands()) or (a.brand_id is null and (select is_admin from users where id = panel.uid()));
