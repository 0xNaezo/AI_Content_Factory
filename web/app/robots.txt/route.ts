import type { NextRequest } from 'next/server';

// Crawlers: blogs yes; panel, token previews, media by token and redirects no.
export function GET(req: NextRequest) {
  const proto = req.headers.get('x-forwarded-proto') || (process.env.PUBLIC_WEB_URL?.startsWith('http://') ? 'http' : 'https');
  const origin = `${proto}://${req.headers.get('host') ?? ''}`;
  const text = ['User-agent: *', 'Disallow: /panel', 'Disallow: /p/', 'Disallow: /d/', 'Disallow: /r', 'Disallow: /api/', '',
    `Sitemap: ${origin}/sitemap.xml`, ''].join('\n');
  return new Response(text, { headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'public, max-age=86400' } });
}
