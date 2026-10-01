-- AI gateway data side (architecture 8.1, 7.13): route config, budget check before the call, usage/cost after it.

create or replace function budget_limit(p_account text, p_brand bigint) returns numeric
language sql stable as $$
  select case p_account
    when 'brand' then (select monthly_budget_usd from brands where id = p_brand)
    when 'guest' then setting_num('guest.monthly_budget_usd')
    when 'eval' then setting_num('eval.monthly_budget_usd')
    else setting_num('system.monthly_budget_usd') end
$$;

create or replace function budget_spent(p_account text, p_brand bigint) returns numeric
language sql stable as $$
  select coalesce(sum(cost_usd), 0) from ai_usage
  where account_type = p_account and (p_account <> 'brand' or brand_id = p_brand)
    and at >= date_trunc('month', now())
$$;

-- Route + prompt + schema + budget verdict in one call. Blocked calls never reach the provider (AD-4).
create or replace function ai_prepare(p_route text, p_account text, p_brand bigint default null, p_schema text default null) returns jsonb
language plpgsql stable as $$
declare
  r ai_routes;
  v_limit numeric;
  v_spent numeric;
  v_prompt prompts;
  v_schema jsonb;
begin
  select * into r from ai_routes where route = p_route;
  if r.route is null or not r.enabled then
    raise exception 'fatal: unknown or disabled AI route %', p_route;
  end if;
  v_limit := budget_limit(p_account, p_brand);
  v_spent := budget_spent(p_account, p_brand);
  if v_limit is not null and v_spent >= v_limit then
    return jsonb_build_object('blocked', true,
      'error', 'budget_exceeded:' || p_account || ':' || coalesce(p_brand::text, '-') || ': spent ' || fmt_usd(v_spent) || ' of ' || fmt_usd(v_limit));
  end if;
  if r.prompt_route is not null then
    select * into v_prompt from prompts where route = r.prompt_route and is_current;
    if v_prompt.route is null then
      raise exception 'fatal: prompt % is not synced (scripts/sync-config.sh)', r.prompt_route;
    end if;
  end if;
  if coalesce(p_schema, r.schema_name) is not null then
    select schema into v_schema from ai_schemas where name = coalesce(p_schema, r.schema_name);
    if v_schema is null then
      raise exception 'fatal: schema % is not synced', coalesce(p_schema, r.schema_name);
    end if;
  end if;
  return jsonb_build_object(
    'blocked', false, 'route', r.route, 'provider', r.provider, 'kind', r.kind, 'model', r.model, 'params', r.params,
    'template', v_prompt.template, 'prompt_hash', v_prompt.version_hash,
    'schema_name', coalesce(p_schema, r.schema_name), 'schema', v_schema,
    'base_url', rtrim(case r.provider when 'anthropic' then setting_text('api.anthropic_base') else setting_text('api.openrouter_base') end, '/'),
    'bucket', setting_text('s3.bucket'));
end $$;

-- Log every call (ok or not). Anthropic cost from list prices; OpenRouter reports usage.cost itself.
create or replace function ai_record(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_cost numeric := (p ->> 'cost_usd')::numeric;
  v_account text := coalesce(p ->> 'account_type', 'system');
  v_brand bigint := (p ->> 'brand_id')::bigint;
  v_limit numeric;
  v_spent numeric;
  v_month text := to_char(now(), 'YYYY-MM');
  v_key text;
begin
  if v_cost is null and p ->> 'provider' = 'anthropic' then
    select (coalesce((p ->> 'input_tokens')::numeric, 0) * max(usd) filter (where unit = 'mtok_in')
          + coalesce((p ->> 'output_tokens')::numeric, 0) * max(usd) filter (where unit = 'mtok_out')
          + coalesce((p ->> 'cache_write_tokens')::numeric, 0) * max(usd) filter (where unit = 'mtok_cache_write')
          + coalesce((p ->> 'cache_read_tokens')::numeric, 0) * max(usd) filter (where unit = 'mtok_cache_read')) / 1000000
      into v_cost
    from ai_prices where provider = 'anthropic' and model = p ->> 'model';
  end if;
  insert into ai_usage (account_type, brand_id, material_id, package_id, variant_id, job_id, route, provider, model, prompt_hash,
                        status, stop_reason, input_tokens, output_tokens, cache_write_tokens, cache_read_tokens, units, cost_usd,
                        latency_ms, error)
  values (v_account, case when v_account = 'brand' then v_brand end, (p ->> 'material_id')::bigint, (p ->> 'package_id')::bigint,
          (p ->> 'variant_id')::bigint, (p ->> 'job_id')::bigint, p ->> 'route', coalesce(p ->> 'provider', '?'), coalesce(p ->> 'model', '?'),
          p ->> 'prompt_hash', coalesce(p ->> 'status', 'ok'), p ->> 'stop_reason',
          coalesce((p ->> 'input_tokens')::int, 0), coalesce((p ->> 'output_tokens')::int, 0),
          coalesce((p ->> 'cache_write_tokens')::int, 0), coalesce((p ->> 'cache_read_tokens')::int, 0),
          coalesce(p -> 'units', '{}'), coalesce(v_cost, 0), (p ->> 'latency_ms')::int, left(p ->> 'error', 2000));

  -- AD-4 thresholds: one notice per account per month for 80% and for 100%
  v_limit := budget_limit(v_account, v_brand);
  v_spent := budget_spent(v_account, v_brand);
  if v_limit > 0 and v_spent >= v_limit * coalesce(setting_num('budget.warn_ratio'), 0.8) then
    v_key := case when v_spent >= v_limit then 'budget100:' else 'budget80:' end || v_account || ':' || coalesce(v_brand::text, '-') || ':' || v_month;
    if alert_once(v_key, interval '40 days') then
      perform notify_admins(tpl(case when v_spent >= v_limit then 'budget.exhausted' else 'budget.warning' end,
        jsonb_build_object('account', case when v_account = 'brand' then (select name from brands where id = v_brand) else v_account end,
                           'spent', fmt_usd(v_spent), 'limit', fmt_usd(v_limit))));
      if v_account = 'brand' then
        perform notify_brand(v_brand, array['manager'], tpl(case when v_spent >= v_limit then 'budget.exhausted' else 'budget.warning' end,
          jsonb_build_object('account', (select name from brands where id = v_brand), 'spent', fmt_usd(v_spent), 'limit', fmt_usd(v_limit))));
      end if;
    end if;
  end if;
  return jsonb_build_object('cost_usd', coalesce(v_cost, 0), 'spent', v_spent, 'limit', v_limit);
end $$;
