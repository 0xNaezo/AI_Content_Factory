-- Periodic work as jobs (architecture 4.5: brand-timezone schedules are jobs with run_after, not n8n cron),
-- health (AD-5), weekly report (AN-3), housekeeping, and the dispatcher for pure-SQL job types.

-- Weekly report text (AN-3; also /report). Numbers from the same facts the panel uses.
create or replace function weekly_report_text(p_brand bigint, p_from timestamptz, p_to timestamptz) returns text
language plpgsql stable as $$
declare
  br brands;
  r record;
begin
  select * into br from brands where id = p_brand;
  select
    (select count(distinct p.material_id) from packages p where p.brand_id = br.id and p.created_at between p_from and p_to) as materials,
    (select count(*) from packages p where p.brand_id = br.id and p.created_at between p_from and p_to and p.cancelled_at is null) as packages,
    (select count(*) from variants v join packages p on p.id = v.package_id where p.brand_id = br.id and v.status = 'published' and v.published_at between p_from and p_to) as published,
    (select count(*) from publish_attempts a join variants v on v.id = a.variant_id join packages p on p.id = v.package_id
      where p.brand_id = br.id and a.outcome in ('failed', 'unknown') and a.started_at between p_from and p_to) as errors,
    (select round(100.0 * count(*) filter (where not exists (select 1 from variant_versions vv where vv.variant_id = v.id and vv.reason in ('edit', 'redo')))
                  / nullif(count(*), 0)) from variants v join packages p on p.id = v.package_id
      where p.brand_id = br.id and v.approved_at between p_from and p_to and not v.auto_approved) as clean_pct,
    (select round(avg(extract(epoch from p.card_sent_at - m.created_at)) / 60) from packages p join materials m on m.id = p.material_id
      where p.brand_id = br.id and p.card_sent_at between p_from and p_to) as to_card_min,
    (select round(avg(extract(epoch from v.published_at - m.created_at)) / 3600, 1) from variants v join packages p on p.id = v.package_id
      join materials m on m.id = p.material_id where p.brand_id = br.id and v.published_at between p_from and p_to and v.status = 'published') as to_pub_h,
    (select coalesce(sum(cost_usd), 0) from ai_usage where brand_id = br.id and at between p_from and p_to) as cost,
    (select coalesce(sum((v.metrics ->> 'reactions')::int), 0) from variants v join packages p on p.id = v.package_id
      where p.brand_id = br.id and v.published_at between p_from and p_to) as reactions,
    (select coalesce(sum(views), 0) from web_page_views where brand_id = br.id and day between p_from::date and p_to::date) as blog_views
  into r;
  return tpl('report.weekly', jsonb_build_object('brand', br.name,
    'period', to_char(p_from at time zone br.timezone, 'DD Mon') || ' – ' || to_char(p_to at time zone br.timezone, 'DD Mon'),
    'materials', r.materials, 'packages', r.packages, 'published', r.published, 'errors', r.errors,
    'clean_pct', coalesce(r.clean_pct::text || '%', '—'), 'to_card', coalesce(r.to_card_min::text || ' min', '—'),
    'to_pub', coalesce(r.to_pub_h::text || ' h', '—'), 'cost', fmt_usd(r.cost),
    'cost_per_package', case when r.packages > 0 then fmt_usd(r.cost / r.packages) else '—' end,
    'reactions', r.reactions, 'blog_views', r.blog_views, 'panel', public_web_url() || '/panel/reports'));
end $$;

create or replace function weekly_report(p_brand bigint) returns jsonb
language plpgsql as $$
declare
  v_text text := weekly_report_text(p_brand, now() - interval '7 days', now());
  u record;
begin
  for u in select us.* from memberships m join users us on us.id = m.user_id
           where m.brand_id = p_brand and m.role in ('manager', 'viewer') and us.status = 'active' loop
    if u.tg_chat_id is not null and not u.tg_blocked_bot then
      perform tg_send(u.id, v_text, null, 'weekly:' || p_brand || ':' || u.id || ':' || to_char(now(), 'IYYY-IW'));
    elsif u.email is not null then
      perform email_send(u.email, 'Weekly report — ' || (select name from brands where id = p_brand), replace(v_text, E'\n', '<br>'), null,
                         'weekly_email:' || p_brand || ':' || u.id || ':' || to_char(now(), 'IYYY-IW'));
    end if;
  end loop;
  return job_flags();
end $$;

-- AD-5 health: queue depth/age, dead jobs, AI and publishing error rates. Returns what n8n needs for the heartbeat.
create or replace function health_check() returns jsonb
language plpgsql as $$
declare
  v_depth int;
  v_age numeric;
  v_dead int;
  v_ai_err numeric;
  v_pub_err int;
  v_alerts text[] := '{}';
  a text;
begin
  select count(*), coalesce(extract(epoch from now() - min(run_after)) / 60, 0) into v_depth, v_age
  from jobs where status in ('queued', 'failed') and run_after <= now();
  select count(*) into v_dead from jobs where status = 'dead' and finished_at > now() - interval '1 hour';
  select coalesce(count(*) filter (where status <> 'ok')::numeric / nullif(count(*), 0), 0) into v_ai_err
  from ai_usage where at > now() - interval '1 hour' and status <> 'budget';
  select count(*) into v_pub_err from publish_attempts where outcome in ('failed', 'unknown') and started_at > now() - interval '1 hour';
  if v_depth > coalesce(setting_num('health.queue_depth_alert'), 300) then v_alerts := v_alerts || ('queue depth ' || v_depth); end if;
  if v_age > coalesce(setting_num('health.queue_age_alert_minutes'), 15) then v_alerts := v_alerts || ('oldest ready job waits ' || round(v_age) || ' min'); end if;
  if v_dead > 0 then v_alerts := v_alerts || (v_dead || ' dead jobs in the last hour'); end if;
  if v_ai_err > coalesce(setting_num('health.error_rate_alert'), 0.25)
     and (select count(*) from ai_usage where at > now() - interval '1 hour') >= 5 then
    v_alerts := v_alerts || ('AI error rate ' || round(v_ai_err * 100) || '%');
  end if;
  if v_pub_err >= 3 then v_alerts := v_alerts || (v_pub_err || ' failed publish attempts in the last hour'); end if;
  foreach a in array v_alerts loop
    if alert_once('health:' || split_part(a, ' ', 1) || split_part(a, ' ', 2), interval '1 hour') then
      perform notify_admins(tpl('admin.health', jsonb_build_object('problem', a)));
    end if;
  end loop;
  return jsonb_build_object('ok', cardinality(v_alerts) = 0, 'alerts', to_jsonb(v_alerts),
                            'heartbeat_url', nullif(setting_text('health.heartbeat_url'), ''),
                            'queue_depth', v_depth, 'dead_last_hour', v_dead);
end $$;

-- Housekeeping: expired guest brands and guest data (privacy), sessions, tokens. Returns S3 keys to delete.
create or replace function housekeeping() returns jsonb
language plpgsql as $$
declare
  v_ttl interval := make_interval(days => coalesce(setting_num('guest.data_ttl_days'), 7)::int);
  v_ids bigint[];
  v_keys jsonb;
begin
  -- files of expired guest data and temporary brands (collected first: deleting materials nulls assets.material_id)
  select coalesce(array_agg(a.id), '{}'), coalesce(jsonb_agg(a.s3_key), '[]') into v_ids, v_keys
  from assets a
  where a.material_id in (select id from materials where is_guest and created_at < now() - v_ttl)
     or a.brand_id in (select id from brands where is_temporary and expires_at < now());
  delete from materials where is_guest and created_at < now() - v_ttl;
  update users set guest_brand_id = null where guest_brand_id in (select id from brands where is_temporary and expires_at < now());
  delete from brands where is_temporary and expires_at < now();
  delete from assets where id = any (v_ids);
  delete from bot_sessions where expires_at < now();
  delete from panel_login_tokens where expires_at < now() - interval '1 day';
  delete from web_sessions where expires_at < now();
  delete from outbox where status in ('sent', 'merged', 'cancelled') and created_at < now() - interval '30 days';
  delete from inbound_events where status in ('processed', 'ignored') and received_at < now() - interval '90 days'
    and not exists (select 1 from material_parts where inbound_event_id = inbound_events.id);
  return jsonb_build_object('s3_keys', v_keys, 'bucket', setting_text('s3.bucket'));
end $$;

-- CORE · Error handler: every failed execution is stored; admins get one alert per workflow per 15 minutes (AD-5).
create or replace function workflow_error_log(p jsonb) returns void
language plpgsql as $$
declare
  v_wf text := coalesce(p #>> '{workflow,id}', '?');
  v_msg text := left(coalesce(p #>> '{execution,error,message}', p #>> '{trigger,error,message}', 'unknown error'), 2000);
begin
  insert into workflow_errors (workflow_id, workflow_name, execution_id, node, message, data)
  values (v_wf, p #>> '{workflow,name}', p #>> '{execution,id}', coalesce(p #>> '{execution,lastNodeExecuted}', p #>> '{execution,error,node,name}'),
          v_msg, jsonb_strip_nulls(jsonb_build_object('url', p #>> '{execution,url}', 'mode', p #>> '{execution,mode}')));
  if alert_once('wf_error:' || v_wf, interval '15 minutes') then
    perform notify_admins(tpl('admin.workflow_error', jsonb_build_object('workflow', coalesce(p #>> '{workflow,name}', v_wf),
      'node', coalesce(p #>> '{execution,lastNodeExecuted}', '?'), 'error', ellipsis(v_msg, 400), 'execution', coalesce(p #>> '{execution,id}', '?'))));
  end if;
end $$;

-- Called every minute by CORE · Cron: enqueue due periodic jobs (dedupe keys make it idempotent).
create or replace function cron_tick() returns jsonb
language plpgsql as $$
declare
  b record;
  v_local timestamp;
begin
  -- health every 5 minutes
  perform enqueue_job('health.check', '{}', p_dedupe => 'health:' || to_char(date_trunc('hour', now()) + floor(extract(minute from now()) / 5) * interval '5 min', 'YYYYMMDDHH24MI'));
  -- housekeeping daily
  if extract(hour from now() at time zone 'UTC') = 3 then
    perform enqueue_job('housekeeping', '{}', p_dedupe => 'housekeeping:' || to_char(now(), 'YYYYMMDD'));
  end if;
  -- new month: budget-blocked jobs get another chance (they re-check the budget)
  if alert_once('month_unblock:' || to_char(now(), 'YYYY-MM'), interval '40 days') then
    perform unblock_jobs('budget_exceeded%');
  end if;
  for b in select br.* from brands br where br.status = 'active' and not br.is_temporary loop
    v_local := now() at time zone b.timezone;
    -- digest planning (idempotent)
    if (email_platform(b.id)).id is not null and not exists (select 1 from digest_issues di where di.brand_id = b.id and di.send_at > now()
                                                            and di.status in ('draft', 'pending_approval', 'approved', 'scheduled')) then
      perform digest_plan(b.id);
    end if;
    -- weekly report
    if extract(isodow from v_local) = coalesce(setting_num('report.weekly_dow', b.id), 1)
       and to_char(v_local, 'HH24:MI') >= coalesce(setting_text('report.weekly_time', b.id), '09:00') then
      perform enqueue_job('report.weekly', '{}', null, null, null, b.id, p_dedupe => 'weekly:' || b.id || ':' || to_char(v_local, 'IYYY-IW'));
    end if;
    -- feeds every 6 hours
    if exists (select 1 from feed_sources where brand_id = b.id and is_active) then
      perform enqueue_job('feeds.fetch', '{}', null, null, null, b.id,
                          p_dedupe => 'feeds:' || b.id || ':' || to_char(now(), 'YYYYMMDD') || ':' || floor(extract(hour from now()) / 6));
    end if;
  end loop;
  return job_flags();
end $$;

-- Handlers for job types that are pure SQL (CORE · SQL job).
create or replace function run_sql_job(p_job bigint) returns jsonb
language plpgsql as $$
declare
  j jobs;
begin
  select * into j from jobs where id = p_job;
  case j.type
    when 'tg.update' then return bot_handle_update((j.payload ->> 'event_id')::bigint);
    when 'material.seal' then perform material_seal(j.material_id); return job_flags();
    when 'material.clarify_timeout' then
      if exists (select 1 from materials m where m.id = j.material_id and m.status = 'awaiting_author'
                 and m.question ->> 'type' = 'clarify' and m.revision = (j.payload ->> 'revision')::int) then
        update materials set low_data = true where id = j.material_id;
        perform close_question(j.material_id);
        perform enqueue_job('material.route', '{}', j.material_id, p_dedupe => 'route:' || j.material_id || ':' || (j.payload ->> 'revision') || ':timeout');
      end if;
      return job_flags();
    when 'package.card' then return package_card(j.package_id);
    when 'card.refresh' then return card_refresh(j.package_id);
    when 'variant.deadline' then return variant_deadline(j.variant_id, j.payload);
    when 'digest.plan' then return digest_plan(j.brand_id);
    when 'digest.deadline' then return digest_deadline((j.payload ->> 'issue_id')::bigint);
    when 'report.weekly' then return weekly_report(j.brand_id);
    when 'eval.finalize' then return eval_finalize((j.payload ->> 'run_id')::bigint);
    else raise exception 'fatal: job type % is not a SQL job', j.type;
  end case;
end $$;
