import { q } from '@/lib/db';
import { uuidParam } from '@/lib/format';

// Digest issue preview: our own template's HTML, served as-is. Its no-scripts CSP is set in next.config.ts.

export async function GET(_req: Request, { params }: { params: Promise<{ token: string }> }) {
  const token = uuidParam((await params).token);
  const row = token ? (await q('select html from site.digest_previews where token = $1', [token]))[0] : null;
  if (!row?.html) return new Response('Not found', { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8' } });
  return new Response(row.html, {
    headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'private, no-store' },
  });
}
