import type { NextRequest } from 'next/server';
import { q } from '@/lib/db';
import { httpUrl } from '@/lib/html';
import { verify } from '@/lib/sign';

// Outbound link from an article: redirect only with a valid signature (no open redirect), counting the click.
export async function GET(req: NextRequest) {
  const sp = req.nextUrl.searchParams;
  const v = sp.get('v') ?? '';
  const u = sp.get('u') ?? '';
  const s = sp.get('s') ?? '';
  if (!/^\d{1,18}$/.test(v) || !httpUrl(u) || !verify(v, u, s)) {
    return new Response('Invalid link', { status: 400, headers: { 'content-type': 'text/plain; charset=utf-8' } });
  }
  await q('select site.count_click(brand_id, variant_id, $2) from site.posts where variant_id = $1', [v, u]).catch((e) =>
    console.error('count_click failed:', e.message),
  );
  return new Response(null, { status: 302, headers: { location: u, 'cache-control': 'no-store' } });
}
