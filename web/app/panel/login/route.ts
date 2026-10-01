import type { NextRequest } from 'next/server';
import { NextResponse } from 'next/server';
import { SESSION_COOKIE, q } from '@/lib/db';

// Magic link from the bot (/panel): one-time token -> session cookie -> /panel. Relative redirects keep the public host.
export async function GET(req: NextRequest) {
  const token = req.nextUrl.searchParams.get('token') ?? '';
  const row = /^[0-9a-f]{16,128}$/.test(token) ? (await q('select session_token from panel.login($1)', [token]))[0] : null;
  if (!row) return new Response(null, { status: 303, headers: { location: '/panel/expired' } });
  const res = new NextResponse(null, { status: 303, headers: { location: '/panel', 'cache-control': 'no-store' } });
  res.cookies.set(SESSION_COOKIE, row.session_token, {
    httpOnly: true,
    sameSite: 'lax',
    secure: (process.env.PUBLIC_WEB_URL ?? '').startsWith('https://'),
    path: '/panel',
    maxAge: 7 * 24 * 3600,
  });
  return res;
}
