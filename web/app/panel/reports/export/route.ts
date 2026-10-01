import type { NextRequest } from 'next/server';
import { panel } from '@/lib/db';
import { REPORTS, reportFilters, runReport, type ReportKey } from '@/lib/reports';

// CSV export of one report table (AN-4), same filters and same row visibility as the page.
function cell(v: unknown): string {
  let s = v == null ? '' : v instanceof Date ? v.toISOString() : String(v);
  if (/^[=+\-@\t\r]/.test(s) && Number.isNaN(Number(s))) s = `'${s}`; // no spreadsheet formulas from brand names
  return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

export async function GET(req: NextRequest) {
  const sp = Object.fromEntries(req.nextUrl.searchParams);
  const key = sp.report as ReportKey;
  if (!Object.hasOwn(REPORTS, key)) return new Response('Unknown report', { status: 404 });
  const f = reportFilters(sp);
  const { columns, rows } = await panel((db) => runReport(db, key, f));
  const csv = [columns, ...rows.map((r) => columns.map((c) => r[c]))].map((line) => line.map(cell).join(',')).join('\r\n') + '\r\n';
  return new Response(csv, {
    headers: {
      'content-type': 'text/csv; charset=utf-8',
      'content-disposition': `attachment; filename="${key}_${f.from}_${f.to}.csv"`,
      'cache-control': 'private, no-store',
    },
  });
}
