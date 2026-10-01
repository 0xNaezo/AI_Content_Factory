-- Job queue in Postgres (architecture 4.2): enqueue, claim with leases, done/failed, budget blocking.

create or replace function enqueue_job(p_type text, p_payload jsonb default '{}', p_material bigint default null,
                                       p_package bigint default null, p_variant bigint default null,
                                       p_brand bigint default null, p_dedupe text default null,
                                       p_run_after timestamptz default null, p_priority int default 0,
                                       p_coalesce text default null) returns bigint
language plpgsql as $$
declare
  v_id bigint;
  v_max int;
begin
  select max_attempts into v_max from job_types where type = p_type;
  if v_max is null then
    raise exception 'unknown job type %', p_type;
  end if;
  -- bulk work (table rows, eval runs, guests) yields to live materials: GN-7 latency holds during a 500-row table
  if p_material is not null then
    p_priority := p_priority - coalesce((select case when m.source = 'table_row' or m.is_eval then 10 when m.is_guest then 5 else 0 end
                                         from materials m where m.id = p_material), 0);
  end if;
  insert into jobs (type, payload, material_id, package_id, variant_id, brand_id, dedupe_key, coalesce_key,
                    run_after, priority, max_attempts)
  values (p_type, coalesce(p_payload, '{}'), p_material, p_package, p_variant, p_brand, p_dedupe, p_coalesce,
          coalesce(p_run_after, now()), p_priority, v_max)
  on conflict do nothing
  returning id into v_id;
  return v_id;  -- null = already enqueued (dedupe/coalesce)
end $$;

-- Claim ready jobs honoring global and per-type concurrency. Expired leases are recovered first
-- ("interrupted processing resumes where it failed", tz section 8).
create or replace function claim_jobs(p_limit int default 10)
returns table (id bigint, type text, workflow_id text, payload jsonb, material_id bigint, package_id bigint,
               variant_id bigint, brand_id bigint, attempts int)
language plpgsql as $$
declare
  v_max_running int := coalesce(setting_num('jobs.max_running'), 16);
  v_running int;
  v_counts jsonb;
  v_taken int := 0;
  r record;
begin
  update jobs j
     set status = case when j.attempts >= j.max_attempts then 'dead' else 'failed' end,
         last_error = left(coalesce(j.last_error || ' | ', '') || 'lease expired', 2000),
         locked_until = null,
         run_after = now(),
         finished_at = case when j.attempts >= j.max_attempts then now() end
   where j.status = 'running' and j.locked_until < now();

  select count(*) into v_running from jobs j where j.status = 'running';
  if v_running >= v_max_running then
    return;
  end if;
  select coalesce(jsonb_object_agg(s.type, s.n), '{}') into v_counts
  from (select j.type, count(*) as n from jobs j where j.status = 'running' group by j.type) s;

  for r in
    select j.id as job_id, j.type as job_type, t.max_concurrency, t.lease_seconds
    from jobs j join job_types t on t.type = j.type
    where j.status in ('queued', 'failed') and j.run_after <= now()
    order by j.priority desc, j.run_after, j.id
    limit greatest(p_limit * 5, 50)
    for update of j skip locked
  loop
    exit when v_taken >= p_limit or v_running + v_taken >= v_max_running;
    continue when coalesce((v_counts ->> r.job_type)::int, 0) >= r.max_concurrency;
    v_counts := jsonb_set(v_counts, array[r.job_type], to_jsonb(coalesce((v_counts ->> r.job_type)::int, 0) + 1));
    v_taken := v_taken + 1;
    return query
      update jobs j
         set status = 'running', attempts = j.attempts + 1, started_at = now(),
             locked_until = now() + make_interval(secs => r.lease_seconds)
       where j.id = r.job_id
      returning j.id, j.type, (select t.workflow_id from job_types t where t.type = j.type),
                j.payload, j.material_id, j.package_id, j.variant_id, j.brand_id, j.attempts;
  end loop;
end $$;

-- Result flags tell the runner whether to trigger the dispatcher / outbox sender right away (fast path).
create or replace function job_flags() returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'dispatch', exists (select 1 from jobs where status in ('queued', 'failed') and run_after <= now()),
    'outbox', exists (select 1 from outbox where status = 'queued' and send_after <= now()),
    'publish', exists (select 1 from variants where status = 'scheduled' and scheduled_at <= now()))
$$;

create or replace function job_done(p_id bigint, p_result jsonb default null) returns jsonb
language plpgsql as $$
begin
  update jobs set status = 'done', finished_at = now(), locked_until = null,
                  result = case when length(p_result::text) <= 4000 and p_result <> '{}'::jsonb then p_result end
   where id = p_id and status in ('running', 'failed', 'queued');
  return job_flags();
end $$;

-- Error codes (architecture 8.1): budget_exceeded -> blocked; fatal -> dead; everything else -> retry with backoff.
create or replace function job_failed(p_id bigint, p_error text) returns jsonb
language plpgsql as $$
declare
  j jobs;
  t job_types;
  v_code text := coalesce(substring(lower(coalesce(p_error, '')) from '(budget_exceeded|fatal|provider_unavailable):'), '');
  v_delay int;
begin
  select * into j from jobs where id = p_id for update;
  if j.id is null or j.status in ('done', 'cancelled') then
    return job_flags();
  end if;
  select * into t from job_types where type = j.type;
  if v_code = 'budget_exceeded' then
    update jobs set status = 'blocked', blocked_reason = left(p_error, 200), locked_until = null,
                    attempts = greatest(attempts - 1, 0), last_error = left(p_error, 2000)
     where id = p_id;
    perform job_blocked_notice(j, p_error);
  elsif v_code = 'fatal' or j.attempts >= j.max_attempts then
    update jobs set status = 'dead', finished_at = now(), locked_until = null, last_error = left(p_error, 2000) where id = p_id;
  else
    v_delay := least(t.backoff_seconds * power(2, greatest(j.attempts - 1, 0))::int, 3600)
               * case when v_code = 'provider_unavailable' then 3 else 1 end;
    update jobs set status = 'failed', locked_until = null, last_error = left(p_error, 2000),
                    run_after = now() + make_interval(secs => v_delay)
     where id = p_id;
  end if;
  return job_flags();
end $$;

-- Dead jobs are alerted to admins (AD-5); a dead pipeline step also tells the author so nothing is silently lost.
create or replace function jobs_dead_alert() returns trigger
language plpgsql as $$
begin
  if new.status = 'dead' and old.status is distinct from 'dead' then
    if alert_once('job_dead:' || new.type || ':' || coalesce(new.material_id::text, new.id::text), interval '1 hour') then
      perform notify_admins(tpl('admin.job_dead', jsonb_build_object(
        'job', new.id, 'type', new.type, 'material', coalesce(mcode(new.material_id), '—'),
        'error', ellipsis(new.last_error, 500))));
    end if;
    if new.material_id is not null and exists (select 1 from materials m where m.id = new.material_id and m.status in ('received', 'parsed', 'awaiting_author'))
       and alert_once('material_failed:' || new.material_id, interval '1 day') then
      perform author_notify(new.material_id, tpl('material.failed', jsonb_build_object('material', mcode(new.material_id))), null,
                            'material_failed:' || new.material_id);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists jobs_dead_alert on jobs;
create trigger jobs_dead_alert after update of status on jobs for each row execute function jobs_dead_alert();

-- Tell the author once per material that generation waits for budget (AD-4: intake continues, materials queue).
create or replace function job_blocked_notice(j jobs, p_error text) returns void
language plpgsql as $$
declare
  m materials;
begin
  if j.material_id is null then
    return;
  end if;
  select * into m from materials where id = j.material_id;
  if m.chat_id is not null and alert_once('blocked_notice:' || m.id, interval '30 days') then
    perform tg_send_chat(m.chat_id, tpl('material.budget_blocked', jsonb_build_object('material', mcode(m.id))), null,
                         'blocked:' || m.id, m.author_user_id, m.id);
  end if;
end $$;

-- Unblock budget-gated jobs (budget raised, new month). p_like: e.g. 'budget_exceeded:brand:5%'.
create or replace function unblock_jobs(p_like text default 'budget_exceeded%') returns int
language plpgsql as $$
declare
  n int;
begin
  update jobs set status = 'queued', run_after = now(), blocked_reason = null
   where status = 'blocked' and blocked_reason like p_like;
  get diagnostics n = row_count;
  return n;
end $$;

-- Manual retry of a dead job (admin command /retry).
create or replace function job_retry(p_id bigint) returns boolean
language plpgsql as $$
begin
  update jobs set status = 'queued', attempts = 0, run_after = now(), locked_until = null, finished_at = null
   where id = p_id and status in ('dead', 'failed', 'blocked');
  return found;
end $$;
