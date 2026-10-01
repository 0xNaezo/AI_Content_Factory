#!/usr/bin/env bash
# Sync repo-owned config into the DB (idempotent): bot texts, email template, platform formats,
# prompts (with version hash), AI response schemas, eval cases. Run after changing any of them.
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${DB:-app}
sqlv() { # sqlv <sql with :'j'> <json>
  printf '%s\n' "$1" | docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -X -U postgres -d "$DB" \
    -c 'set role app_owner' -v j="$2" -f - >/dev/null
}
sqlv "insert into templates (key, body) select key, value from jsonb_each_text(:'j'::jsonb)
      on conflict (key) do update set body = excluded.body, updated_at = now() where templates.body <> excluded.body;" \
     "$(jq -c 'del(._comment)' templates/bot.en.json)"
sqlv "insert into templates (key, body) values ('email.digest', :'j')
      on conflict (key) do update set body = excluded.body, updated_at = now();" "$(cat templates/email/digest.html)"
sqlv "insert into platform_formats (platform, spec) select key, value from jsonb_each(:'j'::jsonb)
      on conflict (platform) do update set spec = excluded.spec;" "$(jq -c 'del(._comment)' config/platforms.json)"
prompts='{}'
for f in prompts/*.md; do
  [ -e "$f" ] || continue
  prompts=$(jq -c --arg r "$(basename "$f" .md)" --rawfile t "$f" '. + {($r): $t}' <<<"$prompts")
done
sqlv "with p as (select key as route, value as template, encode(digest(value, 'sha256'), 'hex') as h from jsonb_each_text(:'j'::jsonb)),
      ins as (insert into prompts (route, version_hash, template, is_current)
              select route, h, template, false from p on conflict (route, version_hash) do nothing)
      select 1;
      update prompts x set is_current = false where is_current and exists (
        select 1 from jsonb_each_text(:'j'::jsonb) p where p.key = x.route and encode(digest(p.value, 'sha256'), 'hex') <> x.version_hash);
      update prompts x set is_current = true, synced_at = now() where exists (
        select 1 from jsonb_each_text(:'j'::jsonb) p where p.key = x.route and encode(digest(p.value, 'sha256'), 'hex') = x.version_hash);" "$prompts"
schemas=$(jq -n -c --slurpfile p <(for f in prompts/schemas/*.json; do jq -c --arg n "$(basename "$f" .json)" '{($n): .}' "$f"; done) \
  --slurpfile b schemas/brand-profile.schema.json '([$p[]] | add) + {"brand-profile": $b[0]}')
sqlv "insert into ai_schemas (name, schema, version_hash) select key, value, md5(value::text) from jsonb_each(:'j'::jsonb)
      on conflict (name) do update set schema = excluded.schema, version_hash = excluded.version_hash, synced_at = now();" "$schemas"
shopt -s nullglob
case_files=(eval/cases/*.json)
cases='[]'
[ ${#case_files[@]} -gt 0 ] && cases=$(jq -s -c '[.[] | if type == "array" then .[] else . end]' "${case_files[@]}")
sqlv "insert into eval_cases (id, brand_slug, kind, material, expected)
      select c->>'id', c->>'brand', coalesce(c->>'kind', 'generation'), c->'material', coalesce(c->'expected', '{}')
      from jsonb_array_elements(:'j'::jsonb) c
      on conflict (id) do update set brand_slug = excluded.brand_slug, kind = excluded.kind, material = excluded.material,
        expected = excluded.expected, synced_at = now();" "$cases"
echo "config synced: templates, platforms, $(jq 'length' <<<"$prompts") prompts, $(jq 'length' <<<"$schemas") schemas, $(jq 'length' <<<"$cases") eval cases"
