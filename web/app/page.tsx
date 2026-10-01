import type { Metadata } from 'next';
import { hostBrand, q } from '@/lib/db';
import { BlogIndex, blogMetadata } from '@/components/blog';

// On a brand's own blog domain "/" is that blog; on the main host it lists the brands.
export async function generateMetadata(): Promise<Metadata> {
  const brand = await hostBrand();
  return brand ? blogMetadata(brand) : { title: 'Brand blogs · AI Content Factory' };
}

export default async function Home() {
  const brand = await hostBrand();
  if (brand) return <BlogIndex slug={brand} base="" />;
  const brands = await q('select slug, name, description, niche, blog_domain, blog_url from site.brands order by name');
  return (
    <main className="narrow">
      <h1>Brand blogs</h1>
      {brands.length === 0 && <p className="muted">No active brands yet.</p>}
      <ul className="brand-list">
        {brands.map((b) => (
          <li key={b.slug}>
            <a href={b.blog_domain ? b.blog_url : `/b/${b.slug}`}>{b.name}</a>
            {b.niche && <span className="muted"> · {b.niche}</span>}
            {b.description && <p>{b.description}</p>}
          </li>
        ))}
      </ul>
    </main>
  );
}
