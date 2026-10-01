import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { q } from '@/lib/db';
import { dt, uuidParam } from '@/lib/format';
import { Ext } from '@/components/panel';
import { PreviewMock } from '@/components/preview';

// "How it will look" page of a variant, reachable only by its unguessable token (PB-8, card previews).
export const metadata: Metadata = { title: 'Preview · AI Content Factory', robots: { index: false } };

export default async function Preview({ params }: { params: Promise<{ token: string }> }) {
  const token = uuidParam((await params).token);
  const p = token ? (await q('select * from site.previews where token = $1', [token]))[0] : null;
  if (!p) notFound();
  const img = p.visual_asset_id ? `/media/${p.visual_asset_id}?t=${token}` : undefined;
  return (
    <main className="preview">
      {p.target === 'preview' && <div className="banner">Preview — not published</div>}
      <header className="preview-head">
        <h1>
          {p.brand_name} · {p.platform_label}
        </h1>
        <p>
          <span className={`badge s-${p.status}`}>{String(p.status).replace(/_/g, ' ')}</span> <span className="muted">version {p.version}</span>
        </p>
        <dl>
          {p.proposed_at && (<><dt>Proposed slot</dt><dd>{dt(p.proposed_at)}</dd></>)}
          {p.scheduled_at && (<><dt>Scheduled</dt><dd>{dt(p.scheduled_at)}</dd></>)}
          {p.published_at && (<><dt>Published</dt><dd>{dt(p.published_at)}</dd></>)}
        </dl>
        {p.status === 'published' && p.target !== 'preview' && <Ext href={p.external_url}>Open the published post →</Ext>}
      </header>
      <PreviewMock p={p} img={img} />
    </main>
  );
}
