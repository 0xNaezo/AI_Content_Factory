import type { NextRequest } from 'next/server';
import { brandForHost } from '@/lib/db';

// Caddy on-demand TLS "ask" endpoint: 200 for the public web host or an active brand's blog domain, else 404.
// Read-only (cached host map, site.brands via app_web), no auth, no side effects.
export async function GET(req: NextRequest) {
  const domain = (req.nextUrl.searchParams.get('domain') ?? '').trim().toLowerCase().replace(/\.$/, '');
  const own = URL.canParse(process.env.PUBLIC_WEB_URL ?? '') ? new URL(process.env.PUBLIC_WEB_URL!).hostname : null;
  const ok = !!domain && (domain === own || (await brandForHost(domain)) !== null);
  return new Response(null, { status: ok ? 200 : 404, headers: { 'cache-control': 'no-store' } });
}
