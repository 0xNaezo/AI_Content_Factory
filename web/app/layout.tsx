import type { Metadata } from 'next';
import type { ReactNode } from 'react';

// Every page reads live data (and counts views), so nothing is prerendered or cached.
export const dynamic = 'force-dynamic';

export const metadata: Metadata = { title: 'AI Content Factory' };

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <head>
        <link rel="stylesheet" href="/site.css" />
      </head>
      <body>{children}</body>
    </html>
  );
}
