import type { Metadata } from 'next';
import { hostBrand, q } from '@/lib/db';
import { httpUrl } from '@/lib/html';
import { longDate } from '@/lib/format';
import { Article, articleMetadata } from '@/components/blog';

// Case page (tz section 10): task, capabilities, live numbers from the demo brands, architecture scheme.
// Main host only: on a brand's own blog domain "/case" is just an article slug.
export async function generateMetadata(): Promise<Metadata> {
  const custom = await hostBrand();
  if (custom) return articleMetadata(custom, 'case');
  return {
    title: 'AI Content Factory · case study',
    description: 'A multi-brand content pipeline on n8n: from raw material to approved, scheduled posts.',
  };
}

const n = (v: unknown, suffix = '') => (v == null ? '—' : `${v}${suffix}`);

export default async function Case() {
  const custom = await hostBrand();
  if (custom) return <Article brandSlug={custom} slug="case" base="" />;
  const [[s], brands] = await Promise.all([
    q('select * from site.case_stats'),
    q('select slug, name, niche, description, blog_domain, blog_url, telegram_url, newsletter from site.brands where is_demo order by name'),
  ]);
  const stats: [string, string][] = [
    ['Demo brands', n(s?.brands)],
    ['Materials processed', n(s?.materials)],
    ['Packages created', n(s?.packages)],
    ['Posts published', n(s?.published)],
    ['Approved without edits', n(s?.approved_without_edits_pct, '%')],
    ['Median time to approval card', n(s?.median_minutes_to_card, ' min')],
    ['Median time to publication', n(s?.median_hours_to_publish, ' h')],
    ['Average AI cost per package', s?.avg_package_cost_usd == null ? '—' : `$${s.avg_package_cost_usd}`],
  ];
  return (
    <main className="case">
      <header className="case-hero">
        <h1>AI Content Factory</h1>
        <p>One installation serves many brands: raw material in, brand-ready posts out — approved by a human, published on schedule.</p>
      </header>

      <section>
        <h2>The task</h2>
        <p>
          Marketing teams and agencies get content as voice notes, texts, files, links and emails. Turning each of them into posts for
          several brands and platforms — in the right voice, with visuals, on schedule — is slow manual work. The factory automates the
          pipeline and leaves people only the decisions.
        </p>
      </section>

      <section>
        <h2>What it does</h2>
        <ul className="features">
          <li><b>Any input.</b> Voice, text, images, PDF, DOCX, spreadsheets, links and email go to one Telegram bot or mailbox.</li>
          <li><b>Brand detection.</b> The material is transcribed, summarized and routed to the right brand, or the author is asked.</li>
          <li><b>Per-platform variants.</b> Each brand gets posts for its platforms in its own voice, with generated visuals and automatic checks.</li>
          <li><b>Approval in Telegram.</b> Editors approve, edit, redo with a comment or reschedule; every change is a new version.</li>
          <li><b>Scheduled publishing.</b> Telegram channel, the brand blog and an email digest — at most once, with retries and a stop switch.</li>
          <li><b>Previews.</b> LinkedIn, Instagram, Facebook and X variants are rendered as “how it will look” pages.</li>
          <li><b>Control.</b> AI budgets per brand, an append-only audit log, end-to-end trace by material ID, brand isolation down to the database.</li>
        </ul>
      </section>

      <section>
        <h2>Live numbers</h2>
        <div className="stats">
          {stats.map(([label, value]) => (
            <div key={label} className="stat">
              <b>{value}</b>
              <span>{label}</span>
            </div>
          ))}
        </div>
        <p className="muted small">Demo brands only{s?.since ? `, since ${longDate(s.since)}` : ''}. Updated on every page load.</p>
      </section>

      <section>
        <h2>Demo brands</h2>
        {brands.length === 0 && <p className="muted">Demo brands are being set up.</p>}
        <ul className="brand-list">
          {brands.map((b) => {
            const blog = b.blog_domain ? b.blog_url : `/b/${b.slug}`;
            return (
              <li key={b.slug}>
                <b>{b.name}</b>
                {b.niche && <span className="muted"> · {b.niche}</span>}
                {b.description && <p>{b.description}</p>}
                <p className="links">
                  <a href={blog}>Blog</a>
                  {httpUrl(b.telegram_url) && <a href={httpUrl(b.telegram_url)!}>Telegram channel</a>}
                  {b.newsletter && <a href={`${blog}#subscribe`}>Newsletter</a>}
                </p>
              </li>
            );
          })}
        </ul>
      </section>

      <section>
        <h2>How it works</h2>
        <div className="scheme">
          <div className="box">
            <h3>Intake</h3>
            <p>Telegram bot</p>
            <p>Email</p>
          </div>
          <div className="arrow" aria-hidden>→</div>
          <div className="box core">
            <h3>n8n workflows</h3>
            <p className="chips">
              <span>Intake</span>
              <span>Pipeline</span>
              <span>Approval</span>
              <span>Publisher</span>
              <span>Digest</span>
            </p>
            <div className="core-deps">
              <div className="box db">↕ Postgres<small>state · job queue · audit</small></div>
              <div className="box ai">↕ AI gateway<small>Claude · OpenRouter</small></div>
            </div>
          </div>
          <div className="arrow" aria-hidden>→</div>
          <div className="box">
            <h3>Publishing</h3>
            <p>Telegram channel</p>
            <p>Brand blog</p>
            <p>Email digest</p>
            <p className="muted small">Previews: LinkedIn, Instagram, Facebook, X</p>
          </div>
        </div>
        <p className="muted small">
          Every event is stored before it is processed; state, the job queue and the audit log live in Postgres, so any step can be
          retried without duplicates. All AI calls go through one gateway that enforces budgets and records cost per material.
        </p>
      </section>
    </main>
  );
}
