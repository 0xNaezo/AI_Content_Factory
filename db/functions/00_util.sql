-- Utilities: settings, templates, audit, status transitions, formatting, Telegram keyboard helpers.

create or replace function setting(p_key text, p_brand bigint default null) returns jsonb
language sql stable as $$
  select value from settings
  where key = p_key and (brand_id = p_brand or brand_id is null)
  order by brand_id nulls last
  limit 1
$$;

create or replace function setting_num(p_key text, p_brand bigint default null) returns numeric
language sql stable as $$ select (setting(p_key, p_brand) #>> '{}')::numeric $$;

create or replace function setting_text(p_key text, p_brand bigint default null) returns text
language sql stable as $$ select setting(p_key, p_brand) #>> '{}' $$;

-- HTML escape for Telegram parse_mode=HTML and emails.
create or replace function h(p text) returns text
language sql immutable as $$
  select replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
$$;

-- Cut to n characters with an ellipsis (apply before escaping so HTML stays valid).
create or replace function ellipsis(p text, n int) returns text
language sql immutable as $$
  select case when p is null then '' when char_length(p) <= n then p else left(p, greatest(n - 1, 0)) || '…' end
$$;

-- Render a user-facing template (templates/*.json). {{var}} is HTML-escaped, {{{var}}} is inserted raw.
create or replace function tpl(p_key text, p_vars jsonb default '{}') returns text
language plpgsql stable as $$
declare
  v_body text;
  k text;
  v jsonb;
begin
  select body into v_body from templates where key = p_key;
  if v_body is null then
    return '[' || p_key || ']';
  end if;
  for k, v in select * from jsonb_each(coalesce(p_vars, '{}')) loop
    v_body := replace(v_body, '{{{' || k || '}}}', coalesce(v #>> '{}', ''));
    v_body := replace(v_body, '{{' || k || '}}', h(coalesce(v #>> '{}', '')));
  end loop;
  return v_body;
end $$;

create or replace function audit(p_actor bigint, p_action text, p_entity text, p_entity_id bigint,
                                 p_brand bigint default null, p_material bigint default null,
                                 p_data jsonb default '{}') returns void
language sql as $$
  insert into audit_log (actor_user_id, action, entity, entity_id, brand_id, material_id, data)
  values (p_actor, p_action, p_entity, p_entity_id, p_brand, p_material, coalesce(p_data, '{}'));
$$;

-- The single point where statuses change (architecture 2.1 #5). Idempotent: same status = no-op.
create or replace function transition(p_entity text, p_id bigint, p_to text, p_actor bigint default null,
                                      p_reason text default null, p_data jsonb default '{}') returns text
language plpgsql as $$
declare
  v_from text;
  v_brand bigint;
  v_material bigint;
  v_table text;
begin
  case p_entity
    when 'material' then
      v_table := 'materials';
      select status, id into v_from, v_material from materials where id = p_id for update;
    when 'variant' then
      v_table := 'variants';
      select v.status, p.brand_id, p.material_id into v_from, v_brand, v_material
      from variants v join packages p on p.id = v.package_id where v.id = p_id for update of v;
    when 'digest_issue' then
      v_table := 'digest_issues';
      select status, brand_id into v_from, v_brand from digest_issues where id = p_id for update;
    else
      raise exception 'unknown entity %', p_entity;
  end case;
  if v_from is null then
    raise exception '% % not found', p_entity, p_id;
  end if;
  if v_from = p_to then
    return v_from;
  end if;
  if not exists (select 1 from status_graph where entity = p_entity and from_status = v_from and to_status = p_to) then
    raise exception 'illegal transition % %: % -> %', p_entity, p_id, v_from, p_to using errcode = 'P0001';
  end if;
  perform set_config('app.transition', 'on', true);
  execute format('update %I set status = $1, status_changed_at = now() where id = $2', v_table) using p_to, p_id;
  perform set_config('app.transition', 'off', true);
  perform audit(p_actor, 'status', p_entity, p_id, v_brand, v_material,
                jsonb_build_object('from', v_from, 'to', p_to) || case when p_reason is null then '{}'::jsonb else jsonb_build_object('reason', p_reason) end || coalesce(p_data, '{}'));
  return v_from;
end $$;

create or replace function guard_status_change() returns trigger
language plpgsql as $$
begin
  if new.status is distinct from old.status and coalesce(current_setting('app.transition', true), 'off') <> 'on' then
    raise exception '%.status changes only via transition()', tg_table_name;
  end if;
  return new;
end $$;

drop trigger if exists materials_status_guard on materials;
create trigger materials_status_guard before update of status on materials for each row execute function guard_status_change();
drop trigger if exists variants_status_guard on variants;
create trigger variants_status_guard before update of status on variants for each row execute function guard_status_change();
drop trigger if exists digest_issues_status_guard on digest_issues;
create trigger digest_issues_status_guard before update of status on digest_issues for each row execute function guard_status_change();

-- Formatting helpers for user-facing texts.
create or replace function mcode(p_material bigint) returns text language sql immutable as $$ select 'M-' || p_material $$;

create or replace function fmt_local(p_at timestamptz, p_tz text) returns text
language sql stable as $$ select to_char(p_at at time zone coalesce(p_tz, 'UTC'), 'Dy DD Mon HH24:MI') $$;

create or replace function fmt_usd(p numeric) returns text
language sql immutable as $$ select '$' || to_char(coalesce(p, 0), 'FM999990.00') $$;

create or replace function fmt_duration(p_seconds int) returns text
language sql immutable as $$ select (coalesce(p_seconds, 0) / 60) || ':' || lpad((coalesce(p_seconds, 0) % 60)::text, 2, '0') $$;

create or replace function fmt_bytes(p bigint) returns text
language sql immutable as $$
  select case when coalesce(p, 0) < 1048576 then round(coalesce(p, 0) / 1024.0) || ' KB'
              else to_char(p / 1048576.0, 'FM9990.0') || ' MB' end
$$;

create or replace function platform_label(p text) returns text
language sql stable as $$ select coalesce((select spec->>'label' from platform_formats where platform = p), initcap(p)) $$;

-- Telegram inline keyboard helpers: kb(row, row...) where row = jsonb array of buttons.
create or replace function btn(p_text text, p_data text) returns jsonb
language sql immutable as $$ select jsonb_build_object('text', p_text, 'callback_data', p_data) $$;

create or replace function btn_url(p_text text, p_url text) returns jsonb
language sql immutable as $$ select jsonb_build_object('text', p_text, 'url', p_url) $$;

create or replace function kb(variadic p_rows jsonb[]) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(r), '[]'::jsonb) from unnest(p_rows) r where r is not null and jsonb_array_length(r) > 0
$$;

-- A keyboard row from buttons, skipping nulls (conditional buttons).
create or replace function btn_row(variadic p_buttons jsonb[]) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(b), '[]'::jsonb) from unnest(p_buttons) b where b is not null and b <> 'null'::jsonb
$$;

-- Split a list of buttons into rows of n.
create or replace function kb_grid(p_buttons jsonb, n int) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(row_btns order by grp), '[]'::jsonb)
  from (
    select (ord - 1) / n as grp, jsonb_agg(b order by ord) as row_btns
    from jsonb_array_elements(coalesce(p_buttons, '[]')) with ordinality as t(b, ord)
    group by (ord - 1) / n
  ) s
$$;

create or replace function public_web_url() returns text
language sql stable as $$ select rtrim(coalesce(setting_text('web.public_url'), 'http://localhost:3001'), '/') $$;

-- Telegram rejects non-https URL buttons (and localhost), so URL buttons are shown only for public https hosts.
create or replace function url_button_ok(p_url text) returns boolean
language sql immutable as $$ select p_url ~ '^https://' and p_url !~ '^https://(localhost|127\.)' $$;

create or replace function alert_once(p_key text, p_period interval) returns boolean
language plpgsql as $$
begin
  insert into alert_log (key, sent_at) values (p_key, now())
  on conflict (key) do update set sent_at = now() where alert_log.sent_at < now() - p_period;
  return found;
end $$;
