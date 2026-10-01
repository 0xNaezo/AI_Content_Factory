import { panel, type Row } from '@/lib/db';
import { PLATFORMS, addDays, dayParam, idParam, oneOf, param, qs, todayIn, type SP } from '@/lib/format';
import { Filters, Select, Shell } from '@/components/panel';

// Calendar (AN-1): proposed, scheduled, published and failed slots. Days are in the brand's time zone when one brand
// is selected, otherwise UTC.
const KINDS = ['proposed', 'approved', 'scheduled', 'rescheduled', 'publishing', 'published', 'failed'];
const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const monday = (day: string) => addDays(day, -((new Date(`${day}T00:00:00Z`).getUTCDay() + 6) % 7));
const monthStart = (day: string) => `${day.slice(0, 8)}01`;
const shiftMonth = (day: string, n: number) => {
  const d = new Date(`${monthStart(day)}T00:00:00Z`);
  d.setUTCMonth(d.getUTCMonth() + n);
  return d.toISOString().slice(0, 10);
};

export default async function Calendar({ searchParams }: { searchParams: Promise<SP> }) {
  const sp = await searchParams;
  const view = param(sp, 'view') === 'week' ? 'week' : 'month';
  const brand = idParam(param(sp, 'brand'));
  const platform = oneOf(param(sp, 'platform'), Object.keys(PLATFORMS));

  const { me, brands, tz, anchor, start, end, items } = await panel(async (db, me) => {
    const brands = (await db.query('select id, name, timezone from panel.brands order by name')).rows;
    const tz: string = brands.find((b) => b.id === brand)?.timezone ?? 'UTC';
    const anchor = dayParam(param(sp, 'date')) ?? todayIn(tz);
    const start = view === 'week' ? monday(anchor) : monday(monthStart(anchor));
    const end = view === 'week' ? addDays(start, 7) : addDays(monday(addDays(shiftMonth(anchor, 1), -1)), 7);
    const items = (await db.query(
      `select variant_id, material_id, brand_name, platform_label, kind, title, preview_token,
              to_char(at at time zone $3, 'YYYY-MM-DD') as day, to_char(at at time zone $3, 'HH24:MI') as time
       from panel.calendar
       where at >= ($1::timestamp at time zone $3) and at < ($2::timestamp at time zone $3)
         and ($4::bigint is null or brand_id = $4) and ($5::text is null or platform = $5)
       order by at`,
      [start, end, tz, brand, platform],
    )).rows;
    return { me, brands, tz, anchor, start, end, items };
  });

  const byDay = new Map<string, Row[]>();
  for (const it of items) byDay.set(it.day, [...(byDay.get(it.day) ?? []), it]);
  const days: string[] = [];
  for (let d = start; d < end; d = addDays(d, 1)) days.push(d);
  const keep = { view, brand, platform };
  const prev = view === 'week' ? addDays(anchor, -7) : shiftMonth(anchor, -1);
  const next = view === 'week' ? addDays(anchor, 7) : shiftMonth(anchor, 1);
  const title =
    view === 'week'
      ? `Week of ${start}`
      : new Date(`${monthStart(anchor)}T00:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });

  return (
    <Shell me={me} active="/panel/calendar" title="Calendar">
      <Filters>
        <input type="hidden" name="date" value={anchor} />
        <Select name="brand" label="Brand" value={brand} options={brands.map((b) => [String(b.id), b.name])} />
        <Select name="platform" label="Platform" value={platform} options={Object.entries(PLATFORMS)} />
        <label>
          View
          <select name="view" defaultValue={view}>
            <option value="month">Month</option>
            <option value="week">Week</option>
          </select>
        </label>
      </Filters>
      <nav className="cal-nav">
        <a href={qs({ ...keep, date: prev })}>← Previous</a>
        <b>{title}</b>
        <a href={qs({ ...keep, date: next })}>Next →</a>
        <a href={qs(keep)}>Today</a>
        <span className="muted small">Times in {tz}</span>
      </nav>
      <p className="legend">
        {KINDS.map((k) => (
          <span key={k} className={`ev k-${k}`}>{k}</span>
        ))}
      </p>
      <div className={`calendar ${view}`}>
        {WEEKDAYS.map((w) => (
          <div key={w} className="cal-weekday">{w}</div>
        ))}
        {days.map((d) => (
          <div key={d} className={`cal-day${view === 'month' && d.slice(0, 7) !== anchor.slice(0, 7) ? ' other' : ''}${byDay.has(d) ? '' : ' empty'}`}>
            <div className="cal-date">{Number(d.slice(8))}<span className="cal-wd"> {WEEKDAYS[(new Date(`${d}T00:00:00Z`).getUTCDay() + 6) % 7]}</span></div>
            {(byDay.get(d) ?? []).map((it) => (
              <div key={it.variant_id} className={`ev k-${it.kind}`}>
                <a href={`/p/${it.preview_token}`} title={it.title ?? ''}>
                  {it.time} {it.platform_label} · {it.brand_name}
                  <span className="ev-title">{it.title}</span>
                </a>
                <a className="small" href={`/panel/materials/${it.material_id}`}>M-{it.material_id}</a>
              </div>
            ))}
          </div>
        ))}
      </div>
    </Shell>
  );
}
