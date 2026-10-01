// Brand blogs (architecture 7.9): the same components serve /b/<brand>/... and a brand's own blog domain (base = '').
import type { CSSProperties } from 'react';
import { cache } from 'react';
import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { q, type Row } from '@/lib/db';
import { httpUrl, renderMarkdown } from '@/lib/html';
import { redirectLink } from '@/lib/sign';
import { brandColor, longDate } from '@/lib/format';

const getBrand = cache(async (slug: string) => (await q('select * from site.brands where slug = $1', [slug]))[0]);
const getPost = cache(
  async (brand: string, slug: string) =>
    (await q('select * from site.posts where brand_slug = $1 and slug = $2 order by published_at desc limit 1', [brand, slug]))[0],
);

const media = (id: unknown) => `/media/${id}`;

function BlogHeader({ brand, base }: { brand: Row; base: string }) {
  return (
    <header className="blog-head" style={{ '--brand': brandColor(brand.palette) } as CSSProperties}>
      <a href={base || '/'} className="blog-brand">
        {brand.logo_asset_id && <img src={media(brand.logo_asset_id)} alt="" />}
        <span>{brand.name}</span>
      </a>
      {brand.description && <p>{brand.description}</p>}
      {httpUrl(brand.telegram_url) && <a className="follow" href={httpUrl(brand.telegram_url)!}>Follow on Telegram →</a>}
    </header>
  );
}

function SubscribeForm({ brand, base }: { brand: Row; base: string }) {
  return (
    <form method="post" action={`${base}/subscribe`} className="subscribe" id="subscribe">
      <label htmlFor="email">Get the {brand.digest_title || `${brand.name} newsletter`} by email</label>
      <div className="row">
        <input id="email" type="email" name="email" required maxLength={254} placeholder="you@example.com" autoComplete="email" />
        <button>Subscribe</button>
      </div>
      <p className="muted">We store only your email address and subscription status. Unsubscribe in one click.</p>
    </form>
  );
}

export async function BlogIndex({ slug, base }: { slug: string; base: string }) {
  const brand = await getBrand(slug);
  if (!brand) notFound();
  const posts = await q(
    'select variant_id, slug, title, lead, cover_asset_id, published_at, language from site.posts where brand_id = $1 order by published_at desc limit 100',
    [brand.id],
  );
  return (
    <>
      <BlogHeader brand={brand} base={base} />
      <main className="blog">
        {posts.length === 0 && <p className="muted">No posts yet.</p>}
        {posts.map((p) => (
          <a key={p.variant_id} href={`${base}/${p.slug}`} className="post-card" lang={p.language}>
            {p.cover_asset_id && <img src={media(p.cover_asset_id)} alt="" loading="lazy" />}
            <div>
              <h2>{p.title}</h2>
              <p>{p.lead}</p>
              <time className="muted">{longDate(p.published_at, brand.timezone)}</time>
            </div>
          </a>
        ))}
        {brand.newsletter && <SubscribeForm brand={brand} base={base} />}
      </main>
    </>
  );
}

/** Title, cover, lead and sections of an article (blog page and the blog preview). `link` maps outbound URLs. */
export function ArticleBody({ content, cover, date, link }: { content: Row; cover?: string; date?: string; link: (u: string) => string }) {
  const sections: Row[] = Array.isArray(content.sections) ? content.sections : [];
  return (
    <>
      <h1>{content.title}</h1>
      {date && <time className="muted">{date}</time>}
      {cover && <img className="cover" src={cover} alt="" />}
      {content.lead && <p className="lead">{content.lead}</p>}
      {sections.map((s, i) => (
        <section key={i}>
          {s.heading && <h2>{s.heading}</h2>}
          {/* renderMarkdown escapes everything first and emits only its own tags (lib/html.ts) */}
          <div dangerouslySetInnerHTML={{ __html: renderMarkdown(s.body_md, link) }} />
        </section>
      ))}
    </>
  );
}

export async function Article({ brandSlug, slug, base }: { brandSlug: string; slug: string; base: string }) {
  const [brand, post] = await Promise.all([getBrand(brandSlug), getPost(brandSlug, slug)]);
  if (!brand || !post) notFound();
  await q('select site.count_view($1, $2, $3)', [post.brand_id, `/${post.slug}`, post.variant_id]);
  const variant = String(post.variant_id);
  return (
    <>
      <BlogHeader brand={brand} base={base} />
      <main className="blog">
        <article className="article" lang={post.language}>
          <ArticleBody
            content={post}
            cover={post.cover_asset_id ? media(post.cover_asset_id) : undefined}
            date={longDate(post.published_at, brand.timezone)}
            link={(url) => redirectLink(variant, url)}
          />
        </article>
        {brand.newsletter && <SubscribeForm brand={brand} base={base} />}
      </main>
    </>
  );
}

export async function articleMetadata(brandSlug: string, slug: string): Promise<Metadata> {
  const [brand, post] = await Promise.all([getBrand(brandSlug), getPost(brandSlug, slug)]);
  if (!brand || !post) return {};
  const image = post.cover_asset_id && URL.canParse(brand.blog_url) ? `${new URL(brand.blog_url).origin}${media(post.cover_asset_id)}` : undefined;
  return {
    title: `${post.title} · ${brand.name}`,
    description: post.seo_description || post.lead,
    alternates: post.url ? { canonical: post.url } : undefined,
    openGraph: { type: 'article', title: post.title, description: post.seo_description || post.lead, images: image ? [image] : undefined },
  };
}

export async function blogMetadata(slug: string): Promise<Metadata> {
  const brand = await getBrand(slug);
  return brand ? { title: brand.name, description: brand.description } : {};
}
