import test from 'node:test';
import assert from 'node:assert/strict';
import sharp from 'sharp';
import { isPublicIp, safeFetch, yamlParse, yamlDump, validate, fitImage, pdfPages, server } from './server.mjs';

test('SSRF guard: private, loopback, link-local and mapped addresses are blocked', async () => {
  for (const ip of ['127.0.0.1', '10.1.2.3', '172.20.0.5', '192.168.1.1', '169.254.169.254', '100.64.0.1', '0.0.0.0', '::1', 'fd00::1', 'fe80::1', '::ffff:127.0.0.1']) {
    assert.equal(isPublicIp(ip), false, ip);
  }
  for (const ip of ['1.1.1.1', '93.184.216.34', '2606:4700::1111']) assert.equal(isPublicIp(ip), true, ip);
  await assert.rejects(safeFetch('http://localhost:8080/health'), /blocked/);
  await assert.rejects(safeFetch('http://169.254.169.254/latest/meta-data/'), /blocked/);
  await assert.rejects(safeFetch('file:///etc/passwd'), /only http/);
});

test('YAML round trip keeps data and reports the line of a syntax error', () => {
  const data = { brand: { slug: 'cafe', name: 'Café «Ромашка»' }, feeds: ['https://example.com/rss'] };
  const text = yamlDump(data, 'Brand config\nEdit and send back');
  assert.match(text, /^# Brand config\n# Edit and send back/);
  assert.deepEqual(yamlParse(text).data, data);
  const bad = yamlParse('brand:\n  name: [unclosed\n');
  assert.equal(bad.ok, false);
  assert.ok(bad.line >= 2);
});

test('brand profile validation lists readable errors', () => {
  const r = validate('brand-profile', { basics: { name: '' }, extra: 1 });
  assert.equal(r.ok, false);
  assert.ok(r.errors.some((e) => e.startsWith('(root): must NOT have additional properties "extra"')), r.errors.join('\n'));
  assert.ok(r.errors.some((e) => e.startsWith('basics.name')), r.errors.join('\n'));
});

test('image fit: exact size, logo overlay, JPEG', async () => {
  const src = await sharp({ create: { width: 1000, height: 700, channels: 3, background: '#336699' } }).png().toBuffer();
  const logo = await sharp({ create: { width: 200, height: 100, channels: 4, background: { r: 255, g: 255, b: 255, alpha: 0.8 } } }).png().toBuffer();
  const out = await fitImage(src, { width: 1080, height: 1350, logo, logoPosition: 'top-left' });
  const m = await sharp(out).metadata();
  assert.deepEqual([m.width, m.height, m.format], [1080, 1350, 'jpeg']);
});

test('pdf page count', () => {
  const pdf = Buffer.from('%PDF-1.4\n1 0 obj <</Type /Pages /Count 2 /Kids [2 0 R 3 0 R]>> endobj\n2 0 obj <</Type /Page>> endobj\n3 0 obj <</Type/Page>> endobj\n');
  assert.equal(pdfPages(pdf), 2);
});

test('HTTP: health and validation endpoints', async () => {
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    assert.equal((await (await fetch(`${base}/health`)).json()).ok, true);
    const v = await (await fetch(`${base}/validate/brand-profile`, { method: 'POST', body: JSON.stringify({ data: {} }) })).json();
    assert.equal(v.ok, false);
    const u = await (await fetch(`${base}/url`, { method: 'POST', body: JSON.stringify({ url: 'http://127.0.0.1/' }) })).json();
    assert.equal(u.ok, false);
  } finally {
    server.close();
  }
});
