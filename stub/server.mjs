// Fake external services for end-to-end tests (scripts/e2e.sh): Telegram Bot API + file downloads, Anthropic Messages,
// OpenRouter (speech-to-text, images, embeddings), Resend (send, batch, status, inbound). No dependencies.
// Answers are schema-driven: structured-output requests get a minimal valid object shaped by the request's JSON schema.
import http from 'node:http';

const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAACAAAAASCAIAAAC1qksFAAAAH0lEQVR42mMwTptJU8QwasGoBaMWjFowasGoBfSwAACPV7CfP1Oc2AAAAABJRU5ErkJggg==', 'base64');
// 500-row content plan for the table acceptance run: rows 50/150/250/350/450 name an unknown brand, 99/199/299 have no text
const CSV500 = 'Brand,Topic or text,Platforms\n' + Array.from({ length: 500 }, (_, k) => {
  const i = k + 1;
  if (i % 100 === 50) return `nope,Row ${i},telegram`;
  if (i % 100 === 99 && i < 300) return 'e2e-brand,,telegram';
  return `e2e-brand,"Plan item ${i}: ${['tasting', 'workshop', 'meetup', 'release', 'interview'][i % 5]} ${i * 7919 % 1000}",telegram`;
}).join('\n') + '\n';
const PDF = Buffer.from('%PDF-1.4\n1 0 obj <</Type /Catalog /Pages 2 0 R>> endobj\n2 0 obj <</Type /Pages /Count 1 /Kids [3 0 R]>> endobj\n3 0 obj <</Type /Page>> endobj\ntrailer <</Root 1 0 R>>\n%%EOF\n');
const calls = [];
const state = { tgFail: 0, anthropicFail: 0, inboundTo: 'in+0000000000000000@in.example.com' };
let seq = 1000;

const json = (res, status, obj) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };

async function body(req) {
  const type = String(req.headers['content-type'] || '');
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const buf = Buffer.concat(chunks);
  if (type.startsWith('multipart/form-data')) {
    const form = await new Response(buf, { headers: { 'content-type': type } }).formData();
    const out = {};
    for (const [k, v] of form.entries()) out[k] = typeof v === 'string' ? v : { file: v.name, type: v.type, size: v.size };
    return out;
  }
  if (!buf.length) return {};
  try { return JSON.parse(buf.toString('utf8')); } catch { return { raw: buf.toString('utf8').slice(0, 500) }; }
}

function chatOf(id) {
  const s = String(id ?? '');
  return s.startsWith('@') ? { id: -1001000000000 - (s.length % 97), type: 'channel', title: s.slice(1), username: s.slice(1) }
    : { id: Number(s), type: Number(s) < 0 ? 'channel' : 'private' };
}

function telegram(method, b) {
  const isChannel = String(b.chat_id ?? '').startsWith('@') || String(b.chat_id ?? '').startsWith('-100');
  if (state.tgFail > 0 && isChannel && /^send/.test(method)) { state.tgFail--; return [500, { ok: false, error_code: 500, description: 'Internal Server Error (stub)' }]; }
  const message = (extra) => ({ ok: true, result: { message_id: ++seq, date: Math.floor(Date.now() / 1000), chat: chatOf(b.chat_id), ...extra } });
  // like the real API: a file field must be an upload or a file_id / URL string; media JSON may point at attach://<field>
  const need = { sendPhoto: 'photo', sendDocument: 'document', editMessageMedia: 'media' }[method];
  if (need && !b[need]) return [400, { ok: false, error_code: 400, description: `Bad Request: there is no ${need} in the request` }];
  if (method === 'editMessageMedia') {
    const m = typeof b.media === 'string' ? JSON.parse(b.media) : b.media;
    const ref = String(m?.media ?? '');
    if (ref.startsWith('attach://') && !b[ref.slice(9)]?.file) return [400, { ok: false, error_code: 400, description: 'Bad Request: file must be uploaded' }];
  }
  switch (method) {
    case 'getMe': return [200, { ok: true, result: { id: 1, is_bot: true, first_name: 'ACF stub', username: 'acf_stub_bot' } }];
    case 'getFile': return [200, { ok: true, result: { file_id: b.file_id, file_unique_id: 'u' + b.file_id, file_size: 2048, file_path: 'files/' + b.file_id } }];
    case 'sendMessage': return [200, message({ text: b.text })];
    case 'sendPhoto': return [200, message({ caption: b.caption, photo: [{ file_id: 'stubphoto' + seq, file_unique_id: 'up' + seq, width: 16, height: 9 }] })];
    case 'sendDocument': return [200, message({ caption: b.caption, document: { file_id: 'stubdoc' + seq, file_name: b.document?.file || 'file' } })];
    case 'editMessageText': case 'editMessageCaption': case 'editMessageMedia':
      return [200, { ok: true, result: { message_id: Number(b.message_id), chat: chatOf(b.chat_id), date: Math.floor(Date.now() / 1000) } }];
    default: return [200, { ok: true, result: true }];  // deleteMessage, answerCallbackQuery, setWebhook, setMyCommands…
  }
}

function tgFile(id) {
  if (/^(voice|audio)/.test(id)) return ['audio/ogg', Buffer.from('OggS stub audio ' + id)];
  if (/^pdf/.test(id)) return ['application/pdf', PDF];
  if (/^csv500/.test(id)) return ['text/csv', Buffer.from(CSV500)];
  if (/^csv/.test(id)) return ['text/csv', Buffer.from('Brand,Topic or text,Platforms\ne2e-brand,Row one: open mic night on Friday,telegram\n')];
  if (/^yaml/.test(id)) return ['application/octet-stream', Buffer.from(state.yaml || 'brand:\n  name: [broken\n')];
  return ['image/png', PNG];
}

// ---- Anthropic: minimal object valid for the requested schema, with pipeline-friendly content ----
const WORDS = (n, w = 'stub') => Array.from({ length: n }, (_, i) => `${w}${i % 7 === 6 ? '.' : ''}`).join(' ');
function fake(s, key) {
  if (!s || typeof s !== 'object') return null;
  if (s.enum) return s.enum[0];
  const types = Array.isArray(s.type) ? s.type : [s.type];
  if (types.includes('null') && !['cta'].includes(key)) return null;
  if (types.includes('object') || s.properties) return Object.fromEntries(Object.entries(s.properties || {}).map(([k, v]) => [k, fake(v, k)]));
  if (types.includes('array')) return ({ languages: ['en'], palette: ['#336699'], key_points: ['stub point'], headline_options: ['Stub headline A', 'Stub headline B', 'Stub headline C'] })[key] ?? [];
  if (types.includes('boolean')) return ({ sufficient: true, ok: true, suitable_as_visual: true })[key] ?? false;
  if (types.includes('integer') || types.includes('number')) return ({ max: 3 })[key] ?? 1;
  return ({ timezone: 'UTC', language: 'en', address: 'informal', emoji: 'sparing', name: 'Stub Brand' })[key] ?? `stub ${key} text`;
}

function anthropic(b) {
  if (state.anthropicFail > 0) { state.anthropicFail--; return [529, { type: 'error', error: { type: 'overloaded_error', message: 'Overloaded (stub)' } }]; }
  const text = JSON.stringify(b.messages) + JSON.stringify(b.system || '');
  const schema = b.output_config?.format?.schema;
  const snippet = (text.match(/\[Text\]\\n([^\\"]{10,200})/) || text.match(/\[Voice message transcript\]\\n([^\\"]{10,200})/) || [])[1] || 'stub material';
  let out;
  if (!schema) out = 'Stub text of the document: jazz evening on Thursday at 20:00.';
  else {
    out = fake(schema, 'root');
    const p = schema.properties || {};
    if (p.ranking) {
      const slugs = [...new Set([...text.matchAll(/\\"slug\\":\s*\\"([a-z0-9-]+)\\"/g)].map((m) => m[1]))];
      out = { ranking: slugs.map((s, i) => ({ brand: s, confidence: i === 0 ? 0.92 : 0.1, reason: 'stub' })), off_topic: false, reason: 'stub' };
    }
    if (p.main_idea) Object.assign(out, { main_idea: snippet.slice(0, 120), sufficient: true, clarifying_question: null, language: 'en' });
    if (p.claims) Object.assign(out, { claims: [], language: 'en', forbidden_topics: [], summary: 'stub check: nothing unsupported' });
    if (p.text) out.text = ('Stub post: ' + snippet).slice(0, 300);
    if (p.posts) out.posts = ['Stub thread, post one.', 'Stub thread, post two.'];
    if (p.sections) Object.assign(out, { title: 'Stub article', slug: 'stub-article-' + (++seq), lead: 'Stub lead.',
      sections: [{ heading: 'Part one', body_md: WORDS(360) }, { heading: 'Part two', body_md: WORDS(360) }], seo_description: 'Stub SEO description' });
    if (p.body && p.link_label) Object.assign(out, { title: 'Stub block', body: WORDS(80), link_label: 'Read more' });
    if (p.order) out.order = [...text.matchAll(/\\"index\\":\s*(\d+)/g)].map((m) => Number(m[1]));
    if (p.has_people) Object.assign(out, { has_people: false, has_text: false, has_third_party_logos: false, has_artifacts: false, ok: true, notes: 'stub' });
    if (p.basics) out.basics.description = 'A stub brand generated by the test stub.';
    out = JSON.stringify(out);
  }
  return [200, { id: 'msg_stub_' + (++seq), type: 'message', role: 'assistant', model: b.model, content: [{ type: 'text', text: out }],
    stop_reason: 'end_turn', usage: { input_tokens: 1200, output_tokens: 300, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 } }];
}

function vector(text) {
  let h = 2166136261;
  for (const ch of String(text)) h = Math.imul(h ^ ch.charCodeAt(0), 16777619) >>> 0;
  return Array.from({ length: 1536 }, () => { h = Math.imul(h ^ (h >>> 15), 2246822507) >>> 0; return (h / 4294967295) * 2 - 1; });
}

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://stub');
  const path = u.pathname;
  try {
    if (path === '/health') return json(res, 200, { ok: true });
    if (path === '/calls') return json(res, 200, { calls: calls.slice(Number(u.searchParams.get('since') || 0)), next: calls.length });
    if (path === '/reset') { calls.length = 0; Object.assign(state, { tgFail: 0, anthropicFail: 0, anthropicDelay: 0 }); return json(res, 200, { ok: true }); }
    if (path === '/control') { Object.assign(state, await body(req)); return json(res, 200, state); }
    let m;
    if ((m = path.match(/^\/tg\/(\w+)$/))) {
      const b = await body(req);
      calls.push({ service: 'tg', method: m[1], body: b });
      const [s, r] = telegram(m[1], b);
      return json(res, s, r);
    }
    if ((m = path.match(/^\/tgfile\/files\/(.+)$/))) {
      const [type, buf] = tgFile(decodeURIComponent(m[1]));
      calls.push({ service: 'tgfile', file: m[1] });
      res.writeHead(200, { 'content-type': type, 'content-length': buf.length });
      return res.end(buf);
    }
    if (path === '/anthropic/v1/messages') {
      const b = await body(req);
      if (state.anthropicDelay) await new Promise((r) => setTimeout(r, state.anthropicDelay));  // e2e: keep a call in flight
      calls.push({ service: 'anthropic', model: b.model, schema: !!b.output_config?.format, effort: b.output_config?.effort, cached: JSON.stringify(b.system || '').includes('cache_control'),
                   key: req.headers['x-api-key'] ? 'present' : 'missing' });
      const [s, r] = anthropic(b);
      return json(res, s, r);
    }
    if ((m = path.match(/^\/openrouter\/(audio\/transcriptions|images|embeddings)$/))) {
      const b = await body(req);
      calls.push({ service: 'openrouter', kind: m[1], model: b.model, auth: req.headers.authorization ? 'present' : 'missing' });
      if (m[1] === 'audio/transcriptions') return json(res, 200, { text: 'Stub transcript: jazz evening on Thursday at 20:00 in the garden.', usage: { cost: 0.0012, seconds: 12 } });
      if (m[1] === 'images') return json(res, 200, { data: [{ b64_json: PNG.toString('base64') }], usage: { cost: 0.039 } });
      const inputs = Array.isArray(b.input) ? b.input : [b.input];
      return json(res, 200, { data: inputs.map((t, i) => ({ index: i, embedding: vector(t) })), usage: { cost: 0.00002 } });
    }
    if (path.startsWith('/resend/')) {
      const b = req.method === 'POST' ? await body(req) : {};
      calls.push({ service: 'resend', method: req.method, path: path.slice(7), idempotency: req.headers['idempotency-key'] || null,
                   auth: req.headers.authorization ? 'present' : 'missing', to: b.to ?? (Array.isArray(b) ? b.length + ' emails' : undefined) });
      if (path === '/resend/emails' && req.method === 'POST') return json(res, 200, { id: 'stub-mail-' + (++seq) });
      if (path === '/resend/emails/batch') return json(res, 200, { data: (Array.isArray(b) ? b : []).map(() => ({ id: 'stub-mail-' + (++seq) })) });
      if ((m = path.match(/^\/resend\/emails\/receiving\/([^/]+)\/attachments$/))) {
        return json(res, 200, { object: 'list', data: [{ id: 'att-1', filename: 'poster.png', content_type: 'image/png', size: PNG.length,
          download_url: 'http://stub:3000/files/poster.png' }] });
      }
      if ((m = path.match(/^\/resend\/emails\/receiving\/([^/]+)$/))) {
        const withFile = m[1].startsWith('att');
        return json(res, 200, { object: 'email', id: m[1], from: 'E2E Author <author@e2e.test>', to: [state.inboundTo], cc: [],
          subject: 'Jazz evening', text: 'Email material: jazz evening on Thursday at 20:00 in the garden, tickets at the door.', html: null,
          attachments: withFile ? [{ id: 'att-1', filename: 'poster.png', content_type: 'image/png', size: PNG.length }] : [] });
      }
      if ((m = path.match(/^\/resend\/emails\/([^/]+)$/))) return json(res, 200, { object: 'email', id: m[1], last_event: 'delivered' });
      return json(res, 404, { message: 'not found' });
    }
    if (path === '/files/poster.png') { res.writeHead(200, { 'content-type': 'image/png' }); return res.end(PNG); }
    if (path === '/rss.xml') {  // a brand's external source for the digest (DG-2)
      const items = ['Community gardens are growing in cities', 'How to repair a bike chain at home', 'Local markets add Sunday hours']
        .map((t, i) => `<item><title>${t}</title><link>http://stub:3000/news/${i + 1}</link><guid>stub-news-${i + 1}</guid>` +
             `<pubDate>${new Date(Date.now() - i * 3600e3).toUTCString()}</pubDate><description>${t}. A short stub summary.</description></item>`).join('');
      res.writeHead(200, { 'content-type': 'application/rss+xml' });
      return res.end(`<?xml version="1.0"?><rss version="2.0"><channel><title>Stub news</title><link>http://stub:3000/</link><description>Stub</description>${items}</channel></rss>`);
    }
    json(res, 404, { error: 'not found' });
  } catch (e) {
    json(res, 500, { error: e.message });
  }
});

server.listen(3000, () => console.log('stub on :3000'));
