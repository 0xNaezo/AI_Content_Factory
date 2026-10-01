import type { Metadata } from 'next';
import { Article, articleMetadata } from '@/components/blog';

type Props = { params: Promise<{ brand: string; slug: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { brand, slug } = await params;
  return articleMetadata(brand, slug);
}

export default async function BlogArticle({ params }: Props) {
  const { brand, slug } = await params;
  return <Article brandSlug={brand} slug={slug} base={`/b/${brand}`} />;
}
