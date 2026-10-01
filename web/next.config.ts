import type { NextConfig } from 'next';

// Security headers live here only: config headers replace same-named headers set by route handlers,
// and for the same key the last matching rule wins.
const csp = (value: string) => [{ key: 'Content-Security-Policy', value }];

const nextConfig: NextConfig = {
  output: 'standalone',
  poweredByHeader: false,
  async headers() {
    return [
      {
        source: '/:path*',
        headers: [
          { key: 'X-Content-Type-Options', value: 'nosniff' },
          { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
          { key: 'X-Frame-Options', value: 'DENY' },
          ...csp("frame-ancestors 'none'; base-uri 'self'; object-src 'none'; form-action 'self'"),
        ],
      },
      // token pages and the panel stay out of search engines
      { source: '/:dir(panel|p|d)/:path*', headers: [{ key: 'X-Robots-Tag', value: 'noindex, nofollow' }] },
      // digest preview: our template's HTML, no scripts at all; images from us (and https for external ones)
      {
        source: '/d/:token',
        headers: csp("default-src 'none'; img-src 'self' https: data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"),
      },
      // media: even an uploaded SVG/HTML file can never run anything
      { source: '/media/:asset', headers: csp("default-src 'none'; style-src 'unsafe-inline'; sandbox") },
    ];
  },
};

export default nextConfig;
