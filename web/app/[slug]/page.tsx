import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { hostBrand } from '@/lib/db';
import { Article, articleMetadata } from '@/components/blog';

// "/<slug>" exists only on a brand's own blog domain.
type Props = { params: Promise<{ slug: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const brand = await hostBrand();
  return brand ? articleMetadata(brand, (await params).slug) : {};
}

export default async function CustomDomainArticle({ params }: Props) {
  const brand = await hostBrand();
  if (!brand) notFound();
  return <Article brandSlug={brand} slug={(await params).slug} base="" />;
}
