// npm test: the markdown sanitizer and the /r link signature (run by Node's built-in test runner with type stripping).
import test from 'node:test';
import assert from 'node:assert/strict';
import { renderMarkdown } from '../lib/html.ts';
import { redirectLink, sign, verify } from '../lib/sign.ts';

test('markdown escapes raw HTML', () => {
  const html = renderMarkdown('<script>alert(1)</script>\n\n<img src=x onerror="alert(1)"> & "q"');
  assert.equal(html, '<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>\n<p>&lt;img src=x onerror=&quot;alert(1)&quot;&gt; &amp; &quot;q&quot;</p>');
});

test('markdown renders the allowed subset', () => {
  const html = renderMarkdown('# Title\n\nOne **bold** and *it* and __b__ _i_ snake_case_name.\nsame paragraph\n\n- a\n- b\n\n1. x\n2) y');
  assert.equal(
    html,
    '<h3>Title</h3>\n<p>One <strong>bold</strong> and <em>it</em> and <strong>b</strong> <em>i</em> snake_case_name.\nsame paragraph</p>\n' +
      '<ul><li>a</li><li>b</li></ul>\n<ol><li>x</li><li>y</li></ol>',
  );
});

test('markdown links: http(s) only, routed through the callback, attributes escaped', () => {
  const link = (u: string) => `/r?u=${encodeURIComponent(u)}&x="1"`;
  assert.equal(
    renderMarkdown('See [the *docs*](https://example.com/a_b*c*?q=1&r=2).', link),
    '<p>See <a href="/r?u=https%3A%2F%2Fexample.com%2Fa_b*c*%3Fq%3D1%26r%3D2&amp;x=&quot;1&quot;" rel="nofollow noopener">the <em>docs</em></a>.</p>',
  );
  assert.equal(renderMarkdown('[x](javascript:alert(1)) [y](data:text/html,hi) [z](/relative)'), '<p>[x](javascript:alert(1)) y z</p>');
  assert.equal(renderMarkdown('[q](https://e.com/"onmouseover="x)'), '<p><a href="https://e.com/%22onmouseover=%22x" rel="nofollow noopener">q</a></p>');
  assert.ok(!renderMarkdown('fake \0' + '0\0 placeholder').includes('undefined'));
});

test('redirect signature binds variant and url', () => {
  const s = sign('42', 'https://example.com/x', 'secret');
  assert.match(s, /^[0-9a-f]{64}$/);
  assert.ok(verify('42', 'https://example.com/x', s, 'secret'));
  assert.ok(!verify('43', 'https://example.com/x', s, 'secret'));
  assert.ok(!verify('42', 'https://evil.example/x', s, 'secret'));
  assert.ok(!verify('42', 'https://example.com/x', s, 'other-secret'));
  assert.ok(!verify('42', 'https://example.com/x', s.slice(1), 'secret'));
  assert.ok(!verify('42', 'https://example.com/x', '', 'secret'));

  process.env.SESSION_SECRET = 'env-secret';
  const q = new URLSearchParams(redirectLink('7', 'https://example.com/?a=1&b=2').split('?')[1]);
  assert.equal(q.get('u'), 'https://example.com/?a=1&b=2');
  assert.ok(verify(q.get('v')!, q.get('u')!, q.get('s')!));
  delete process.env.SESSION_SECRET;
  assert.throws(() => sign('1', 'https://example.com/'));
});
