// Utility sidecar for n8n (architecture: extraction and checks that n8n nodes can't do safely).
// No secrets, no state. Every outbound fetch goes through safeFetch (SSRF guard: public IPs only, re-checked per redirect).
import http from 'node:http';
import https from 'node:https';
import dns from 'node:dns/promises';
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { Readable } from 'node:stream';
import mammoth from 'mammoth';
import { Readability } from '@mozilla/readability';
import { parseHTML } from 'linkedom';
import YAML from 'yaml';
import Ajv2020 from 'ajv/dist/2020.js';
import sharp from 'sharp';

const PORT = Number(process.env.PORT || 8080);
const SCHEMA_DIR = process.env.SCHEMA_DIR || '/app/schemas';
const UA = 'Mozilla/5.0 (compatible; AIContentFactory/1.0; +https://github.com/)';

// ---------- SSRF guard ----------
const V4_BLOCKED = [
  ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8], ['169.254.0.0', 16], ['172.16.0.0', 12],
  ['192.0.0.0', 24], ['192.0.2.0', 24], ['192.168.0.0', 16], ['198.18.0.0', 15], ['198.51.100.0', 24], ['203.0.113.0', 24],
  ['224.0.0.0', 4], ['240.0.0.0', 4],
];
const v4int = (ip) => ip.split('.').reduce((a, o) => (a << 8) + Number(o), 0) >>> 0;

export function isPublicIp(ip) {
  if (net.isIPv4(ip)) {
    const n = v4int(ip);
    return !V4_BLOCKED.some(([base, bits]) => (n >>> (32 - bits)) === (v4int(base) >>> (32 - bits)));
  }
  if (net.isIPv6(ip)) {
    const x = ip.toLowerCase();
    const mapped = x.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
    if (mapped) return isPublicIp(mapped[1]);
    return !(x === '::' || x === '::1' || /^f[cd]/.test(x) || /^fe[89ab]/.test(x) || /^ff/.test(x) || x.startsWith('64:ff9b:') || x.startsWith('2001:db8'));
  }
  return false;
}

async function resolvePublic(hostname) {
  const host = hostname.replace(/^\[|\]$/g, '');
  const addrs = net.isIP(host) ? [{ address: host, family: net.isIPv6(host) ? 6 : 4 }] : await dns.lookup(host, { all: true });
  if (!addrs.length || !addrs.every((a) => isPublicIp(a.address))) throw new Error(`blocked address for ${hostname}`);
  return addrs[0];
}

// GET/HEAD with manual redirects; the socket connects to the vetted IP (no DNS rebinding between check and connect).
export async function safeFetch(url, { method = 'GET', maxBytes = 3_000_000, timeout = 15_000, redirects = 5 } = {}) {
  let current = new URL(url);
  for (let hop = 0; hop <= redirects; hop++) {
    if (!['http:', 'https:'].includes(current.protocol)) throw new Error('only http(s) URLs are allowed');
    if (current.port && !['80', '443', '8080', '8443'].includes(current.port)) throw new Error('port not allowed');
    const addr = await resolvePublic(current.hostname);
    const res = await new Promise((resolve, reject) => {
      const lib = current.protocol === 'https:' ? https : http;
      const req = lib.request(current, {
        method, timeout,
        headers: { 'user-agent': UA, accept: 'text/html,application/xhtml+xml,*/*;q=0.8', 'accept-language': 'en,*;q=0.5' },
        lookup: (_h, opts, cb) => (opts && opts.all ? cb(null, [addr]) : cb(null, addr.address, addr.family)),
      }, resolve);
      req.on('timeout', () => req.destroy(new Error('timeout')));
      req.on('error', reject);
      req.end();
    });
    if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) {
      res.resume();
      current = new URL(res.headers.location, current);
      continue;
    }
    const chunks = [];
    let size = 0;
    if (method !== 'HEAD') {
      for await (const c of res) {
        size += c.length;
        if (size > maxBytes) { res.destroy(); throw new Error(`response larger than ${maxBytes} bytes`); }
        chunks.push(c);
      }
    } else res.resume();
    return { status: res.statusCode, headers: res.headers, url: current.toString(), body: Buffer.concat(chunks) };
  }
  throw new Error('too many redirects');
}

function decode(buf, contentType = '') {
  const cs = (contentType.match(/charset=([^;]+)/i) || [])[1]?.trim() || (buf.subarray(0, 2048).toString('latin1').match(/<meta[^>]+charset=["']?([\w-]+)/i) || [])[1] || 'utf-8';
  try { return new TextDecoder(cs).decode(buf); } catch { return new TextDecoder('utf-8').decode(buf); }
}

// ---------- handlers ----------
export async function pageText(url, maxChars = 60_000) {
  const r = await safeFetch(url);
  if (r.status >= 400) return { ok: false, error: `page returned HTTP ${r.status}`, status: r.status };
  const type = String(r.headers['content-type'] || '');
  if (/^text\/plain/i.test(type)) return { ok: true, url: r.url, title: '', text: decode(r.body, type).slice(0, maxChars) };
  if (!/html|xml/i.test(type)) return { ok: false, error: `unsupported content type ${type || 'unknown'}` };
  const { document } = parseHTML(decode(r.body, type));
  const article = new Readability(document).parse();
  const text = (article?.textContent || document.body?.textContent || '').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  if (text.length < 200) return { ok: false, error: 'the page has no readable text (paywall, login or JavaScript-only page)', url: r.url };
  return { ok: true, url: r.url, title: article?.title || document.title || '', text: text.slice(0, maxChars), meta: { chars: text.length, site: article?.siteName || null } };
}

export async function checkLinks(urls) {
  const out = [];
  const queue = [...new Set(urls)].slice(0, 20);
  await Promise.all(Array.from({ length: 5 }, async () => {
    for (let u = queue.shift(); u; u = queue.shift()) {
      try {
        let r = await safeFetch(u, { method: 'HEAD', timeout: 8000 });
        if (r.status === 405 || r.status === 403 || r.status === 501) r = await safeFetch(u, { timeout: 8000, maxBytes: 200_000 }).catch((e) => ({ status: 0, error: e.message }));
        out.push({ url: u, ok: r.status > 0 && r.status < 400, status: r.status });
      } catch (e) {
        out.push({ url: u, ok: false, status: 0, error: e.message });
      }
    }
  }));
  return out;
}

const ajv = new Ajv2020({ allErrors: true, strict: false });
const validators = {};
if (fs.existsSync(SCHEMA_DIR)) {
  for (const f of fs.readdirSync(SCHEMA_DIR).filter((f) => f.endsWith('.schema.json'))) {
    validators[path.basename(f, '.schema.json')] = ajv.compile(JSON.parse(fs.readFileSync(path.join(SCHEMA_DIR, f), 'utf8')));
  }
}

export function validate(schema, data) {
  const v = validators[schema];
  if (!v) throw new Error(`unknown schema ${schema}`);
  if (v(data)) return { ok: true, errors: [] };
  const errors = v.errors.map((e) => {
    const where = e.instancePath ? e.instancePath.slice(1).replaceAll('/', '.') : '(root)';
    const extra = e.params?.additionalProperty ? ` "${e.params.additionalProperty}"` : e.params?.allowedValues ? `: ${e.params.allowedValues.join(', ')}` : '';
    return `${where}: ${e.message}${extra}`;
  });
  return { ok: false, errors: [...new Set(errors)].slice(0, 50) };
}

export function yamlParse(text) {
  try {
    return { ok: true, data: YAML.parse(text, { maxAliasCount: 50 }) };
  } catch (e) {
    return { ok: false, error: e.message.split('\n')[0], line: e.linePos?.[0]?.line ?? null };
  }
}

export function yamlDump(data, comment) {
  const doc = new YAML.Document(data);
  if (comment) doc.commentBefore = ' ' + comment.split('\n').join('\n ');
  return doc.toString({ lineWidth: 0 });
}

const POSITIONS = { 'top-left': ['west', 'north'], 'top-right': ['east', 'north'], 'bottom-left': ['west', 'south'], 'bottom-right': ['east', 'south'] };

// Cover-crop to width x height (attention = keep the interesting part), optional logo overlay. JPEG out.
export async function fitImage(image, { width, height, logo, logoPosition = 'bottom-right', logoSizePct = 12, logoMarginPct = 3 }) {
  let img = sharp(image, { failOn: 'error' }).rotate().resize(width, height, { fit: 'cover', position: sharp.strategy.attention });
  if (logo) {
    const lw = Math.round(width * logoSizePct / 100);
    const margin = Math.round(width * logoMarginPct / 100);
    const logoBuf = await sharp(logo).resize({ width: lw }).png().toBuffer();
    const meta = await sharp(logoBuf).metadata();
    const [hx, vy] = POSITIONS[logoPosition] || POSITIONS['bottom-right'];
    img = sharp(await img.toBuffer()).composite([{
      input: logoBuf,
      left: hx === 'west' ? margin : width - lw - margin,
      top: vy === 'north' ? margin : height - meta.height - margin,
    }]);
  }
  return img.jpeg({ quality: 88, mozjpeg: true }).toBuffer();
}

export async function imageInfo(image) {
  const m = await sharp(image).metadata();
  return { width: m.width, height: m.height, format: m.format };
}

// Page count without a PDF library: count page objects. ponytail: naive on exotic PDFs (object streams), Claude still reads the file.
export function pdfPages(buf) {
  const s = buf.toString('latin1');
  const n = (s.match(/\/Type\s*\/Page(?!s)\b/g) || []).length;
  const counts = [...s.matchAll(/\/Count\s+(\d+)/g)].map((m) => Number(m[1]));
  return Math.max(n, counts.length ? Math.max(...counts) : 0);
}

// ---------- HTTP ----------
async function readBody(req, limit = 40_000_000) {
  const chunks = [];
  let size = 0;
  for await (const c of req) {
    size += c.length;
    if (size > limit) throw Object.assign(new Error('request too large'), { status: 413 });
    chunks.push(c);
  }
  return Buffer.concat(chunks);
}

const json = (res, status, obj) => {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(obj));
};

const routes = {
  'GET /health': async () => ({ ok: true, schemas: Object.keys(validators) }),
  'POST /url': async (req) => {
    const { url, max_chars } = JSON.parse(await readBody(req));
    try { return await pageText(url, max_chars); } catch (e) { return { ok: false, error: e.message }; }
  },
  'POST /links': async (req) => checkLinks(JSON.parse(await readBody(req)).urls || []),
  'POST /docx': async (req) => {
    const { value, messages } = await mammoth.extractRawText({ buffer: await readBody(req) });
    return { text: value.replace(/\n{3,}/g, '\n\n').trim(), meta: { chars: value.length, warnings: messages.length } };
  },
  'POST /pdf/info': async (req) => ({ pages: pdfPages(await readBody(req)) }),
  'POST /yaml/parse': async (req) => yamlParse(JSON.parse(await readBody(req)).text || ''),
  'POST /yaml/dump': async (req) => {
    const { data, comment } = JSON.parse(await readBody(req));
    return { text: yamlDump(data, comment) };
  },
  'POST /image/info': async (req) => imageInfo(await readBody(req)),
  // multipart: image (file), logo (file, optional), width, height, logo_position, logo_size_pct, logo_margin_pct
  'POST /image/fit': async (req, res) => {
    const form = await new Response(Readable.toWeb(req), { headers: { 'content-type': req.headers['content-type'] } }).formData();
    const file = async (k) => (form.get(k) && typeof form.get(k) !== 'string' ? Buffer.from(await form.get(k).arrayBuffer()) : null);
    const width = Number(form.get('width'));
    const height = Number(form.get('height'));
    if (!(width > 0 && width <= 4096 && height > 0 && height <= 4096)) throw Object.assign(new Error('bad width/height'), { status: 400 });
    const out = await fitImage(await file('image'), {
      width, height, logo: await file('logo'), logoPosition: form.get('logo_position') || undefined,
      logoSizePct: Number(form.get('logo_size_pct') || 12), logoMarginPct: Number(form.get('logo_margin_pct') || 3),
    });
    res.writeHead(200, { 'content-type': 'image/jpeg', 'x-width': width, 'x-height': height, 'content-length': out.length });
    res.end(out);
  },
};

export const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  const key = `${req.method} ${u.pathname}`;
  try {
    if (req.method === 'POST' && u.pathname.startsWith('/validate/')) {
      return json(res, 200, validate(u.pathname.slice('/validate/'.length), JSON.parse(await readBody(req)).data));
    }
    const h = routes[key];
    if (!h) return json(res, 404, { error: 'not found' });
    const out = await h(req, res);
    if (!res.headersSent) json(res, 200, out);
  } catch (e) {
    if (!res.headersSent) json(res, e.status || 500, { error: e.message });
  }
});

if (process.argv[1] && import.meta.url === `file://${process.argv[1]}`) {
  server.listen(PORT, () => console.log(`extractor on :${PORT}, schemas: ${Object.keys(validators).join(', ') || 'none'}`));
}
