#!/usr/bin/env bash
# One-time admin invite link (the first admin, or recovery). Open the link in Telegram and press Start.
set -euo pipefail
cd "$(dirname "$0")/.."
token=$(docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -X -tA -U postgres -d app -c 'set role app_owner' -c 'select admin_invite_bootstrap()')
bot=$(docker compose exec -T postgres psql -X -tA -U postgres -d app -c "select setting_text('bot.username')")
echo "Admin invite (valid 72 h, single use): https://t.me/${bot:-<your_bot>}?start=$token"
