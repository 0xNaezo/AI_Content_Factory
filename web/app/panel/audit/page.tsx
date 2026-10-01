import { panel } from '@/lib/db';
import { dt, idParam, materialParam, pageParam, param, type SP } from '@/lib/format';
import { Filters, Json, Pager, Select, Shell } from '@/components/panel';

// Append-only audit log (AD-3), newest first, 50 per page.
const PER_PAGE = 50;

export default async function Audit({ searchParams }: { searchParams: Promise<SP> }) {
  const sp = await searchParams;
  const brand = idParam(param(sp, 'brand'));
  const action = param(sp, 'action')?.slice(0, 100) ?? null;
  const entity = param(sp, 'entity')?.slice(0, 50) ?? null;
  const material = param(sp, 'material') ?? null;
  const page = pageParam(param(sp, 'page'));
  const { me, brands, rows } = await panel(async (db, me) => ({
    me,
    brands: (await db.query('select id, name from panel.brands where full_access order by name')).rows,
    rows: material && !materialParam(material) ? [] : (await db.query(
      `select a.id, a.at, a.actor, a.action, a.entity, a.entity_id, a.material_id, a.data, b.name as brand
       from panel.audit a left join panel.brands b on b.id = a.brand_id
       where ($1::bigint is null or a.brand_id = $1) and ($2::text is null or starts_with(a.action, $2))
         and ($3::text is null or a.entity = $3) and ($4::bigint is null or a.material_id = $4)
       order by a.id desc limit $5 offset $6`,
      [brand, action, entity, materialParam(material ?? undefined), PER_PAGE + 1, (page - 1) * PER_PAGE],
    )).rows,
  }));
  return (
    <Shell me={me} active="/panel/audit" title="Audit log">
      <Filters>
        <Select name="brand" label="Brand" value={brand} options={brands.map((b) => [String(b.id), b.name])} />
        <label>
          Action starts with
          <input name="action" defaultValue={action ?? ''} placeholder="status" size={12} />
        </label>
        <label>
          Entity
          <input name="entity" defaultValue={entity ?? ''} placeholder="variant" size={10} />
        </label>
        <label>
          Material
          <input name="material" defaultValue={material ?? ''} placeholder="M-123" size={8} />
        </label>
      </Filters>
      <div className="table-wrap">
        <table>
          <thead>
            <tr><th>Time</th><th>Actor</th><th>Action</th><th>Object</th><th>Brand</th><th>Material</th><th>Data</th></tr>
          </thead>
          <tbody>
            {rows.slice(0, PER_PAGE).map((r) => (
              <tr key={r.id}>
                <td className="nowrap">{dt(r.at)}</td>
                <td>{r.actor}</td>
                <td>{r.action}</td>
                <td>{r.entity ? `${r.entity} ${r.entity_id ?? ''}` : '—'}</td>
                <td>{r.brand ?? '—'}</td>
                <td>{r.material_id ? <a href={`/panel/materials/${r.material_id}`}>M-{r.material_id}</a> : '—'}</td>
                <td><Json value={r.data} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {rows.length === 0 && <p className="muted">No entries.</p>}
      <Pager page={page} more={rows.length > PER_PAGE} params={{ brand, action, entity, material }} />
    </Shell>
  );
}
