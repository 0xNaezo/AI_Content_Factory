// Newsletter subscription (DG-5, double opt-in) and one-click unsubscribe (RFC 8058). The web never writes business
// state: every action is a web command handled by n8n -> web_command(). Pages are plain HTML so that the same URL can
// answer GET (a page with buttons) and POST (mail clients send "List-Unsubscribe=One-Click" without cookies).
import { hostBrand } from './db';
import { esc } from './html';
import { slugParam } from './format';

type Result = { ok: boolean; status?: string; error?: string; brand?: string };
type Ctx = { params: Promise<{ brand?: string; token?: string }> };

async function command(action: string, body: Record<string, string>): Promise<Result> {
  const res = await fetch(process.env.N8N_CMD_URL ?? '', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-acf-secret': process.env.N8N_CMD_SECRET ?? '' },
    body: JSON.stringify({ action, body }),
    signal: AbortSignal.timeout(10_000),
    cache: 'no-store',
  });
  if (!res.ok) throw new Error(`web command ${action}: HTTP ${res.status}`);
  return res.json();
}

function page(status: number, title: string, body: string, back: string | null): Response {
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex"><title>${esc(title)}</title><link rel="stylesheet" href="/site.css"></head>
<body><main class="narrow card"><h1>${esc(title)}</h1>${body}${back === null ? '' : `<p class="muted"><a href="${esc(back || '/')}">← Back to the blog</a></p>`}</main></body></html>`;
  return new Response(html, { status, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' } });
}

const unavailable = (back: string) => page(503, 'Temporarily unavailable', '<p>Something went wrong on our side. Please try again in a few minutes.</p>', back);
const badLink = (back: string) => page(404, 'Link not valid', '<p>This link is not valid anymore. If you still get our emails, use the link in the latest one.</p>', back);
const validToken = (t?: string) => !!t && /^[0-9a-f]{16,64}$/.test(t);
const baseOf = (brand?: string) => (slugParam(brand) ? `/b/${brand}` : '');

// ponytail: in-memory per-process limit on the public form; move to Redis/DB if the web runs as several instances.
const hits = new Map<string, { n: number; reset: number }>();
function limited(key: string, max = 10, windowMs = 10 * 60_000): boolean {
  const now = Date.now();
  const h = hits.get(key);
  if (!h || h.reset < now) {
    if (hits.size > 10_000) hits.clear();
    hits.set(key, { n: 1, reset: now + windowMs });
    return false;
  }
  return ++h.n > max;
}

/** POST /b/<brand>/subscribe, or /subscribe on a custom blog domain. */
export async function subscribePOST(req: Request, { params }: Ctx): Promise<Response> {
  const { brand: fromPath } = await params;
  const brand = fromPath !== undefined ? slugParam(fromPath) : await hostBrand();
  const back = baseOf(fromPath);
  if (!brand) return page(404, 'Not found', '<p>There is no newsletter here.</p>', null);
  // First X-Forwarded-For entry: the reverse proxy (Caddy) replaces client-supplied values.
  const ip = req.headers.get('x-forwarded-for')?.split(',')[0].trim() || 'direct';
  if (limited(ip)) return page(429, 'Too many attempts', '<p>Please wait a few minutes and try again.</p>', back);
  const form = await req.formData().catch(() => null);
  const email = String(form?.get('email') ?? '').trim().slice(0, 320);
  try {
    const r = await command('subscribe', { brand, email });
    if (r.ok && r.status === 'confirmed') return page(200, 'Already subscribed', '<p>This address already receives the newsletter.</p>', back);
    if (r.ok) {
      return page(200, 'Check your inbox', `<p>We sent a confirmation link to <b>${esc(email)}</b>. Click it to start receiving the newsletter.</p>
<p class="muted">Nothing arrived? Check the spam folder or try again in an hour.</p>`, back);
    }
    if (r.error === 'invalid email') return page(400, 'Invalid email', '<p>Please go back and enter a valid email address.</p>', back);
    return page(404, 'Not found', '<p>This newsletter is not available.</p>', back);
  } catch (e) {
    console.error('subscribe failed:', (e as Error).message);
    return unavailable(back);
  }
}

/** GET /b/<brand>/confirm/<token> and /confirm/<token>: the link from the confirmation email. */
export async function confirmGET(_req: Request, { params }: Ctx): Promise<Response> {
  const { brand, token } = await params;
  const back = baseOf(brand);
  if (!validToken(token)) return badLink(back);
  try {
    const r = await command('confirm', { token: token! });
    if (!r.ok) return badLink(back);
    return page(200, 'Subscription confirmed', `<p>Thank you! You will receive the ${esc(r.brand ?? '')} newsletter.</p>
<p class="muted">Every email has a one-click unsubscribe link.</p>`, back);
  } catch (e) {
    console.error('confirm failed:', (e as Error).message);
    return unavailable(back);
  }
}

const button = (op: string, label: string, cls = '') => `<form method="post"><button name="op" value="${op}"${cls ? ` class="${cls}"` : ''}>${label}</button></form>`;

/** GET /b/<brand>/unsubscribe/<token> and /unsubscribe/<token>: confirmation page (link scanners must not unsubscribe). */
export async function unsubscribeGET(_req: Request, { params }: Ctx): Promise<Response> {
  const { brand, token } = await params;
  if (!validToken(token)) return badLink(baseOf(brand));
  return page(200, 'Unsubscribe', `<p>Stop receiving this newsletter?</p><div class="actions">${button('unsubscribe', 'Unsubscribe')}
${button('delete', 'Delete my data', 'secondary')}</div><p class="muted">“Delete my data” removes your email address from our list completely.</p>`, baseOf(brand));
}

/** POST to the same URL: form buttons (op=unsubscribe|resubscribe|delete) or RFC 8058 one-click (no op -> unsubscribe). */
export async function unsubscribePOST(req: Request, { params }: Ctx): Promise<Response> {
  const { brand, token } = await params;
  const back = baseOf(brand);
  if (!validToken(token)) return badLink(back);
  const form = await req.formData().catch(() => null);
  const asked = String(form?.get('op') ?? 'unsubscribe');
  const op = ['unsubscribe', 'resubscribe', 'delete'].includes(asked) ? asked : 'unsubscribe';
  try {
    const r = await command(op, { token: token! });
    if (!r.ok) return badLink(back);
    const name = esc(r.brand ?? 'this newsletter');
    if (op === 'delete') return page(200, 'Your data was deleted', '<p>We no longer store your email address. You will not receive any more emails.</p>', back);
    if (op === 'resubscribe') return page(200, 'Welcome back', `<p>You are subscribed to ${name} again.</p>${button('unsubscribe', 'Unsubscribe')}`, back);
    return page(200, 'You are unsubscribed', `<p>You will not receive more emails from ${name}.</p><div class="actions">
${button('resubscribe', 'Resubscribe')}${button('delete', 'Delete my data', 'secondary')}</div>`, back);
  } catch (e) {
    console.error('unsubscribe failed:', (e as Error).message);
    return unavailable(back);
  }
}
