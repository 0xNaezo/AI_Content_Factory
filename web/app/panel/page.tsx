import { panel } from '@/lib/db';
import { dt } from '@/lib/format';
import { Badge, Shell } from '@/components/panel';

export default async function Overview() {
  const { me, brands, queue, materials } = await panel(async (db, me) => ({
    me,
    brands: (await db.query('select id, name, role, timezone, status from panel.brands order by name')).rows,
    queue: (await db.query('select brand_name, count(*) as n, min(created_at) as oldest from panel.queue group by 1 order by 1')).rows,
    materials: (await db.query('select id, code, created_at, status, brands, main_idea, published, variants from panel.materials order by created_at desc limit 10')).rows,
  }));
  const pending = queue.reduce((sum, r) => sum + Number(r.n), 0);
  return (
    <Shell me={me} active="/panel" title="Overview">
      <div className="cards">
        <section className="card">
          <h2>My brands</h2>
          {brands.length === 0 && <p className="muted">No brands.</p>}
          <ul className="plain">
            {brands.map((b) => (
              <li key={b.id}>
                <b>{b.name}</b> <span className="muted">· {b.role ?? 'author'} · {b.timezone}</span> {b.status !== 'active' && <Badge value={b.status} />}
              </li>
            ))}
          </ul>
        </section>
        <section className="card">
          <h2>
            Pending approval: <a href="/panel/queue">{pending}</a>
          </h2>
          <ul className="plain">
            {queue.map((r) => (
              <li key={r.brand_name}>
                {r.brand_name}: <b>{r.n}</b> <span className="muted">· oldest {dt(r.oldest)}</span>
              </li>
            ))}
          </ul>
        </section>
      </div>
      <h2>Recent materials</h2>
      <div className="table-wrap">
        <table>
          <thead>
            <tr><th>Material</th><th>Received</th><th>Status</th><th>Brands</th><th>Main idea</th><th>Published</th></tr>
          </thead>
          <tbody>
            {materials.map((m) => (
              <tr key={m.id}>
                <td><a href={`/panel/materials/${m.id}`}>{m.code}</a></td>
                <td className="nowrap">{dt(m.created_at)}</td>
                <td><Badge value={m.status} /></td>
                <td>{m.brands ?? '—'}</td>
                <td>{m.main_idea ?? '—'}</td>
                <td>{m.published}/{m.variants}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {materials.length === 0 && <p className="muted">No materials yet.</p>}
    </Shell>
  );
}
