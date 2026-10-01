import type { Metadata } from 'next';
import { BlogIndex, blogMetadata } from '@/components/blog';

type Props = { params: Promise<{ brand: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  return blogMetadata((await params).brand);
}

export default async function Blog({ params }: Props) {
  const { brand } = await params;
  return <BlogIndex slug={brand} base={`/b/${brand}`} />;
}
