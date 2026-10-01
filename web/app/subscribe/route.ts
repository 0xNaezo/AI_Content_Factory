import { subscribePOST } from '@/lib/subscription';

// Subscribe form on a brand's own blog domain: the brand comes from the Host header.
export const POST = (req: Request) => subscribePOST(req, { params: Promise.resolve({}) });
