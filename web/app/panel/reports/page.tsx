import { panel } from '@/lib/db';
import { PLATFORMS, qs, type SP } from '@/lib/format';
import { REPORTS, reportFilters, runReport, type ReportKey } from '@/lib/reports';
import { Filters, Select, Shell, Table } from '@/components/panel';

// Reports (AN-2) with brand / platform / period filters; each table has a CSV export (AN-4).
export default async function Reports({ searchParams }: { searchParams: Promise<SP> }) {
  const f = reportFilters(await searchParams);
  const keys = Object.keys(REPORTS) as ReportKey[];
  const { me, brands, results } = await panel(async (db, me) => {
    const brands = (await db.query('select id, name from panel.brands where full_access order by name')).rows;
    const results = [];
    for (const key of keys) results.push(await runReport(db, key, f)); // one connection: sequential
    return { me, brands, results };
  });
  const filters = { brand: f.brand, platform: f.platform, from: f.from, to: f.to };
  return (
    <Shell me={me} active="/panel/reports" title="Reports">
      <Filters>
        <Select name="brand" label="Brand" value={f.brand} options={brands.map((b) => [String(b.id), b.name])} />
        <Select name="platform" label="Platform" value={f.platform} options={Object.entries(PLATFORMS)} />
        <label>
          From
          <input type="date" name="from" defaultValue={f.from} />
        </label>
        <label>
          To
          <input type="date" name="to" defaultValue={f.to} />
        </label>
      </Filters>
      {keys.map((key, i) => (
        <section key={key} className="report">
          <h2>
            {REPORTS[key].title} <a className="small" href={`/panel/reports/export${qs({ report: key, ...filters })}`}>CSV</a>
          </h2>
          <p className="muted small">{REPORTS[key].note}</p>
          <Table columns={results[i].columns} rows={results[i].rows} />
        </section>
      ))}
    </Shell>
  );
}
