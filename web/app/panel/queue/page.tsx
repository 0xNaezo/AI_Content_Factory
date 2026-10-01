import { panel } from '@/lib/db';
import { dt, duration } from '@/lib/format';
import { Badge, Shell } from '@/components/panel';

// Variants waiting for an editor, oldest first.
export default async function Queue() {
  const { me, rows } = await panel(async (db, me) => ({
    me,
    rows: (await db.query(
      `select variant_id, material_id, brand_name, platform_label, status, check_status, proposed_at, created_at, excerpt, preview_token,
              extract(epoch from age)::bigint as age_s
       from panel.queue order by created_at, variant_id`,
    )).rows,
  }));
  return (
    <Shell me={me} active="/panel/queue" title={`Approval queue (${rows.length})`}>
      {rows.length === 0 && <p className="muted">Nothing is waiting for approval.</p>}
      <div className="table-wrap">
        <table>
          <thead>
            <tr><th>Waiting</th><th>Brand · platform</th><th>Status</th><th>Checks</th><th>Proposed slot</th><th>Text</th><th /></tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.variant_id}>
                <td className="nowrap">{duration(r.age_s)}</td>
                <td>{r.brand_name} · {r.platform_label}</td>
                <td><Badge value={r.status} /></td>
                <td><Badge value={r.check_status} /></td>
                <td className="nowrap">{dt(r.proposed_at)}</td>
                <td className="excerpt-cell">{r.excerpt}</td>
                <td className="nowrap">
                  <a href={`/p/${r.preview_token}`}>Preview</a> · <a href={`/panel/materials/${r.material_id}`}>M-{r.material_id}</a>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </Shell>
  );
}
