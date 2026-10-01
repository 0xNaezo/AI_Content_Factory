// Postgres access as app_web: it can read only site.* / panel.* views and call site.* / panel.* functions.
// All SQL is parameterized.
import { Pool, type PoolClient } from 'pg';
import { cookies, headers } from 'next/headers';
import { redirect } from 'next/navigation';

// One pool per process (Next can load this module from several bundles).
const g = globalThis as unknown as { acfPool?: Pool };
export const pool = (g.acfPool ??= new Pool({ connectionString: process.env.DATABASE_URL, max: 10 }).on('error', (e) =>
  console.error('postgres idle client error:', e.message), // without a listener this would crash the process
));

// Rows are plain view rows; pages read the columns they render.
export type Row = Record<string, any>;

export async function q(sql: string, params: unknown[] = []): Promise<Row[]> {
  return (await pool.query(sql, params)).rows;
}

export const SESSION_COOKIE = 'acf_session';
export type Db = Pick<PoolClient, 'query'>;

/**
 * Every panel request: resolve the session cookie (revocation is checked by the DB on each call), then run `fn`
 * in one read-only transaction that starts with app.user_id — the panel views filter rows by it (brand isolation).
 * No valid session -> /panel/expired.
 */
export async function panel<T>(fn: (db: Db, me: Row) => Promise<T>): Promise<T> {
  const token = (await cookies()).get(SESSION_COOKIE)?.value;
  if (token && /^[0-9a-f]{64}$/.test(token)) {
    const c = await pool.connect();
    let broken = false;
    try {
      const uid = (await c.query('select panel.session_user($1) as uid', [token])).rows[0]?.uid;
      if (uid) {
        await c.query('begin read only');
        try {
          await c.query("select set_config('app.user_id', $1, true)", [String(uid)]);
          const me = (await c.query('select * from panel.me')).rows[0];
          const out = await fn(c, me);
          await c.query('commit');
          return out;
        } catch (e) {
          await c.query('rollback').catch(() => (broken = true));
          throw e;
        }
      }
    } finally {
      c.release(broken);
    }
  }
  redirect('/panel/expired');
}

// Custom blog domains: host -> brand slug, reloaded at most every 60 s.
let hosts: { at: number; map: Map<string, string> } | null = null;

export async function brandForHost(host: string): Promise<string | null> {
  if (!hosts || Date.now() - hosts.at > 60_000) {
    const rows = await q('select lower(blog_domain) as host, slug from site.brands where blog_domain is not null');
    hosts = { at: Date.now(), map: new Map(rows.map((r) => [r.host, r.slug])) };
  }
  return hosts.map.get(host.toLowerCase().replace(/\.$/, '')) ?? null;
}

/** Brand whose blog_domain is this request's Host (port stripped), or null on the main host. */
export async function hostBrand(): Promise<string | null> {
  const host = (await headers()).get('host')?.replace(/:\d+$/, '');
  return host ? brandForHost(host) : null;
}
