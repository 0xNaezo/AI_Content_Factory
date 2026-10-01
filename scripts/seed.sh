#!/usr/bin/env bash
# Demo brands from seed/brands/*.yaml (the same format as the brand YAML the bot exports). Each file is parsed and its
# profile validated against schemas/brand-profile.schema.json by the extractor, then brand_seed() creates or updates the
# brand (a new profile version only when the file changed). Demo brands power the guest mode and the eval set.
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${DB:-app}
for f in seed/brands/*.yaml; do
  json=$(docker compose exec -T extractor node --input-type=module -e "
import fs from 'node:fs';
import { yamlParse, validate } from '/app/server.mjs';
const p = yamlParse(fs.readFileSync(0, 'utf8'));
if (!p.ok) { console.error('YAML error at line ' + p.line + ': ' + p.error); process.exit(1); }
const v = validate('brand-profile', p.data.profile);
if (!v.ok) { console.error(v.errors.join('\n')); process.exit(1); }
process.stdout.write(JSON.stringify(p.data));
" < "$f") || { echo "seed: $f is invalid" >&2; exit 1; }
  r=$(printf '%s\n' "select brand_seed(:'j'::jsonb, true)" | docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -X -tA \
      -U postgres -d "$DB" -c 'set role app_owner' -v j="$json" -f -)
  echo "seed: $(basename "$f" .yaml) $r"
done
