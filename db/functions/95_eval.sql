-- Measurable quality (tz section 8, architecture 8.6): run the reference set through the real pipeline steps
-- under the eval account; eval materials never get cards or real publications (publish_target -> preview).

create or replace function eval_user() returns bigint
language plpgsql as $$
declare
  v_id bigint;
begin
  select id into v_id from users where is_system and display_name = 'eval-runner';
  if v_id is null then
    insert into users (display_name, is_system) values ('eval-runner', true) returning id into v_id;
  end if;
  return v_id;
end $$;

create or replace function eval_start(p_note text default null, p_kind text default null) returns jsonb
language plpgsql as $$
declare
  v_run bigint;
  c eval_cases;
  v_m bigint;
  v_part bigint;
  v_user bigint := eval_user();
  n int := 0;
begin
  insert into eval_runs (note, config)
  values (p_note, jsonb_build_object(
    'routes', (select jsonb_object_agg(route, jsonb_build_object('model', model, 'params', params)) from ai_routes),
    'prompts', (select jsonb_object_agg(route, version_hash) from prompts where is_current)))
  returning id into v_run;
  for c in select * from eval_cases where p_kind is null or kind = p_kind order by id loop
    insert into materials (author_user_id, source, is_eval, eval_case_id, sealed_at)
    values (v_user, 'eval', true, c.id, now()) returning id into v_m;
    if c.material ? 'url' then
      insert into material_parts (material_id, kind, ord, source_ref, url, input_text)
      values (v_m, 'url', 1, 'eval:url', c.material ->> 'url', c.material ->> 'url') returning id into v_part;
      perform enqueue_job('part.process', jsonb_build_object('part_id', v_part), v_m, p_dedupe => 'part:' || v_part);
    else
      insert into material_parts (material_id, kind, ord, source_ref, input_text, extracted_text, extracted_at)
      values (v_m, 'text', 1, 'eval:text', c.material ->> 'text', c.material ->> 'text', now());
    end if;
    insert into eval_results (run_id, case_id, material_id) values (v_run, c.id, v_m);
    perform material_try_summarize(v_m);
    n := n + 1;
  end loop;
  return jsonb_build_object('run_id', v_run, 'cases', n);
end $$;

-- Called whenever an eval material advances; queues finalization when every case of the run is final.
create or replace function eval_try_finalize(p_material bigint) returns void
language plpgsql as $$
declare
  v_run bigint;
begin
  select run_id into v_run from eval_results where material_id = p_material;
  if v_run is null then
    return;
  end if;
  if not exists (
    select 1 from eval_results r join materials m on m.id = r.material_id
    where r.run_id = v_run and (
      m.status in ('received', 'parsed', 'awaiting_author')
      or exists (select 1 from packages p join variants v on v.package_id = p.id
                 where p.material_id = m.id and v.status in ('draft', 'revising')))) then
    perform enqueue_job('eval.finalize', jsonb_build_object('run_id', v_run), p_dedupe => 'eval_finalize:' || v_run);
  end if;
end $$;

create or replace function eval_finalize(p_run bigint) returns jsonb
language plpgsql as $$
declare
  r record;
  v_metrics jsonb;
  v_run jsonb;
  v_prev jsonb;
begin
  for r in select er.*, c.kind, c.expected, c.brand_slug from eval_results er join eval_cases c on c.id = er.case_id where er.run_id = p_run loop
    if r.kind = 'routing' then
      v_metrics := r.metrics || jsonb_build_object('routing_correct', r.metrics ->> 'routed_to' = coalesce(r.expected ->> 'brand', r.brand_slug));
    else
      select jsonb_build_object(
        'variants', count(v.id),
        'checks_passed', count(v.id) filter (where v.check_status = 'passed'),
        'length_ok', count(v.id) filter (where exists (select 1 from check_results c where c.variant_id = v.id and c.version = v.current_version and c.check_name = 'length' and c.status = 'pass')),
        'unsupported_claims', coalesce(sum((select jsonb_array_length(coalesce(c.details -> 'unsupported', '[]')) from check_results c
                                            where c.variant_id = v.id and c.version = v.current_version and c.check_name = 'facts')), 0),
        'forbidden_claims_found', coalesce(sum((select count(*) from jsonb_array_elements_text(coalesce(r.expected -> 'forbidden_claims', '[]')) fc
                                                where position(lower(fc) in lower(vv.plain_text)) > 0)), 0),
        'expected_facts_covered', coalesce(sum((select count(*) from jsonb_array_elements_text(coalesce(r.expected -> 'facts', '[]')) ef
                                                where position(lower(ef) in lower(vv.plain_text)) > 0)), 0),
        'fix_attempts', coalesce(sum(v.fix_attempts), 0),
        'cost_usd', (select coalesce(sum(cost_usd), 0) from ai_usage a where a.material_id = r.material_id),
        'seconds', extract(epoch from max(vv.created_at) - min(m.created_at)))
      into v_metrics
      from materials m
      left join packages p on p.material_id = m.id
      left join variants v on v.package_id = p.id
      left join variant_versions vv on vv.variant_id = v.id and vv.version = v.current_version
      where m.id = r.material_id;
    end if;
    update eval_results set metrics = coalesce(v_metrics, '{}') where run_id = p_run and case_id = r.case_id;
  end loop;

  select jsonb_build_object(
    'cases', count(*),
    'variants', sum((metrics ->> 'variants')::int),
    'checks_pass_rate', round(sum((metrics ->> 'checks_passed')::numeric) / nullif(sum((metrics ->> 'variants')::numeric), 0), 3),
    'length_ok_rate', round(sum((metrics ->> 'length_ok')::numeric) / nullif(sum((metrics ->> 'variants')::numeric), 0), 3),
    'unsupported_claims', sum((metrics ->> 'unsupported_claims')::int),
    'forbidden_claims_found', sum((metrics ->> 'forbidden_claims_found')::int),
    'routing_accuracy', round(avg(case when metrics ? 'routing_correct' then (metrics ->> 'routing_correct')::boolean::int end), 3),
    'cost_usd', round(sum(coalesce((metrics ->> 'cost_usd')::numeric, 0)), 4),
    'avg_seconds', round(avg((metrics ->> 'seconds')::numeric)))
  into v_run from eval_results where run_id = p_run;
  select metrics into v_prev from eval_runs where id < p_run and status = 'done' order by id desc limit 1;
  update eval_runs set metrics = v_run || jsonb_build_object('previous', v_prev), status = 'done', finished_at = now() where id = p_run;
  perform notify_admins(tpl('eval.done', jsonb_build_object('run', p_run, 'metrics', v_run::text, 'previous', coalesce(v_prev::text, '—'))));
  return job_flags();
end $$;
