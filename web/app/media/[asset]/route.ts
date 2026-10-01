import type { NextRequest } from 'next/server';
import { GetObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { q } from '@/lib/db';
import { uuidParam } from '@/lib/format';

// Media from the private bucket, after site.asset() says it is public (published) or reachable with this preview token.
let s3: S3Client | undefined;
const client = () =>
  (s3 ??= new S3Client({
    endpoint: process.env.S3_ENDPOINT,
    region: 'us-east-1',
    forcePathStyle: true,
    credentials: { accessKeyId: process.env.S3_ACCESS_KEY ?? '', secretAccessKey: process.env.S3_SECRET_KEY ?? '' },
    requestChecksumCalculation: 'WHEN_REQUIRED',
    responseChecksumValidation: 'WHEN_REQUIRED',
  }));

const notFound = () => new Response('Not found', { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8' } });

export async function GET(req: NextRequest, { params }: { params: Promise<{ asset: string }> }) {
  const { asset } = await params;
  const token = uuidParam(req.nextUrl.searchParams.get('t')); // invalid tokens are ignored
  if (!/^\d{1,18}$/.test(asset)) return notFound();
  const row = (await q('select * from site.asset($1, $2)', [asset, token]))[0];
  if (!row) return notFound();
  let obj;
  try {
    obj = await client().send(new GetObjectCommand({ Bucket: process.env.S3_BUCKET, Key: row.s3_key }));
  } catch (e) {
    const err = e as { name?: string; $metadata?: { httpStatusCode?: number } };
    if (err.name === 'NoSuchKey' || err.$metadata?.httpStatusCode === 404) return notFound();
    throw e;
  }
  if (!obj.Body) return notFound();
  const headers: Record<string, string> = {
    'content-type': row.mime,
    'cache-control': token ? 'private, max-age=600' : 'public, max-age=86400', // sandbox CSP: next.config.ts
  };
  if (obj.ContentLength != null) headers['content-length'] = String(obj.ContentLength);
  if (obj.ETag) headers.etag = obj.ETag;
  return new Response(obj.Body.transformToWebStream(), { headers });
}
