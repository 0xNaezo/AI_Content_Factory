// Read-only panel chrome and small building blocks (architecture 7.11). Plain links and GET forms: no client JS needed.
import type { ReactNode } from 'react';
import type { Row } from '@/lib/db';
import { httpUrl } from '@/lib/html';
import { qs } from '@/lib/format';

const NAV = [
  ['/panel', 'Overview'],
  ['/panel/materials', 'Materials'],
  ['/panel/calendar', 'Calendar'],
  ['/panel/queue', 'Queue'],
  ['/panel/digests', 'Digests'],
  ['/panel/reports', 'Reports'],
  ['/panel/audit', 'Audit'],
];

export function Shell({ me, active, title, children }: { me: Row; active: string; title: ReactNode; children: ReactNode }) {
  return (
    <>
      <header className="topbar">
        <a className="logo" href="/panel">Content Factory</a>
        <nav>
          {NAV.map(([href, label]) => (
            <a key={href} href={href} className={href === active ? 'active' : undefined}>{label}</a>
          ))}
        </nav>
        <form method="post" action="/panel/logout" className="me">
          <span>{me?.name}{me?.is_admin ? ' · admin' : ''}</span>
          <button className="link">Log out</button>
        </form>
      </header>
      <main className="panel">
        <h1>{title}</h1>
        {children}
      </main>
    </>
  );
}

export function Select({ name, label, value, options }: { name: string; label: string; value?: string | null; options: [string, string][] }) {
  return (
    <label>
      {label}
      <select name={name} defaultValue={value ?? ''}>
        <option value="">All</option>
        {options.map(([v, text]) => (
          <option key={v} value={v}>{text}</option>
        ))}
      </select>
    </label>
  );
}

export const Filters = ({ children }: { children: ReactNode }) => (
  <form method="get" className="filters">
    {children}
    <button>Apply</button>
  </form>
);

export const Badge = ({ value }: { value: unknown }) => (value ? <span className={`badge s-${String(value)}`}>{String(value).replace(/_/g, ' ')}</span> : null);

/** External link only for http(s) URLs. */
export const Ext = ({ href, children }: { href: unknown; children: ReactNode }) => {
  const url = httpUrl(href);
  return url ? <a href={url} target="_blank" rel="noopener noreferrer">{children}</a> : null;
};

export const Json = ({ value }: { value: unknown }) =>
  value == null || (typeof value === 'object' && Object.keys(value).length === 0) ? null : <code className="json">{JSON.stringify(value)}</code>;

export function Pager({ page, more, params }: { page: number; more: boolean; params: Record<string, string | null | undefined> }) {
  if (page === 1 && !more) return null;
  return (
    <nav className="pager">
      {page > 1 && <a href={qs({ ...params, page: page - 1 })}>← Newer</a>}
      <span className="muted">Page {page}</span>
      {more && <a href={qs({ ...params, page: page + 1 })}>Older →</a>}
    </nav>
  );
}

/** Generic table for report rows: headers are the SQL column aliases. */
export function Table({ columns, rows }: { columns: string[]; rows: Row[] }) {
  if (!rows.length) return <p className="muted">No data for these filters.</p>;
  return (
    <div className="table-wrap">
      <table>
        <thead>
          <tr>{columns.map((c) => <th key={c}>{c}</th>)}</tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={i}>{columns.map((c) => <td key={c}>{r[c] == null ? '—' : String(r[c])}</td>)}</tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
