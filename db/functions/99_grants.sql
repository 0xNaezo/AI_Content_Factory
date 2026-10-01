-- Roles (architecture 5.1): app_n8n — business writes without ownership; app_web — read models only.
set client_min_messages = error;

grant usage on schema public to app_n8n;
grant select, insert, update, delete on all tables in schema public to app_n8n;
grant usage, select on all sequences in schema public to app_n8n;
revoke execute on all functions in schema public from public;
grant execute on all functions in schema public to app_n8n;
grant execute on function blog_base_url(bigint), variant_visual(bigint), platform_label(text), publish_target(bigint),
  user_label(bigint), is_paused(bigint), material_parts_summary(bigint) to app_web;
-- audit is append-only for everyone (plus the triggers)
revoke update, delete, truncate on audit_log from app_n8n;
revoke truncate on all tables in schema public from app_n8n;

-- The web role reads only site/panel objects; base tables stay invisible.
revoke all on all tables in schema public from app_web;
grant usage on schema site, panel to app_web;
grant select on all tables in schema site to app_web;
grant select on all tables in schema panel to app_web;
grant execute on all functions in schema site to app_web;
grant execute on all functions in schema panel to app_web;
grant usage on schema site, panel to app_n8n;
grant select on all tables in schema site, panel to app_n8n;
