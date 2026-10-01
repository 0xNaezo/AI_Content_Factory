// Formatting and query-string parsing shared by pages. Every value from the URL is validated before it reaches SQL.

export const PLATFORMS: Record<string, string> = {
  telegram: 'Telegram', blog: 'Blog', email: 'Email digest', linkedin: 'LinkedIn', instagram: 'Instagram', facebook: 'Facebook', x: 'X',
};

export type SP = Record<string, string | string[] | undefined>;

export function param(sp: SP, key: string): string | undefined {
  const v = sp[key];
  return (Array.isArray(v) ? v[0] : v)?.trim() || undefined;
}

export const idParam = (v?: string) => (v && /^\d{1,18}$/.test(v) ? v : null);
export const oneOf = (v: string | undefined, list: readonly string[]) => (v && list.includes(v) ? v : null);
export const uuidParam = (v?: string | null) =>
  v && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v) ? v : null;
export const slugParam = (v?: string) => (v && /^[a-z0-9][a-z0-9-]{1,39}$/.test(v) ? v : null);
/** "M-123", "m123" or "123" -> "123". */
export const materialParam = (v?: string) => /^(?:m-?)?(\d{1,18})$/i.exec(v ?? '')?.[1] ?? null;
/** Strict YYYY-MM-DD (rejects 2026-02-31). */
export const dayParam = (v?: string) => (v && /^\d{4}-\d{2}-\d{2}$/.test(v) && addDays(v, 0) === v ? v : null);
export const pageParam = (v?: string) => Math.min(Math.max(Number.parseInt(v ?? '1', 10) || 1, 1), 1000);

export function qs(p: Record<string, string | number | null | undefined>): string {
  const s = new URLSearchParams();
  for (const [k, v] of Object.entries(p)) if (v != null && v !== '') s.set(k, String(v));
  const r = s.toString();
  return r ? `?${r}` : '';
}

/** Calendar arithmetic on YYYY-MM-DD strings (timezone-free). */
export function addDays(day: string, n: number): string {
  const d = new Date(`${day}T00:00:00Z`);
  if (Number.isNaN(+d)) return '';
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

export const todayIn = (tz: string) => new Intl.DateTimeFormat('en-CA', { timeZone: tz }).format(new Date());

export function dt(v: unknown): string {
  if (!v) return '—';
  const d = new Date(v as string);
  return Number.isNaN(+d) ? '—' : `${d.toISOString().slice(0, 16).replace('T', ' ')} UTC`;
}

export function longDate(v: unknown, tz = 'UTC'): string {
  const d = new Date(v as string);
  return Number.isNaN(+d) ? '' : d.toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric', timeZone: tz });
}

export const usd = (v: unknown) => `$${Number(v ?? 0).toFixed(Number(v ?? 0) >= 1 ? 2 : 4)}`;

export function duration(seconds: unknown): string {
  const m = Math.floor(Number(seconds ?? 0) / 60);
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  return h < 48 ? `${h} h ${m % 60} min` : `${Math.floor(h / 24)} d ${h % 24} h`;
}

/** First palette color when it is a plain hex value (it ends up in a style attribute). */
export const brandColor = (palette: unknown) => {
  const c = Array.isArray(palette) ? palette[0] : null;
  return typeof c === 'string' && /^#[0-9a-f]{3,8}$/i.test(c) ? c : undefined;
};

export const json = (v: unknown) => (v == null ? '' : JSON.stringify(v, null, 2));
