import type { NextRequest } from 'next/server';
import { hostBrand, q } from '@/lib/db';
import { esc } from '@/lib/html';

// SEO sitemap (architecture 7.9) for the requesting host only: a brand domain lists that brand's blog, the main host
// lists the blogs served under /b/<brand>. URLs come from the DB (site.brands.blog_url, site.posts.url).
export async function GET(req: NextRequest) {
  const host = req.headers.get('host') ?? '';
  const brand = await hostBrand();
  const where = brand ? 'where brand_slug = $1' : '';
  const [blogs, posts] = await Promise.all([
    q(`select blog_url as loc, null as lastmod from site.brands ${brand ? 'where slug = $1' : ''}`, brand ? [brand] : []),
    q(`select url as loc, published_at as lastmod from site.posts ${where} order by published_at desc limit 5000`, brand ? [brand] : []),
  ]);
  const urls = [...blogs, ...posts].filter((u) => URL.canParse(u.loc) && new URL(u.loc).host === host);
  const body = urls
    .map((u) => `<url><loc>${esc(u.loc)}</loc>${u.lastmod ? `<lastmod>${new Date(u.lastmod).toISOString()}</lastmod>` : ''}</url>`)
    .join('\n');
  return new Response(`<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${body}\n</urlset>\n`, {
    headers: { 'content-type': 'application/xml; charset=utf-8', 'cache-control': 'public, max-age=3600' },
  });
}
