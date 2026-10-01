-- Core mechanics: templates coverage, status guard, audit immutability, job queue (dedupe, coalesce, leases, errors).
begin;
set local role app_n8n;

-- every literal tpl('key') used by SQL code exists (templates/bot.en.json is synced)
do $$
declare
  missing text;
begin
  select string_agg(distinct k, ', ') into missing
  from (select m[1] as k from pg_proc p join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public',
        regexp_matches(p.prosrc, 'tpl\(''([a-z0-9_.]+)''', 'g') m) s
  where k !~ '\.$' and not exists (select 1 from templates where key = k);
  perform t.ok(missing is null, 'templates missing: ' || coalesce(missing, ''));
end $$;

-- statuses change only via transition(), illegal transitions raise
do $$
declare
  b bigint := t.brand('core-brand');
  u bigint := t.user(1001, b, 'author');
  m bigint;
begin
  insert into materials (author_user_id, source) values (u, 'telegram') returning id into m;
  begin
    update materials set status = 'routed' where id = m;
    raise exception 'guard did not fire';
  exception when raise_exception then
    perform t.ok(sqlerrm like '%only via transition%', 'status guard: ' || sqlerrm);
  end;
  begin
    perform transition('material', m, 'routed');
    raise exception 'illegal transition allowed';
  exception when raise_exception then
    perform t.ok(sqlerrm like 'illegal transition%', 'illegal transition: ' || sqlerrm);
  end;
  perform transition('material', m, 'parsed', u);
  perform t.eq(transition('material', m, 'parsed', u), 'parsed', 'same status is a no-op');
  perform t.eq((select count(*) from audit_log where entity = 'material' and entity_id = m and action = 'status')::int, 1, 'one audit row per change');
end $$;

-- audit is append-only for the n8n role (grants) and for the owner (trigger)
do $$
begin
  begin
    update audit_log set action = 'x';
    raise exception 'audit update allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from audit_log;
    raise exception 'audit delete allowed';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set local role app_owner;
do $$
begin
  update audit_log set action = 'x';
  raise exception 'audit trigger did not fire';
exception when raise_exception then
  perform t.ok(sqlerrm = 'audit_log is append-only', 'audit trigger: ' || sqlerrm);
end $$;
reset role;
set local role app_n8n;

-- job queue
do $$
declare
  j1 bigint;
  j2 bigint;
  r record;
  n int;
begin
  j1 := enqueue_job('health.check', '{}', p_dedupe => 'dedupe-1');
  perform t.ok(j1 is not null, 'enqueue');
  perform t.eq(enqueue_job('health.check', '{}', p_dedupe => 'dedupe-1'), null::bigint, 'dedupe');
  perform t.ok(enqueue_job('feeds.fetch', '{}', p_coalesce => 'co-1') is not null, 'coalesce first');
  perform t.eq(enqueue_job('feeds.fetch', '{}', p_coalesce => 'co-1'), null::bigint, 'coalesce second while pending');
  begin
    perform enqueue_job('no.such.type');
    raise exception 'unknown type accepted';
  exception when raise_exception then
    perform t.ok(sqlerrm like 'unknown job type%', 'unknown job type');
  end;

  -- per-type concurrency: health.check max_concurrency = 1
  j2 := enqueue_job('health.check', '{}', p_dedupe => 'dedupe-2');
  select count(*) into n from claim_jobs(10) c where c.type = 'health.check';
  perform t.eq(n, 1, 'one running health.check');
  perform t.eq((select count(*) from claim_jobs(10) c where c.type = 'health.check')::int, 0, 'second waits while first runs');

  -- retryable error -> failed with backoff; fatal -> dead; budget -> blocked (attempt not counted)
  select id into j1 from jobs where type = 'health.check' and status = 'running';
  perform job_failed(j1, 'fatal: broken');
  perform t.eq((select status from jobs where id = j1), 'dead', 'fatal -> dead');

  j2 := enqueue_job('report.weekly', '{}', p_dedupe => 'rw-1');
  perform t.ok(exists (select 1 from claim_jobs(10) c where c.id = j2), 'claimed report');
  perform job_failed(j2, 'provider_unavailable: 503');
  select * into r from jobs where id = j2;
  perform t.eq(r.status, 'failed', 'retryable -> failed');
  perform t.ok(r.run_after > now(), 'backoff in the future');

  j1 := enqueue_job('variant.generate', '{}', p_dedupe => 'gen-x');
  perform t.ok(exists (select 1 from claim_jobs(10) c where c.id = j1), 'claimed generate');
  perform job_failed(j1, 'budget_exceeded:brand:1: spent $5.00 of $5.00');
  select * into r from jobs where id = j1;
  perform t.eq(r.status, 'blocked', 'budget -> blocked');
  perform t.eq(r.attempts, 0, 'blocked attempt not counted');
  perform t.eq(unblock_jobs('budget_exceeded:brand:1%'), 1, 'unblock by account');
  perform t.eq((select status from jobs where id = j1), 'queued', 'unblocked -> queued');

  -- expired lease: the job is recovered as failed and claimed again (crash mid-step)
  perform t.ok(exists (select 1 from claim_jobs(10) c where c.id = j1), 'claimed again');
  update jobs set locked_until = now() - interval '1 second' where id = j1;
  perform t.ok(exists (select 1 from claim_jobs(10) c where c.id = j1), 'recovered after lease expiry');
  perform t.eq((select attempts from jobs where id = j1), 2, 'attempts counted');
  perform job_done(j1, '{"ok": true}');
  perform t.eq((select status from jobs where id = j1), 'done', 'done');
  perform job_failed(j1, 'late error');
  perform t.eq((select status from jobs where id = j1), 'done', 'late failure ignored for done job');
end $$;

rollback;
