import { panel } from '@/lib/db';
import { dt, idParam, materialParam, oneOf, pageParam, param, usd, type SP } from '@/lib/format';
import { Badge, Filters, Pager, Select, Shell } from '@/components/panel';

const STATUSES = ['received', 'parsed', 'awaiting_author', 'routed', 'rejected'];
const PER_PAGE = 50;

export default async function Materials({ searchParams }: { searchParams: Promise<SP> }) {
  const sp = await searchParams;
  const brand = idParam(param(sp, 'brand'));
  const status = oneOf(param(sp, 'status'), STATUSES);
  const code = param(sp, 'q');
  const id = materialParam(code);
  const page = pageParam(param(sp, 'page'));
  const { me, brands, rows } = await panel(async (db, me) => ({
    me,
    brands: (await db.query('select id, name from panel.brands order by name')).rows,
    rows: code && !id ? [] : (await db.query(
      `select id, code, created_at, status, source, author, brands, main_idea, variants, published, cost_usd, is_own
       from panel.materials
       where ($1::bigint is null or $1 = any(brand_ids)) and ($2::text is null or status = $2) and ($3::bigint is null or id = $3)
       order by created_at desc, id desc limit $4 offset $5`,
      [brand, status, id, PER_PAGE + 1, (page - 1) * PER_PAGE],
    )).rows,
  }));
  return (
    <Shell me={me} active="/panel/materials" title="Materials">
      <Filters>
        <label>
          Code
          <input name="q" defaultValue={code ?? ''} placeholder="M-123" size={10} />
        </label>
        <Select name="brand" label="Brand" value={brand} options={brands.map((b) => [String(b.id), b.name])} />
        <Select name="status" label="Status" value={status} options={STATUSES.map((s) => [s, s.replace('_', ' ')])} />
      </Filters>
      <div className="table-wrap">
        <table>
          <thead>
            <tr><th>Material</th><th>Received</th><th>Status</th><th>Source</th><th>Author</th><th>Brands</th><th>Main idea</th><th>Published</th><th>AI cost</th></tr>
          </thead>
          <tbody>
            {rows.slice(0, PER_PAGE).map((m) => (
              <tr key={m.id}>
                <td><a href={`/panel/materials/${m.id}`}>{m.code}</a></td>
                <td className="nowrap">{dt(m.created_at)}</td>
                <td><Badge value={m.status} /></td>
                <td>{m.source}</td>
                <td>{m.author ?? '—'}</td>
                <td>{m.brands ?? '—'}</td>
                <td>{m.main_idea ?? '—'}</td>
                <td>{m.published}/{m.variants}</td>
                <td>{usd(m.cost_usd)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {rows.length === 0 && <p className="muted">Nothing found.</p>}
      <Pager page={page} more={rows.length > PER_PAGE} params={{ q: code, brand, status }} />
    </Shell>
  );
}
