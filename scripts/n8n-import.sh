#!/usr/bin/env bash
# Import every workflow from n8n/workflows (stable ids, the repo is the source of truth) and publish it.
# Sub-workflows run only in their published version; publishing a trigger workflow activates it. Restart makes the
# running instance pick up activations done through the CLI.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose exec -T n8n n8n import:workflow --separate --input=/workflows 2>&1 | grep -v '^$' | tail -2
for f in n8n/workflows/*.json; do
  id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$f")
  docker compose exec -T n8n n8n publish:workflow --id="$id" >/dev/null 2>&1 || { echo "publish failed: $f" >&2; exit 1; }
done
docker compose restart n8n >/dev/null
for i in $(seq 1 60); do curl -sf -o /dev/null http://localhost:5679/healthz && break; sleep 2; done
echo "n8n: $(ls n8n/workflows/*.json | wc -l) workflows imported and published"
