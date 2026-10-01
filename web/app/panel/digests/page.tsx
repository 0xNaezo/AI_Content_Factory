import { panel } from '@/lib/db';
import { dt } from '@/lib/format';
import { Badge, Shell } from '@/components/panel';

// Email digest issues with delivery stats (DG-6) and the preview link.
const STATS = ['sent', 'delivered', 'opened', 'clicked', 'bounced', 'complained', 'unsubscribed'];

export default async function Digests() {
  const { me, rows } = await panel(async (db, me) => ({
    me,
    rows: (await db.query('select id, brand_name, send_at, status, subject, stats, preview_token, blocks from panel.digests order by send_at desc limit 100')).rows,
  }));
  return (
    <Shell me={me} active="/panel/digests" title="Digests">
      {rows.length === 0 && <p className="muted">No digest issues yet.</p>}
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Send at</th><th>Brand</th><th>Status</th><th>Subject</th><th>Blocks</th>
              {STATS.map((s) => <th key={s}>{s}</th>)}
              <th>Open rate</th><th />
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const st = r.stats ?? {};
              const rate = st.delivered > 0 ? `${Math.round((100 * (st.opened ?? 0)) / st.delivered)}%` : '—';
              return (
                <tr key={r.id}>
                  <td className="nowrap">{dt(r.send_at)}</td>
                  <td>{r.brand_name}</td>
                  <td><Badge value={r.status} /></td>
                  <td>{r.subject ?? '—'}</td>
                  <td>{r.blocks}</td>
                  {STATS.map((s) => <td key={s}>{st[s] ?? '—'}</td>)}
                  <td>{rate}</td>
                  <td><a href={`/d/${r.preview_token}`}>Preview</a></td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </Shell>
  );
}
