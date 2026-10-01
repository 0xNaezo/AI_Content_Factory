// Signed outbound links: /r?v=<variant>&u=<url>&s=HMAC-SHA256(SESSION_SECRET, v + '|' + u), hex.
// /r redirects only when the signature matches, so it can never be used as an open redirect.
import { createHmac, timingSafeEqual } from 'node:crypto';

export function sign(v: string, u: string, secret = process.env.SESSION_SECRET): string {
  if (!secret) throw new Error('SESSION_SECRET is not set');
  return createHmac('sha256', secret).update(`${v}|${u}`).digest('hex');
}

export function verify(v: string, u: string, s: string, secret?: string): boolean {
  const expected = Buffer.from(sign(v, u, secret));
  const given = Buffer.from(s);
  return expected.length === given.length && timingSafeEqual(expected, given);
}

export function redirectLink(variant: string, url: string): string {
  return `/r?${new URLSearchParams({ v: variant, u: url, s: sign(variant, url) })}`;
}
