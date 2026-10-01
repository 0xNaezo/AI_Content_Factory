import { notFound } from 'next/navigation';
import { panel, type Row } from '@/lib/db';
import { dt, idParam, usd } from '@/lib/format';
import { Badge, Ext, Json, Shell } from '@/components/panel';

// Trace by material ID (tz section 8): what came in, what was generated, checks, who approved, where and when it was
// published, and what it cost — audit, jobs, AI calls and publish attempts on one timeline.
export default async function MaterialDetail({ params }: { params: Promise<{ id: string }> }) {
  const id = idParam((await params).id);
  if (!id) notFound();
  const { me, m, variants, versions, events } = await panel(async (db, me) => {
    const m = (await db.query('select * from panel.material_detail where id = $1', [id])).rows[0];
    if (!m) notFound();
    const variants = (await db.query('select * from panel.variants where material_id = $1 order by brand_name, platform', [id])).rows;
    const versions = (await db.query('select * from panel.variant_versions where variant_id = any($1::bigint[]) order by variant_id, version desc', [
      variants.map((v) => v.id),
    ])).rows;
    const events = (await db.query('select * from panel.material_events where material_id = $1 order by at, kind', [id])).rows;
    return { me, m, variants, versions, events };
  });
  const s: Row = m.summary ?? {};
  const list = (v: unknown) => (Array.isArray(v) ? v : []);
  return (
    <Shell me={me} active="/panel/materials" title={<>{m.code} <Badge value={m.status} /></>}>
      <dl className="facts">
        <dt>Received</dt><dd>{dt(m.created_at)} via {m.source}</dd>
        <dt>Author</dt><dd>{m.author ?? '—'}</dd>
        <dt>Brands</dt><dd>{m.brands ?? '—'}</dd>
        <dt>Content</dt><dd>{m.parts}</dd>
        <dt>AI cost</dt><dd>{usd(m.cost_usd)}</dd>
        {m.low_data && (<><dt>Note</dt><dd>generated with little source data</dd></>)}
        {m.reject_reason && (<><dt>Rejected</dt><dd>{m.reject_reason}</dd></>)}
      </dl>

      <h2>Summary</h2>
      {s.main_idea ? <p className="lead">{s.main_idea}</p> : <p className="muted">No summary yet.</p>}
      {list(s.key_points).length > 0 && <ul>{list(s.key_points).map((k, i) => <li key={i}>{String(k)}</li>)}</ul>}
      {list(s.facts).length > 0 && (
        <>
          <h3>Facts</h3>
          <ul>{list(s.facts).map((f, i) => <li key={i}>{f?.fact} <span className="muted">— “{f?.source_quote}”</span></li>)}</ul>
        </>
      )}
      {list(s.links).length > 0 && (
        <p>Links: {list(s.links).map((l, i) => <span key={i}><Ext href={l}>{String(l)}</Ext> </span>)}</p>
      )}
      <details>
        <summary>Source text, hints and raw summary</summary>
        <pre className="source">{m.source_text ?? '—'}</pre>
        <p>Hints: <Json value={m.hints} /></p>
        <p>Summary: <Json value={m.summary} /></p>
      </details>

      <h2>Variants</h2>
      {variants.length === 0 && <p className="muted">No variants.</p>}
      {variants.map((v) => (
        <section key={v.id} className="card variant">
          <h3>
            {v.brand_name} · {v.platform_label} <Badge value={v.status} /> <span className="muted small">checks: {v.check_status} · target: {v.target}</span>
          </h3>
          <p className="muted small">
            {v.proposed_at && <>proposed {dt(v.proposed_at)} · </>}
            {v.scheduled_at && <>scheduled {dt(v.scheduled_at)} · </>}
            {v.published_at && <>published {dt(v.published_at)} · </>}
            {v.approved_by ? <>approved by {v.approved_by} · </> : v.auto_approved ? <>auto-approved · </> : null}
            <a href={`/p/${v.preview_token}`}>preview</a> <Ext href={v.external_url}>· published post</Ext>
          </p>
          <div className="mock-text excerpt">{v.text}</div>
          <table className="versions">
            <thead>
              <tr><th>Version</th><th>Created</th><th>Author</th><th>Reason</th><th>Checks</th></tr>
            </thead>
            <tbody>
              {versions.filter((x) => x.variant_id === v.id).map((x) => (
                <tr key={x.version}>
                  <td>v{x.version}</td>
                  <td className="nowrap">{dt(x.created_at)}</td>
                  <td>{x.author_kind === 'ai' ? 'AI' : x.author ?? 'human'}</td>
                  <td>{x.reason}{x.comment && <span className="muted"> — {x.comment}</span>}</td>
                  <td>
                    {list(x.checks).map((c) => (
                      <span key={c.check} className={`badge s-${c.status}`} title={JSON.stringify(c.details)}>
                        {c.check}{c.required ? '' : ' (opt)'}: {c.status}
                      </span>
                    ))}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      ))}

      <h2>Timeline</h2>
      <div className="table-wrap">
        <table>
          <thead>
            <tr><th>Time</th><th>Kind</th><th>Event</th><th>Actor</th><th>Cost</th><th>Details</th></tr>
          </thead>
          <tbody>
            {events.map((e, i) => (
              <tr key={i}>
                <td className="nowrap">{dt(e.at)}</td>
                <td><span className={`badge k-${e.kind}`}>{e.kind}</span></td>
                <td>{e.title}{e.entity && <span className="muted small"> · {e.entity} {e.entity_id}</span>}</td>
                <td>{e.actor}</td>
                <td>{e.cost_usd == null ? '' : usd(e.cost_usd)}</td>
                <td><Json value={e.details} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </Shell>
  );
}
