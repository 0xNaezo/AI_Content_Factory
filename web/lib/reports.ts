// Reports (AN-2) over panel.variant_facts / package_facts / cost_daily; the same SQL feeds the page and the CSV (AN-4).
// Every query starts with the same parameter CTE: $1 brand id | null, $2 platform | null, $3 from date, $4 to date (inclusive).
import type { Db } from './db';
import { PLATFORMS, addDays, dayParam, idParam, oneOf, param, todayIn, type SP } from './format';

const P = `with p as (select $1::bigint as brand, $2::text as platform, $3::date as d0, $4::date + 1 as d1)\n`;
const BRAND = '(p.brand is null or f.brand_id = p.brand)';
const PLATFORM = '(p.platform is null or f.platform = p.platform)';

export const REPORTS = {
  volume: {
    title: 'Materials and packages',
    note: 'Packages created in the period (platform filter does not apply).',
    sql: `${P}select b.name as "Brand", count(distinct f.material_id) as "Materials", count(*) as "Packages",
       count(*) filter (where f.cancelled_at is not null) as "Cancelled"
from panel.package_facts f join panel.brands b on b.id = f.brand_id cross join p
where f.created_at >= p.d0 and f.created_at < p.d1 and ${BRAND}
group by 1 order by 1`,
  },
  published: {
    title: 'Published per platform',
    note: 'Variants published in the period.',
    sql: `${P}select b.name as "Brand", f.platform as "Platform", count(*) as "Published"
from panel.variant_facts f join panel.brands b on b.id = f.brand_id cross join p
where f.status = 'published' and f.published_at >= p.d0 and f.published_at < p.d1 and ${BRAND} and ${PLATFORM}
group by 1, 2 order by 1, 2`,
  },
  approval: {
    title: 'Approved without edits',
    note: 'Variants approved by an editor in the period; edits = manual edits, redo with a comment, headline changes.',
    sql: `${P}select b.name as "Brand", f.platform as "Platform", count(*) as "Approved",
       count(*) filter (where f.edits = 0) as "Without edits",
       round(100.0 * count(*) filter (where f.edits = 0) / count(*), 1) as "Without edits, %",
       round(avg(f.versions), 2) as "Avg versions"
from panel.variant_facts f join panel.brands b on b.id = f.brand_id cross join p
where f.approved_at >= p.d0 and f.approved_at < p.d1 and not f.auto_approved and ${BRAND} and ${PLATFORM}
group by 1, 2 order by 1, 2`,
  },
  timing: {
    title: 'Time to card and to publication (medians)',
    note: 'Material received → card sent (packages carded in the period); material received → published (variants published in the period).',
    sql: `${P}select b.name as "Brand",
  (select count(*) from panel.package_facts f where f.brand_id = b.id and f.card_sent_at >= p.d0 and f.card_sent_at < p.d1) as "Cards",
  (select round(extract(epoch from percentile_cont(0.5) within group (order by f.card_sent_at - f.received_at)) / 60, 1)
     from panel.package_facts f where f.brand_id = b.id and f.card_sent_at >= p.d0 and f.card_sent_at < p.d1) as "Median to card, min",
  (select count(*) from panel.variant_facts f where f.brand_id = b.id and f.status = 'published'
     and f.published_at >= p.d0 and f.published_at < p.d1 and ${PLATFORM}) as "Published",
  (select round(extract(epoch from percentile_cont(0.5) within group (order by f.published_at - f.received_at)) / 3600, 1)
     from panel.variant_facts f where f.brand_id = b.id and f.status = 'published'
     and f.published_at >= p.d0 and f.published_at < p.d1 and ${PLATFORM}) as "Median to publication, h"
from panel.brands b cross join p
where b.full_access and (p.brand is null or b.id = p.brand)
order by 1`,
  },
  errors: {
    title: 'Publish errors',
    note: 'Variants active in the period (published, else approved, else created) with failed or unknown publish attempts.',
    sql: `${P}select b.name as "Brand", f.platform as "Platform",
       count(*) filter (where f.publish_errors > 0) as "Variants with errors",
       sum(f.publish_errors) as "Failed attempts",
       count(*) filter (where f.status = 'failed') as "Failed variants"
from panel.variant_facts f join panel.brands b on b.id = f.brand_id cross join p
where coalesce(f.published_at, f.approved_at, f.package_at) >= p.d0 and coalesce(f.published_at, f.approved_at, f.package_at) < p.d1
  and ${BRAND} and ${PLATFORM}
group by 1, 2 having sum(f.publish_errors) > 0 or count(*) filter (where f.status = 'failed') > 0
order by 1, 2`,
  },
  engagement: {
    title: 'Reactions, views and clicks',
    note: 'Totals to date for posts published in the period, where the platform reports them (Telegram reactions, blog views and clicks).',
    sql: `${P}select b.name as "Brand", f.platform as "Platform", count(*) as "Posts",
       sum(f.reactions) as "Reactions", sum(f.views) as "Views", sum(f.clicks) as "Clicks"
from panel.variant_facts f join panel.brands b on b.id = f.brand_id cross join p
where f.status = 'published' and f.published_at >= p.d0 and f.published_at < p.d1 and ${BRAND} and ${PLATFORM}
group by 1, 2 order by 1, 2`,
  },
  cost_package: {
    title: 'AI cost per package',
    note: 'Packages created in the period; calls made before routing are split across the material’s packages (platform filter does not apply).',
    sql: `${P}select b.name as "Brand", count(*) as "Packages", round(sum(f.cost_usd), 4) as "AI cost, USD",
       round(avg(f.cost_usd), 4) as "Per package, USD"
from panel.package_facts f join panel.brands b on b.id = f.brand_id cross join p
where f.created_at >= p.d0 and f.created_at < p.d1 and ${BRAND}
group by 1 order by 1`,
  },
  cost_daily: {
    title: 'AI cost per brand per day',
    note: 'All AI calls billed to the brand, by UTC day (platform filter does not apply).',
    sql: `${P}select f.day::text as "Day", b.name as "Brand", sum(f.calls) as "AI calls", round(sum(f.cost_usd), 4) as "AI cost, USD"
from panel.cost_daily f join panel.brands b on b.id = f.brand_id cross join p
where f.day >= p.d0 and f.day < p.d1 and ${BRAND}
group by 1, 2 order by 1 desc, 2`,
  },
} as const;

export type ReportKey = keyof typeof REPORTS;

/** Filters from the query string; the period defaults to the last 30 days (UTC). */
export function reportFilters(sp: SP) {
  const to = dayParam(param(sp, 'to')) ?? todayIn('UTC');
  let from = dayParam(param(sp, 'from')) ?? addDays(to, -29);
  if (from > to) from = to;
  return { brand: idParam(param(sp, 'brand')), platform: oneOf(param(sp, 'platform'), Object.keys(PLATFORMS)), from, to };
}

export async function runReport(db: Db, key: ReportKey, f: ReturnType<typeof reportFilters>) {
  const r = await db.query(REPORTS[key].sql, [f.brand, f.platform, f.from, f.to]);
  return { columns: r.fields.map((c) => c.name), rows: r.rows };
}
