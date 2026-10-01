-- Access: users from Telegram, roles per brand, permission checks, invites (AD-2), revocation.
-- Every action re-checks memberships from the DB (architecture 2.1 #6); callback data is untrusted input.

create or replace function tg_user_upsert(p_from jsonb, p_chat bigint) returns users
language plpgsql as $$
declare
  u users;
begin
  insert into users (tg_user_id, tg_chat_id, tg_username, display_name, last_seen_at)
  values ((p_from ->> 'id')::bigint, p_chat, p_from ->> 'username',
          trim(coalesce(p_from ->> 'first_name', '') || ' ' || coalesce(p_from ->> 'last_name', '')), now())
  on conflict (tg_user_id) do update set
    tg_chat_id = coalesce(excluded.tg_chat_id, users.tg_chat_id),
    tg_username = excluded.tg_username,
    display_name = excluded.display_name,
    tg_blocked_bot = false,
    last_seen_at = now()
  returning * into u;
  return u;
end $$;

create or replace function user_label(p_user bigint) returns text
language sql stable as $$
  select coalesce('@' || nullif(tg_username, ''), nullif(display_name, ''), 'user ' || id) from users where id = p_user
$$;

-- 'admin' for global admins, the membership role otherwise, null = no access.
create or replace function user_role(p_user bigint, p_brand bigint) returns text
language sql stable as $$
  select case when u.is_admin then 'admin' else m.role end
  from users u left join memberships m on m.user_id = u.id and m.brand_id = p_brand
  where u.id = p_user and u.status = 'active'
$$;

-- Permission matrix (tz section 3).
create or replace function can(p_user bigint, p_brand bigint, p_action text) returns boolean
language sql stable as $$
  select coalesce(user_role(p_user, p_brand) = any (case p_action
    when 'submit'       then array['admin', 'manager', 'editor', 'author']
    when 'approve'      then array['admin', 'manager', 'editor']
    when 'pause'        then array['admin', 'manager', 'editor']
    when 'configure'    then array['admin', 'manager']
    when 'manage_users' then array['admin', 'manager']
    when 'view'         then array['admin', 'manager', 'editor', 'viewer']
    when 'admin'        then array['admin']
    else array[]::text[] end), false)
$$;

-- Brands where the user may submit materials (admins: all active brands).
create or replace function user_submit_brands(p_user bigint)
returns table (brand_id bigint, slug text, name text, role text)
language sql stable as $$
  select b.id, b.slug, b.name, coalesce(m.role, 'admin')
  from brands b
  join users u on u.id = p_user and u.status = 'active'
  left join memberships m on m.user_id = u.id and m.brand_id = b.id
  where b.status = 'active' and not b.is_temporary
    and (u.is_admin or m.role in ('manager', 'editor', 'author'))
  order by b.name
$$;

create or replace function has_any_access(p_user bigint) returns boolean
language sql stable as $$
  select exists (select 1 from users where id = p_user and status = 'active' and is_admin)
      or exists (select 1 from memberships where user_id = p_user)
$$;

create or replace function brand_by_ref(p_ref text) returns brands
language sql stable as $$
  select * from brands where slug = lower(p_ref) or lower(name) = lower(p_ref) order by id limit 1
$$;

-- Invite link (AD-2). Returns the raw token once; only its hash is stored.
create or replace function invite_create(p_actor bigint, p_role text, p_brand_ids bigint[]) returns text
language plpgsql as $$
declare
  v_token text := encode(gen_random_bytes(16), 'hex');
  b bigint;
begin
  if p_role = 'admin' then
    if not can(p_actor, null, 'admin') then
      raise exception 'forbidden: only admins can invite admins';
    end if;
  else
    if p_role not in ('manager', 'editor', 'author', 'viewer') then
      raise exception 'unknown role %', p_role;
    end if;
    if coalesce(cardinality(p_brand_ids), 0) = 0 then
      raise exception 'no brands given';
    end if;
    foreach b in array p_brand_ids loop
      if not can(p_actor, b, 'manage_users') then
        raise exception 'forbidden: you cannot manage users of brand %', b;
      end if;
    end loop;
  end if;
  insert into invites (token_hash, role, brand_ids, created_by, expires_at)
  values (digest(v_token, 'sha256'), p_role, coalesce(p_brand_ids, '{}'), p_actor,
          now() + make_interval(hours => coalesce(setting_num('invite.ttl_hours'), 72)::int));
  perform audit(p_actor, 'invite.created', 'invite', null, p_brand_ids[1], null,
                jsonb_build_object('role', p_role, 'brand_ids', p_brand_ids));
  return v_token;
end $$;

-- First admin (scripts/admin-invite.sh, run by the operator on the database host): an admin invite without an inviter.
create or replace function admin_invite_bootstrap() returns text
language plpgsql as $$
declare
  v_token text := encode(gen_random_bytes(16), 'hex');
begin
  insert into invites (token_hash, role, created_by, expires_at)
  values (digest(v_token, 'sha256'), 'admin', null, now() + make_interval(hours => coalesce(setting_num('invite.ttl_hours'), 72)::int));
  perform audit(null, 'invite.created', 'invite', null, null, null, jsonb_build_object('role', 'admin', 'bootstrap', true));
  return v_token;
end $$;

create or replace function invite_accept(p_user bigint, p_token text) returns jsonb
language plpgsql as $$
declare
  i invites;
  b bigint;
begin
  select * into i from invites where token_hash = digest(p_token, 'sha256') for update;
  if i.id is null or i.used_at is not null or i.revoked_at is not null or i.expires_at < now() then
    return jsonb_build_object('ok', false);
  end if;
  update invites set used_at = now(), used_by = p_user where id = i.id;
  if i.role = 'admin' then
    update users set is_admin = true where id = p_user;
  else
    foreach b in array i.brand_ids loop
      insert into memberships (user_id, brand_id, role, granted_by)
      select p_user, b, i.role, i.created_by where exists (select 1 from brands where id = b)
      on conflict (user_id, brand_id) do update set role = excluded.role, granted_by = excluded.granted_by;
    end loop;
  end if;
  perform audit(p_user, 'invite.accepted', 'invite', i.id, i.brand_ids[1], null,
                jsonb_build_object('role', i.role, 'brand_ids', i.brand_ids));
  return jsonb_build_object('ok', true, 'role', i.role, 'brands',
    (select coalesce(string_agg(name, ', ' order by name), '') from brands where id = any (i.brand_ids)));
end $$;

-- Revocation is immediate: every check reads memberships; open bot sessions and panel sessions are dropped.
create or replace function access_revoke(p_actor bigint, p_target bigint, p_brand bigint) returns boolean
language plpgsql as $$
begin
  if not can(p_actor, p_brand, 'manage_users') then
    raise exception 'forbidden';
  end if;
  delete from memberships where user_id = p_target and brand_id = p_brand;
  if not found then
    return false;
  end if;
  delete from bot_sessions where user_id = p_target;
  if not has_any_access(p_target) then
    delete from web_sessions where user_id = p_target;
  end if;
  perform audit(p_actor, 'access.revoked', 'user', p_target, p_brand, null, '{}');
  return true;
end $$;

create or replace function user_by_ref(p_ref text) returns users
language sql stable as $$
  select * from users
  where lower(tg_username) = lower(ltrim(p_ref, '@'))
     or tg_user_id = case when p_ref ~ '^\d{1,18}$' then p_ref::bigint end
     or id = case when p_ref ~ '^\d{1,18}$' then p_ref::bigint end
  order by id limit 1
$$;
