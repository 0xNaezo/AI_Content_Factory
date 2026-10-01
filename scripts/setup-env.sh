#!/usr/bin/env bash
# Creates .env from .env.example and fills local secrets with random values (existing values are kept).
# External API keys (Telegram, Anthropic, OpenRouter, Resend) stay empty: fill them yourself.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] || cp .env.example .env
gen() { openssl rand -hex 24; }
for key in POSTGRES_PASSWORD APP_OWNER_PASSWORD APP_N8N_PASSWORD APP_WEB_PASSWORD N8N_DB_PASSWORD \
           S3_SECRET_KEY TELEGRAM_WEBHOOK_SECRET WEB_CMD_SECRET WEB_SESSION_SECRET; do
  if ! grep -q "^${key}=." .env; then
    if grep -q "^${key}=" .env; then sed -i "s|^${key}=.*|${key}=$(gen)|" .env; else echo "${key}=$(gen)" >> .env; fi
  fi
done
grep -q '^S3_ACCESS_KEY=.' .env || { grep -q '^S3_ACCESS_KEY=' .env && sed -i "s|^S3_ACCESS_KEY=.*|S3_ACCESS_KEY=acf$(openssl rand -hex 6)|" .env || echo "S3_ACCESS_KEY=acf$(openssl rand -hex 6)" >> .env; }
echo ".env ready. Fill TELEGRAM_BOT_TOKEN, ANTHROPIC_API_KEY, OPENROUTER_API_KEY, RESEND_API_KEY, PUBLIC_N8N_URL."
