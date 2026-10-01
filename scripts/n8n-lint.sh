#!/usr/bin/env bash
# Static checks of n8n/workflows before import: connections and $('Node') references point at existing nodes, called
# workflows exist, and every expression still parses after n8n's own rewrite (extendSyntax). The rewrite of optional
# chaining can drop parentheses, e.g. "a?.b ?? (c || d)" becomes invalid; such expressions fail only at run time.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'EOF' > /tmp/acf-n8n-exprs.json
import json, glob, re, sys
ids = {json.load(open(f))['id'] for f in glob.glob('n8n/workflows/*.json')}
exprs, bad = [], 0
def walk(o, path):
    if isinstance(o, dict):
        for k, v in o.items():
            if k != 'jsCode': yield from walk(v, path + [k])
    elif isinstance(o, list):
        for i, v in enumerate(o): yield from walk(v, path + [i])
    elif isinstance(o, str) and o.startswith('=') and '{{' in o:
        yield path, o
for f in sorted(glob.glob('n8n/workflows/*.json')):
    w = json.load(open(f))
    names = {n['name'] for n in w['nodes']}
    targets = {c['node'] for src in w['connections'].values() for outs in src.values() for out in outs for c in (out or [])}
    probs = [f"connection to missing node '{t}'" for t in targets - names]
    probs += [f"connection from missing node '{s}'" for s in set(w['connections']) - names]
    for ref in set(re.findall(r"\$\(['\"]([^'\"]+)['\"]\)", json.dumps(w['nodes']).replace('\\"', '"'))):
        if ref not in names: probs.append(f"reference to missing node '{ref}'")
    for n in w['nodes']:
        wid = n['parameters'].get('workflowId')
        v = wid.get('value') if isinstance(wid, dict) else wid
        if n['type'].endswith('executeWorkflow') and isinstance(v, str) and not v.startswith('=') and v not in ids:
            probs.append(f"'{n['name']}' calls unknown workflow {v}")
        for path, e in walk(n['parameters'], []):
            exprs.append({'where': f"{f.split('/')[-1]} / {n['name']} / {'.'.join(map(str, path))}", 'expr': e})
    for p in probs:
        print(f"{f}: {p}", file=sys.stderr)
    bad += len(probs)
if bad: sys.exit(1)
print(json.dumps(exprs))
EOF
docker compose exec -T -w "$(docker compose exec -T n8n sh -c 'ls -d /usr/local/lib/node_modules/n8n/node_modules/.pnpm/n8n-workflow@*/node_modules/n8n-workflow' | head -1)" n8n node -e '
const { extendSyntax } = require("./dist/cjs/extensions/expression-extension.js");
const items = JSON.parse(require("fs").readFileSync(0, "utf8"));
let bad = 0;
for (const { where, expr } of items) {
  let out;
  try { out = extendSyntax(expr); } catch (e) { console.log(`${where}: rewrite failed: ${e.message}`); bad++; continue; }
  for (const [, s] of out.matchAll(/\{\{([\s\S]*?)\}\}/g)) {
    try { new Function("return (" + s + ")"); } catch (e) { console.log(`${where}: ${e.message}`); bad++; }
  }
}
console.log(`n8n-lint: ${items.length} expressions, ${bad} problems`);
process.exit(bad ? 1 : 0);
' < /tmp/acf-n8n-exprs.json
