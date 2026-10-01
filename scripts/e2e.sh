#!/usr/bin/env bash
# End-to-end run of the real n8n workflows with the stub service in place of Telegram, Anthropic, OpenRouter and Resend.
# Runs in the dev database with e2e-only brands and users (tg ids 9000xx, removed at the end); the API base URLs are
# switched to the stub for the run and restored afterwards. Requires: n8n workflows imported (scripts/n8n-import.sh),
# prompts synced (scripts/sync-config.sh).
# Usage: scripts/e2e.sh [text voice image email retry pause profile onboarding digest guest eval stranger table]
# (default: all but table). KEEP=1 leaves the data and stub settings for debugging.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
N8N=http://localhost:5679
STUB=http://127.0.0.1:3902
ERR0=0
KEYS="'api.telegram_base','api.telegram_file_base','api.anthropic_base','api.openrouter_base','api.resend_base'"

sql() { docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -X -tA -U postgres -d app -c 'set role app_owner' -c "$1"; }
pass() { echo "  ok    $1"; }
fail() {
  echo "  FAIL  $1"
  sql "select j.id || ' ' || j.type || ' ' || j.status || ' attempts=' || j.attempts || ' ' || coalesce(left(j.last_error, 300), '')
       from jobs j where j.created_at > now() - interval '15 minutes' and j.status not in ('done', 'cancelled') order by j.id" | sed 's/^/        /'
  sql "select 'wf error: ' || coalesce(workflow_name, workflow_id) || ' / ' || coalesce(node, '?') || ': ' || left(message, 300)
       from workflow_errors where id > $ERR0 order by id" | sed 's/^/        /'
  exit 1
}
wait_for() {  # wait_for "<sql returning t|f>" "<what>" [seconds]
  for i in $(seq 1 "${3:-120}"); do
    [ "$(sql "$1")" = "t" ] && { pass "$2 (${i}s)"; return 0; }
    sleep 1
  done
  fail "$2"
}
stub_wait() {  # stub_wait "<python condition on call c>" "<what>" [seconds]: wait for a matching call in the stub's log
  for i in $(seq 1 "${3:-60}"); do
    curl -s "$STUB/calls" | python3 -c "import json, sys; sys.exit(0 if any($1 for c in json.load(sys.stdin)['calls']) else 1)" \
      && { pass "$2 (${i}s)"; return 0; }
    sleep 1
  done
  fail "$2"
}
UPD=$(( $(date +%s) * 10 ))
tg_post() { curl -s -o /dev/null -w '%{http_code}' -X POST "$N8N/webhook/tg" -H 'content-type: application/json' \
  -H "X-Telegram-Bot-Api-Secret-Token: $TELEGRAM_WEBHOOK_SECRET" -d "$1"; }
msg() {  # msg <tg id> <json fields of the message>  -> $U (no subshell: the update counter must advance)
  UPD=$((UPD + 1))
  U="{\"update_id\": $UPD, \"message\": {\"message_id\": $UPD, \"date\": $(date +%s), \"chat\": {\"id\": $1, \"type\": \"private\"},
    \"from\": {\"id\": $1, \"is_bot\": false, \"first_name\": \"E2E\", \"username\": \"e2e_$1\"}, $2}}"
}
cb() {  # cb <tg id> <callback data>
  UPD=$((UPD + 1))
  tg_post "{\"update_id\": $UPD, \"callback_query\": {\"id\": \"e2e$UPD\", \"data\": \"$2\", \"chat_instance\": \"1\",
    \"from\": {\"id\": $1, \"is_bot\": false, \"first_name\": \"E2E\"}, \"message\": {\"message_id\": 1, \"chat\": {\"id\": $1, \"type\": \"private\"}}}}" >/dev/null
}
cleanup() {
  sql "delete from jobs where dedupe_key like 'email_fetch:att-e2e-%';
       delete from jobs where type = 'tg.update' and (payload ->> 'event_id')::bigint in (select id from inbound_events where
         coalesce(payload #>> '{message,from,id}', payload #>> '{callback_query,from,id}') like '9000%' or external_key like 'e2e-%');
       delete from inbound_events where coalesce(payload #>> '{message,from,id}', payload #>> '{callback_query,from,id}') like '9000%' or external_key like 'e2e-%';
       create temp table e2e_m as select id from materials where author_user_id in (select id from users where tg_user_id between 900000 and 900099)
         or id in (select r.material_id from eval_results r join eval_runs e on e.id = r.run_id
                   where e.note in (select 'bot: ' || id from users where tg_user_id between 900000 and 900099));
       delete from eval_runs where note in (select 'bot: ' || id from users where tg_user_id between 900000 and 900099);
       delete from ai_usage where material_id in (select id from e2e_m);
       delete from materials where id in (select id from e2e_m);
       delete from outbox where chat_id between 900000 and 900099 or email_to like '%@e2e.test';
       delete from system_pauses where paused_by in (select id from users where tg_user_id between 900000 and 900099);
       delete from brands where slug like 'e2e-%' or (is_temporary and owner_user_id in (select id from users where tg_user_id between 900000 and 900099));
       delete from users where tg_user_id between 900000 and 900099;" >/dev/null
}

echo "e2e: setup"
docker compose --profile test up -d stub >/dev/null 2>&1
for i in $(seq 1 30); do curl -sf "$STUB/health" >/dev/null && break; sleep 1; done
curl -sf -X POST "$STUB/reset" >/dev/null
cleanup
# the real API bases are kept in a file while the stub is active, so a KEEP=1 run cannot make the stub "the original"
SAVED_FILE=.e2e-api-settings.json
CUR=$(sql "select jsonb_object_agg(key, value) from settings where key in ($KEYS) and brand_id is null")
if [[ "$CUR" == *stub:3000* ]]; then
  [ -f "$SAVED_FILE" ] || { echo "e2e: API settings point at the stub and $SAVED_FILE is missing: reset the api.* settings first" >&2; exit 1; }
  SAVED=$(cat "$SAVED_FILE")
else
  SAVED=$CUR
  printf '%s' "$SAVED" > "$SAVED_FILE"
fi
restore() {
  if [ -n "${KEEP:-}" ]; then echo "e2e: KEEP set: stub settings and e2e data left in place (the next run restores and cleans up)"; return; fi
  sql "update settings s set value = x.value from jsonb_each('$SAVED'::jsonb) x where s.key = x.key and s.brand_id is null" >/dev/null
  rm -f "$SAVED_FILE"
  cleanup
  echo "e2e: settings restored, e2e data removed"
}
trap restore EXIT
sql "update settings set value = to_jsonb('http://stub:3000/' || case key when 'api.telegram_base' then 'tg' when 'api.telegram_file_base' then 'tgfile'
       when 'api.anthropic_base' then 'anthropic' when 'api.openrouter_base' then 'openrouter' else 'resend' end)
     where key in ($KEYS) and brand_id is null" >/dev/null
ERR0=$(sql "select coalesce(max(id), 0) from workflow_errors")
PROFILE='{"basics": {"name": "E2E", "description": "End-to-end test brand.", "niche": "tests", "audience": "testers", "languages": ["en"],
  "timezone": "UTC", "website": null, "topics": ["jazz", "events"], "facts": ["Garden stage on Oak street"]},
  "voice": {"tone": "friendly", "style": "short", "address": "informal", "emoji": "none", "allowed_words": [], "forbidden_words": ["cheap"],
  "allowed_topics": [], "forbidden_topics": []},
  "required_elements": {"cta": {"phrases": [], "platforms": []}, "links": [], "hashtags": {"required": [], "pool": [], "max": 5, "platforms": []},
  "disclaimers": [], "signature": {"text": null, "platforms": []}},
  "visual": {"palette": ["#336699"], "image_style": "bright photo", "logo": null, "forbidden": []}, "examples": {"good": [], "bad": []},
  "platforms": {"telegram": {"notes": null, "max_chars": null, "image_aspect": null}, "blog": {"notes": null, "max_chars": null, "image_aspect": null},
    "email": {"notes": null, "max_chars": null, "image_aspect": null}, "linkedin": {"notes": null, "max_chars": null, "image_aspect": null},
    "instagram": {"notes": null, "max_chars": null, "image_aspect": null}, "facebook": {"notes": null, "max_chars": null, "image_aspect": null},
    "x": {"notes": null, "max_chars": null, "image_aspect": null}},
  "digest": {"title": "E2E weekly", "intro_style": "short", "footer_text": "E2E", "cta": null}}'
for b in e2e-brand e2e-other; do
  sql "select brand_seed(jsonb_build_object('brand', jsonb_build_object('slug', '$b', 'name', '$b', 'timezone', 'UTC'), 'profile', '$PROFILE'::jsonb,
    'platforms', '[{\"platform\": \"telegram\", \"language\": \"en\", \"mode\": \"real\", \"target\": {\"chat_id\": \"@e2e_channel\"},
                    \"schedule\": {\"slots\": [{\"days\": [1,2,3,4,5,6,7], \"times\": [\"09:00\"]}], \"max_per_day\": 3, \"min_interval_minutes\": 60}},
                   {\"platform\": \"blog\", \"language\": \"en\", \"mode\": \"real\"},
                   {\"platform\": \"linkedin\", \"language\": \"en\", \"mode\": \"preview\"}]'::jsonb))" >/dev/null
done
sql "insert into users (tg_user_id, tg_chat_id, tg_username, display_name, is_admin, email) values
       (900001, 900001, 'e2e_author', 'E2E Author', false, 'author@e2e.test'), (900002, 900002, 'e2e_editor', 'E2E Editor', false, null),
       (900003, 900003, 'e2e_admin', 'E2E Admin', true, null);
     insert into memberships (user_id, brand_id, role) select u.id, b.id, 'author' from users u, brands b where u.tg_user_id = 900001 and b.slug like 'e2e-%';
     insert into memberships (user_id, brand_id, role) select u.id, b.id, 'editor' from users u, brands b where u.tg_user_id = 900002 and b.slug = 'e2e-brand';" >/dev/null
AUTHOR=$(sql "select id from users where tg_user_id = 900001")

scenario_text() {
echo "e2e: text material -> classifier -> package -> card -> publish"
msg 900001 '"text": "Jazz evening on Thursday at 20:00 on the garden stage, entrance free for members."'
[ "$(tg_post "$U")" = "200" ] || fail "webhook accepts the update"
[ "$(tg_post "$U")" = "200" ] || fail "webhook accepts a redelivery"
wait_for "select count(*) = 1 from inbound_events where source = 'telegram' and external_key = '$UPD'" "redelivered update stored once" 10
wait_for "select exists (select 1 from materials where author_user_id = $AUTHOR and status = 'received')" "material received" 60
M=$(sql "select max(id) from materials where author_user_id = $AUTHOR")
cb 900001 "mp:$M"
wait_for "select status = 'routed' from materials where id = $M" "routed" 120
[ "$(sql "select method || ':' || b.slug from material_routes r join brands b on b.id = r.brand_id where material_id = $M")" = "classifier:e2e-brand" ] \
  && pass "classifier picked e2e-brand" || fail "classifier route"
wait_for "select count(*) = 3 from variants v join packages p on p.id = v.package_id where p.material_id = $M and v.status = 'pending_approval'" "3 variants checked" 180
wait_for "select card_sent_at is not null from packages where material_id = $M" "card queued" 120
wait_for "select exists (select 1 from outbox where slot_key like 'card:%' and chat_id = 900002 and status = 'sent')" "card delivered to the editor" 60
wait_for "select (select count(*) from ai_usage where material_id = $M and status = 'ok') >= 7 and (select sum(cost_usd) from ai_usage where material_id = $M) > 0" "AI calls recorded with cost" 10
wait_for "select exists (select 1 from package_visuals pv join packages p on p.id = pv.package_id where p.material_id = $M)" "visual generated" 60
VT=$(sql "select v.id from variants v join packages p on p.id = v.package_id where p.material_id = $M and v.platform = 'telegram'")
VB=$(sql "select v.id from variants v join packages p on p.id = v.package_id where p.material_id = $M and v.platform = 'blog'")
cb 900002 "pny:$VT"
cb 900002 "pny:$VB"
wait_for "select status = 'published' from variants where id = $VT" "telegram post published" 90
wait_for "select status = 'published' and external_url like '%/b/e2e-brand/%' from variants where id = $VB" "blog post published" 60
curl -s "$STUB/calls" | python3 -c "
import json, sys
calls = json.load(sys.stdin)['calls']
posts = [c for c in calls if c['service'] == 'tg' and c['method'] in ('sendPhoto', 'sendMessage') and str(c['body'].get('chat_id')) == '@e2e_channel']
assert len(posts) == 1, f'expected 1 channel post, got {len(posts)}'
assert all(c.get('key') == 'present' for c in calls if c['service'] == 'anthropic'), 'anthropic calls without key'
assert any(c['service'] == 'anthropic' and c['cached'] for c in calls), 'no cached system block'
print('  ok    exactly one channel post; AI calls authenticated; prompt caching used')
" || fail "stub call log"
wait_for "select count(*) = 1 from publish_attempts where variant_id = $VT and op = 'publish'" "one publish attempt" 5
# PB-7: edit the published post from the card, then delete it
cb 900002 "pe:$VT"
wait_for "select exists (select 1 from bot_sessions b join users u on u.id = b.user_id where u.tg_user_id = 900002 and b.kind = 'edit_published')" "edit dialog opened" 30
msg 900002 '"text": "Jazz evening on Thursday at 20:00 on the garden stage. Entrance is free for members."'
tg_post "$U" >/dev/null
wait_for "select exists (select 1 from publish_attempts where variant_id = $VT and op = 'edit' and outcome = 'ok')" "published post edited" 90
cb 900002 "pdy:$VT"
wait_for "select external_deleted_at is not null from variants where id = $VT" "published post deleted" 90
curl -s "$STUB/calls" | python3 -c "
import json, sys
calls = [c for c in json.load(sys.stdin)['calls'] if c['service'] == 'tg' and str(c['body'].get('chat_id', '')).startswith('-100')]
assert any(c['method'] in ('editMessageText', 'editMessageCaption') for c in calls), 'no channel edit call'
assert any(c['method'] == 'deleteMessage' for c in calls), 'no channel delete call'
print('  ok    channel post edited and deleted through the Bot API')" || fail "post ops calls"
}

scenario_voice() {
echo "e2e: voice material, n8n restarted mid-pipeline"
M=$(sql "select coalesce(max(id), 0) from materials where author_user_id = $AUTHOR")
msg 900001 '"voice": {"file_id": "voice-e2e-1", "file_unique_id": "voice-e2e-u1", "duration": 12, "mime_type": "audio/ogg", "file_size": 2048}'
tg_post "$U" >/dev/null
wait_for "select exists (select 1 from materials where author_user_id = $AUTHOR and id > $M)" "voice material received" 60
M2=$(sql "select max(id) from materials where author_user_id = $AUTHOR")
curl -sf -X POST "$STUB/control" -H 'content-type: application/json' -d '{"anthropicDelay": 15000}' >/dev/null
cb 900001 "mp:$M2"
# crash while the summary call is in flight
wait_for "select exists (select 1 from jobs where material_id = $M2 and type = 'material.summarize' and status = 'running')" "summary step running" 60
docker compose restart n8n >/dev/null 2>&1
curl -sf -X POST "$STUB/control" -H 'content-type: application/json' -d '{"anthropicDelay": 0}' >/dev/null
for i in $(seq 1 60); do curl -sf -o /dev/null "$N8N/healthz" && break; sleep 2; done
sql "update jobs set locked_until = now() - interval '1 second' where status = 'running';
     update outbox set locked_until = now() - interval '1 second' where status = 'sending'" >/dev/null  # time passes: leases expire
wait_for "select status = 'routed' from materials where id = $M2" "voice material routed after the restart" 240
wait_for "select extracted_text like 'Stub transcript%' from material_parts where material_id = $M2 and kind = 'voice'" "voice transcribed" 5
wait_for "select card_sent_at is not null from packages where material_id = $M2" "card after the restart" 120
[ "$(sql "select count(*) from packages where material_id = $M2")" = 1 ] && pass "one package, no duplicates after the crash" || fail "duplicate packages"
# n8n reports the executions the restart killed; that is the expected alert, not a failure of this run
wait_for "select exists (select 1 from workflow_errors where id > $ERR0 and message ilike '%did not finish%')" "interrupted executions reported to the error handler" 30
ERR0=$(sql "select coalesce(max(id), 0) from workflow_errors")
}

scenario_email() {
echo "e2e: email material with an attachment"
curl -sf -X POST "$STUB/control" -H 'content-type: application/json' \
  -d "{\"inboundTo\": \"$(sql "select 'in+' || intake_token || '@' || setting_text('email.inbound_domain') from users where id = $AUTHOR")\"}" >/dev/null
# unique ids per run: a redelivered email id is (correctly) never fetched twice
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$N8N/webhook/resend" -H 'content-type: application/json' -H "svix-id: e2e-mail-$UPD" \
  -d "{\"type\": \"email.received\", \"data\": {\"email_id\": \"att-e2e-$UPD\"}}")
[ "$code" = "200" ] || fail "resend webhook"
wait_for "select exists (select 1 from materials where author_user_id = $AUTHOR and source = 'email' and status = 'routed')" "email material routed" 180
M3=$(sql "select max(id) from materials where author_user_id = $AUTHOR and source = 'email'")
wait_for "select count(*) = 2 and count(*) filter (where asset_id is not null) = 1 from material_parts where material_id = $M3" "text + stored attachment" 5
wait_for "select exists (select 1 from outbox where email_to = 'author@e2e.test' and dedupe_key = 'email_ack:$M3' and status = 'sent')" "ack email sent" 60
}

scenario_stranger() {
echo "e2e: unknown sender"
msg 900099 '"text": "hello, who are you?"'
tg_post "$U" >/dev/null
wait_for "select exists (select 1 from outbox where chat_id = 900099 and status = 'sent')" "unknown sender answered" 60
wait_for "select not exists (select 1 from materials m join users u on u.id = m.author_user_id where u.tg_user_id = 900099)" "no material from a stranger" 5
}

# acceptance (tz 11) and load measurement, opt-in (several minutes): a 500-row CSV -> 492 row materials, 8 bad rows listed
scenario_table() {
echo "e2e: 500-row table"
M=$(sql "select coalesce(max(id), 0) from materials where author_user_id = $AUTHOR")
msg 900001 '"document": {"file_id": "csv500-e2e", "file_unique_id": "csv500-u", "file_name": "plan.csv", "mime_type": "text/csv", "file_size": 30000}'
tg_post "$U" >/dev/null
wait_for "select exists (select 1 from materials where author_user_id = $AUTHOR and id > $M and parent_material_id is null)" "table material received" 60
MT=$(sql "select min(id) from materials where author_user_id = $AUTHOR and id > $M and parent_material_id is null")
cb 900001 "mp:$MT"
wait_for "select count(*) = 492 from materials where parent_material_id = $MT" "492 row materials" 120
[ "$(sql "select count(distinct row_number) from materials where parent_material_id = $MT")" = 492 ] && pass "no duplicated rows" || fail "duplicated rows"
sql "select payload ->> 'text' from outbox where dedupe_key = 'table_report:$MT'" | python3 -c "
import sys
t = sys.stdin.read()
missing = [r for r in (51, 151, 251, 351, 451, 100, 200, 300) if f'row {r}: ' not in t]
assert not missing, f'rows not reported: {missing}'
print('  ok    8 bad rows listed with their numbers')" || fail "table report"
T0=$(date +%s)
wait_for "select count(*) = 492 from materials where parent_material_id = $MT and status = 'routed'" "all rows routed" 1200
wait_for "select count(*) = 492 from packages p join materials c on c.id = p.material_id where c.parent_material_id = $MT and p.card_sent_at is not null" "492 cards" 3600
echo "        492 rows: routed and carded in $(( $(date +%s) - T0 ))s"
}

scenario_image() {
echo "e2e: photo material -> the author's photo becomes the visual"
M=$(sql "select coalesce(max(id), 0) from materials where author_user_id = $AUTHOR")
msg 900001 '"photo": [{"file_id": "img-e2e-s", "file_unique_id": "img-e2e-us", "width": 32, "height": 18, "file_size": 300},
  {"file_id": "img-e2e-1", "file_unique_id": "img-e2e-u1", "width": 32, "height": 18, "file_size": 600}],
  "caption": "New espresso bar next to the garden stage, open from Monday."'
tg_post "$U" >/dev/null
wait_for "select exists (select 1 from materials where author_user_id = $AUTHOR and id > $M)" "photo material received" 60
MI=$(sql "select max(id) from materials where author_user_id = $AUTHOR")
cb 900001 "mp:$MI"
wait_for "select status = 'routed' from materials where id = $MI" "photo material routed" 180
wait_for "select exists (select 1 from material_parts where material_id = $MI and kind = 'image' and asset_id is not null and extracted_text <> '')" "photo stored and described" 5
wait_for "select exists (select 1 from package_visuals pv join packages p on p.id = pv.package_id where p.material_id = $MI and pv.origin = 'source')" "author's photo adapted as the visual" 180
wait_for "select card_sent_at is not null from packages where material_id = $MI" "card with the photo" 120
}

scenario_profile() {
echo "e2e: brand config as a YAML file through the bot: export, edit, import, activate"
B=$(sql "select id from brands where slug = 'e2e-brand'")
msg 900003 '"text": "/profile e2e-brand"'; tg_post "$U" >/dev/null
wait_for "select exists (select 1 from outbox where chat_id = 900003 and kind = 'document' and status = 'sent')" "YAML file sent (file upload)" 90
# the manager edits the file: another tone
YAML=$(sql "select brand_config($B)" | docker compose exec -T extractor node --input-type=module -e "
import fs from 'node:fs'; import { yamlDump } from '/app/server.mjs';
const c = JSON.parse(fs.readFileSync(0, 'utf8'));
for (const k of Object.keys(c)) if (k.startsWith('_')) delete c[k];
c.profile.voice.tone = 'warm and witty';
process.stdout.write(yamlDump(c, 'edited by e2e'));")
printf '%s' "$YAML" | python3 -c 'import json, sys; print(json.dumps({"yaml": sys.stdin.read()}))' \
  | curl -sf -X POST "$STUB/control" -H 'content-type: application/json' -d @- >/dev/null
msg 900003 '"document": {"file_id": "yaml-e2e-1", "file_unique_id": "yaml-e2e-u1", "file_name": "e2e-brand.yaml", "mime_type": "application/x-yaml", "file_size": 4000}'
tg_post "$U" >/dev/null
wait_for "select exists (select 1 from brand_profile_versions where brand_id = $B and status = 'draft' and source = 'yaml')" "YAML imported as a draft version" 90
V=$(sql "select max(version) from brand_profile_versions where brand_id = $B and status = 'draft'")
cb 900003 "pa:$B:$V"
wait_for "select profile #>> '{voice,tone}' = 'warm and witty' from brand_profile_versions where brand_id = $B and status = 'active'" "edited version active" 30
}

scenario_onboarding() {
echo "e2e: onboarding: sample posts -> draft profile"
B=$(sql "select id from brands where slug = 'e2e-other'")
msg 900003 '"text": "/onboard e2e-other"'; tg_post "$U" >/dev/null
wait_for "select exists (select 1 from bot_sessions b join users u on u.id = b.user_id where u.tg_user_id = 900003 and b.kind = 'onboarding')" "onboarding dialog opened" 30
for t in "Sunday brunch is back: pancakes, berries and live acoustic sets from 11:00." \
         "Our barista team just came back from the roasters in Porto. New single origin on the menu this week." \
         "Thank you for 500 reviews! Come by for a free cookie with any coffee this Friday."; do
  msg 900003 "\"text\": \"$t\""; tg_post "$U" >/dev/null
done
wait_for "select count(*) >= 3 from onboarding_samples where brand_id = $B" "3 samples stored" 30
msg 900003 '"text": "/done"'; tg_post "$U" >/dev/null
wait_for "select exists (select 1 from brand_profile_versions where brand_id = $B and source = 'onboarding' and status = 'draft')" "draft profile from the samples" 120
}

scenario_digest() {
echo "e2e: digest: blocks -> build -> test send -> approve -> send in chunks -> delivery event"
sql "select brand_seed(jsonb_build_object('brand', jsonb_build_object('slug', 'e2e-news', 'name', 'E2E News', 'timezone', 'UTC'), 'profile', '$PROFILE'::jsonb,
  'platforms', '[{\"platform\": \"email\", \"language\": \"en\", \"mode\": \"real\", \"target\": {\"from_name\": \"E2E News\"},
                  \"schedule\": {\"frequency\": \"weekly\", \"day\": 5, \"time\": \"10:00\", \"auto_send\": false}}]'::jsonb,
  'feeds', '[\"http://stub:3000/rss.xml\"]'::jsonb))" >/dev/null
BN=$(sql "select id from brands where slug = 'e2e-news'")
sql "select enqueue_job('feeds.fetch', '{}', p_brand => $BN, p_dedupe => 'e2e-feeds-$UPD')" >/dev/null
wait_for "select count(*) = 3 and bool_and(fi.relevance is not null and fi.embedding is not null) from feed_items fi join feed_sources fs on fs.id = fi.source_id where fs.brand_id = $BN" "RSS source read, items scored by embeddings" 90
sql "insert into users (tg_user_id, tg_chat_id, tg_username, display_name) values (900004, 900004, 'e2e_news', 'E2E News Author');
     insert into memberships (user_id, brand_id, role) select id, $BN, 'author' from users where tg_user_id = 900004;
     insert into memberships (user_id, brand_id, role) select id, $BN, 'editor' from users where tg_user_id = 900002;
     update users set email = 'editor@e2e.test' where tg_user_id = 900002;
     insert into subscribers (brand_id, email, status) values ($BN, 'r1@e2e.test', 'confirmed'), ($BN, 'r2@e2e.test', 'confirmed'),
       ($BN, 'r3@e2e.test', 'confirmed'), ($BN, 'pending@e2e.test', 'pending')" >/dev/null
NA=$(sql "select id from users where tg_user_id = 900004")
for t in "Our community garden harvested two hundred kilos of tomatoes this year." \
         "A new bike repair cafe opens every first Saturday at the town hall."; do
  M=$(sql "select coalesce(max(id), 0) from materials where author_user_id = $NA")
  msg 900004 "\"text\": \"$t\""; tg_post "$U" >/dev/null
  wait_for "select exists (select 1 from materials where author_user_id = $NA and id > $M)" "news material received" 60
  MN=$(sql "select max(id) from materials where author_user_id = $NA")
  cb 900004 "mp:$MN"
  wait_for "select exists (select 1 from variants v join packages p on p.id = v.package_id where p.material_id = $MN and v.status = 'pending_approval')" "email block ready" 180
  cb 900002 "ap:$(sql "select v.id || ':' || v.current_version from variants v join packages p on p.id = v.package_id where p.material_id = $MN")"
  wait_for "select v.status = 'scheduled' from variants v join packages p on p.id = v.package_id where p.material_id = $MN" "block approved for the digest" 30
done
msg 900002 '"text": "/digest e2e-news now"'; tg_post "$U" >/dev/null
wait_for "select exists (select 1 from digest_issues where brand_id = $BN and status = 'pending_approval')" "issue built" 180
DI=$(sql "select id from digest_issues where brand_id = $BN and status = 'pending_approval'")
wait_for "select (select count(*) from digest_items where issue_id = $DI) = 2 and exists (select 1 from outbox where slot_key like 'digest:$DI:%' and status = 'sent')" "2 blocks, card sent" 60
cb 900002 "dt:$DI"
stub_wait "c['service'] == 'resend' and c.get('to') == 'editor@e2e.test' and str(c.get('idempotency')).startswith('digest-test-$DI-')" "test email sent" 90
cb 900002 "da:$DI"
wait_for "select status = 'scheduled' from digest_issues where id = $DI" "issue approved" 30
sql "update digest_issues set send_at = now() where id = $DI;
     update jobs set run_after = now() where type = 'digest.deadline' and payload ->> 'issue_id' = '$DI'" >/dev/null
wait_for "select status = 'published' and (stats ->> 'sent')::int = 3 from digest_issues where id = $DI" "issue sent to the 3 confirmed subscribers" 120
curl -s "$STUB/calls" | python3 -c "
import json, sys
calls = [c for c in json.load(sys.stdin)['calls'] if c['service'] == 'resend' and c['path'] == '/emails/batch']
assert len(calls) == 1, f'expected 1 batch call, got {len(calls)}'
assert calls[0]['idempotency'] and calls[0]['auth'] == 'present', 'batch call without idempotency key or auth'
print('  ok    one authenticated batch call with an idempotency key')" || fail "resend batch"
ESP=$(sql "select esp_message_id from digest_deliveries where issue_id = $DI order by esp_message_id limit 1")
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$N8N/webhook/resend" -H 'content-type: application/json' -H "svix-id: e2e-ev-$DI" \
  -d "{\"type\": \"email.delivered\", \"data\": {\"email_id\": \"$ESP\"}}")
[ "$code" = "200" ] || fail "resend event webhook"
wait_for "select status = 'delivered' from digest_deliveries where esp_message_id = '$ESP'" "delivery event verified and applied" 60
}

scenario_guest() {
echo "e2e: guest mode: demo brand -> preview package, nothing really published; brand from one sentence"
sql "select brand_seed(jsonb_build_object('brand', jsonb_build_object('slug', 'e2e-demo', 'name', 'E2E Demo', 'timezone', 'UTC'), 'profile', '$PROFILE'::jsonb,
  'platforms', '[{\"platform\": \"telegram\", \"language\": \"en\", \"mode\": \"real\", \"target\": {\"chat_id\": \"@e2e_demo_channel\"},
                  \"schedule\": {\"slots\": [{\"days\": [1,2,3,4,5,6,7], \"times\": [\"09:00\"]}], \"max_per_day\": 3, \"min_interval_minutes\": 60}},
                 {\"platform\": \"linkedin\", \"language\": \"en\", \"mode\": \"preview\"}]'::jsonb), true)" >/dev/null
BD=$(sql "select id from brands where slug = 'e2e-demo'")
msg 900098 '"text": "/demo"'; tg_post "$U" >/dev/null
wait_for "select exists (select 1 from users where tg_user_id = 900098 and guest_enabled)" "guest menu" 30
cb 900098 "gb:$BD"
wait_for "select guest_brand_id = $BD from users where tg_user_id = 900098" "demo brand chosen" 30
G=$(sql "select id from users where tg_user_id = 900098")
msg 900098 '"text": "We are a flower shop opening a second store downtown next month."'; tg_post "$U" >/dev/null
wait_for "select exists (select 1 from materials where author_user_id = $G and is_guest)" "guest material received" 60
MG=$(sql "select max(id) from materials where author_user_id = $G")
cb 900098 "mp:$MG"
wait_for "select count(*) = 2 and bool_and(v.status = 'published' and v.external_url like '%/p/%') from variants v join packages p on p.id = v.package_id where p.material_id = $MG" "guest variants published as previews" 240
wait_for "select not exists (select 1 from publish_attempts a join variants v on v.id = a.variant_id join packages p on p.id = v.package_id where p.material_id = $MG and a.adapter <> 'preview')" "no real adapter used" 5
curl -s "$STUB/calls" | python3 -c "
import json, sys
calls = json.load(sys.stdin)['calls']
assert not [c for c in calls if c['service'] == 'tg' and str(c['body'].get('chat_id')) == '@e2e_demo_channel'], 'guest content reached the channel'
print('  ok    nothing sent to the demo channel')" || fail "guest isolation"
cb 900098 "gn"
wait_for "select exists (select 1 from bot_sessions where user_id = $G and kind = 'guest_business')" "business description asked" 30
msg 900098 '"text": "Family bakery in Lisbon with sourdough bread and pastel de nata."'; tg_post "$U" >/dev/null
wait_for "select exists (select 1 from brands b join users u on u.guest_brand_id = b.id where u.id = $G and b.is_temporary)" "temporary brand from one sentence" 120
}

scenario_eval() {
echo "e2e: eval run (routing set) through the real pipeline steps"
R0=$(sql "select coalesce(max(id), 0) from eval_runs")
msg 900003 '"text": "/eval routing"'; tg_post "$U" >/dev/null
wait_for "select exists (select 1 from eval_runs where id > $R0)" "eval run started" 30
R=$(sql "select max(id) from eval_runs")
wait_for "select status = 'done' from eval_runs where id = $R" "eval run finished" 300
wait_for "select exists (select 1 from outbox where chat_id = 900003 and payload ->> 'text' like '%Eval run #$R finished%')" "summary sent to the admin" 60
wait_for "select not exists (select 1 from packages p join materials m on m.id = p.material_id join eval_results r on r.material_id = m.id where r.run_id = $R and p.card_sent_at is not null)" "no cards for eval materials" 5
}

scenario_retry() {
echo "e2e: channel unavailable -> retries -> editors notified -> manual retry publishes exactly once"
M=$(sql "select coalesce(max(id), 0) from materials where author_user_id = $AUTHOR")
msg 900001 '"text": "Poetry night on Wednesday at 19:00 in the library hall, bring your own poems."'; tg_post "$U" >/dev/null
wait_for "select exists (select 1 from materials where author_user_id = $AUTHOR and id > $M)" "material received" 60
MR=$(sql "select max(id) from materials where author_user_id = $AUTHOR")
cb 900001 "mp:$MR"
wait_for "select card_sent_at is not null from packages where material_id = $MR" "card" 180
VR=$(sql "select v.id from variants v join packages p on p.id = v.package_id where p.material_id = $MR and v.platform = 'telegram'")
curl -sf -X POST "$STUB/control" -H 'content-type: application/json' -d '{"tgFail": 1000}' >/dev/null
cb 900002 "pny:$VR"
wait_for "select count(*) = 1 from publish_attempts where variant_id = $VR and outcome = 'failed'" "first attempt failed" 60
wait_for "select status = 'publishing' and next_attempt_at > now() from variants where id = $VR" "retry scheduled with backoff" 5
sql "update variants set next_attempt_at = now() where id = $VR" >/dev/null   # time passes
wait_for "select count(*) = 2 from publish_attempts where variant_id = $VR and outcome = 'failed'" "automatic retry failed too" 60
sql "update variants set publish_first_attempt_at = now() - interval '31 minutes', next_attempt_at = now() where id = $VR" >/dev/null  # the retry window is over
wait_for "select status = 'failed' from variants where id = $VR" "variant failed after the retry window" 60
wait_for "select exists (select 1 from outbox where chat_id = 900002 and dedupe_key like 'pubfail:$VR:%')" "editor notified with retry buttons" 30
curl -sf -X POST "$STUB/control" -H 'content-type: application/json' -d '{"tgFail": 0}' >/dev/null
cb 900002 "pr:$VR"
wait_for "select status = 'published' from variants where id = $VR" "manual retry published" 90
[ "$(sql "select count(*) from publish_attempts where variant_id = $VR and outcome = 'ok'")" = 1 ] && pass "exactly one successful publication" || fail "publication count"
}

scenario_pause() {
echo "e2e: stop switch: nothing is published while paused; resume publishes the overdue post"
msg 900003 '"text": "/pause all"'; tg_post "$U" >/dev/null
wait_for "select exists (select 1 from system_pauses where scope = 'system' and resumed_at is null)" "system paused" 30
SP=$(sql "select max(id) from system_pauses where scope = 'system' and resumed_at is null")
M=$(sql "select coalesce(max(id), 0) from materials where author_user_id = $AUTHOR")
msg 900001 '"text": "Chess club meets on Tuesday at 18:30 in the garden pavilion, beginners welcome."'; tg_post "$U" >/dev/null
wait_for "select exists (select 1 from materials where author_user_id = $AUTHOR and id > $M)" "material received" 60
MP=$(sql "select max(id) from materials where author_user_id = $AUTHOR")
cb 900001 "mp:$MP"
wait_for "select card_sent_at is not null from packages where material_id = $MP" "card" 180
VP=$(sql "select v.id from variants v join packages p on p.id = v.package_id where p.material_id = $MP and v.platform = 'telegram'")
cb 900002 "pny:$VP"
wait_for "select status = 'scheduled' and scheduled_at <= now() from variants where id = $VP" "post due now" 30
sleep 65  # more than two publisher ticks
[ "$(sql "select status || ':' || (select count(*) from publish_attempts where variant_id = $VP) from variants where id = $VP")" = "scheduled:0" ] \
  && pass "nothing published for 65 s while paused" || fail "published during the pause"
cb 900003 "ur:$SP:p"
wait_for "select status = 'published' from variants where id = $VP" "overdue post published after resume" 90
}

for s in ${@:-text voice image email retry pause profile onboarding digest guest eval stranger}; do "scenario_$s"; done

echo "e2e: health"
wait_for "select not exists (select 1 from jobs where status = 'dead' and created_at > now() - interval '15 minutes')" "no dead jobs" 5
wait_for "select not exists (select 1 from outbox where status in ('dead', 'failed') and created_at > now() - interval '15 minutes')" "no failed messages" 5
wait_for "select not exists (select 1 from workflow_errors where id > $ERR0)" "no workflow errors" 5
echo "e2e: all passed"
