#!/usr/bin/env bash
# Point the Telegram bot at n8n and store its username. PUBLIC_N8N_URL must be a public HTTPS base (a cloudflared tunnel
# in dev). Bot API calls go through the egress proxy, which holds the bot token; the webhook secret travels on stdin only.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
: "${PUBLIC_N8N_URL:?set PUBLIC_N8N_URL in .env (public https base of n8n)}"
api() { docker compose exec -T egress wget -qO- --header 'content-type: application/json' --post-file=/dev/stdin "http://127.0.0.1:8081/tg/$1"; }
python3 -c 'import json, os; print(json.dumps({"url": os.environ["PUBLIC_N8N_URL"].rstrip("/") + "/webhook/tg",
  "secret_token": os.environ["TELEGRAM_WEBHOOK_SECRET"], "max_connections": 40,
  "allowed_updates": ["message", "callback_query", "message_reaction_count", "my_chat_member"]}))' | api setWebhook
echo
python3 -c 'import json; print(json.dumps({"commands": [{"command": c, "description": d} for c, d in [
  ("help", "What I can do for you"), ("status", "Status and history of a material: /status M-123"), ("panel", "Link to the web panel"),
  ("intake", "Your personal email address for materials"), ("myemail", "Set your email for test digests"),
  ("notify", "Published notices: each, batch or off"), ("brands", "Your brands and roles"), ("digest", "Newsletter status or build now"),
  ("report", "Weekly report"), ("pause", "Stop publishing (brand or platform)"), ("resume", "Resume publishing"),
  ("cancel", "Cancel the current dialog"), ("demo", "Try the demo mode")]]}))' | api setMyCommands
echo
user=$(echo '{}' | api getMe | python3 -c 'import json, sys; print(json.load(sys.stdin)["result"]["username"])')
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -X -U postgres -d app -c 'set role app_owner' \
  -c "update settings set value = to_jsonb('$user'::text), updated_at = now() where key = 'bot.username' and brand_id is null"
echo "telegram: webhook set, bot @$user"
