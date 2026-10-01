import type { NextRequest } from 'next/server';
import { NextResponse } from 'next/server';
import { SESSION_COOKIE, q } from '@/lib/db';

// Ends the session in the DB and clears the cookie.
export async function POST(req: NextRequest) {
  const token = req.cookies.get(SESSION_COOKIE)?.value;
  if (token) await q('select panel.logout($1)', [token]);
  const res = new NextResponse(null, { status: 303, headers: { location: '/panel/expired?out=1' } });
  res.cookies.set(SESSION_COOKIE, '', { httpOnly: true, sameSite: 'lax', path: '/panel', maxAge: 0 });
  return res;
}

export const GET = POST;
