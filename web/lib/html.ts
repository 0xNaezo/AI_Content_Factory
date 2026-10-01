// HTML escaping and the tiny Markdown subset used in article bodies (paragraphs, headings, lists, bold/italic, http(s) links).
// Safety model: the whole input is escaped first; the only tags in the output are the literal ones built below,
// and the only attribute (href) comes from a URL that parsed as http(s) and is escaped again.
// No relative imports here: the unit test runs this file directly with Node's type stripping.

const ENTITIES: Record<string, string> = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
const UNESCAPE: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'" };

export function esc(s: unknown): string {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ENTITIES[c]);
}

function unesc(s: string): string {
  return s.replace(/&(amp|lt|gt|quot|#39);/g, (_, e: string) => UNESCAPE[e]);
}

/** Normalized absolute http(s) URL, or null for anything else (javascript:, data:, relative, garbage). */
export function httpUrl(u: unknown): string | null {
  try {
    const url = new URL(String(u));
    return url.protocol === 'http:' || url.protocol === 'https:' ? url.href : null;
  } catch {
    return null;
  }
}

// Works on already-escaped text: markers are ASCII, so no tag or entity can be produced or split.
function emphasis(s: string): string {
  return s
    .replace(/\*\*(?=\S)(.+?)(?<=\S)\*\*|__(?=\S)(.+?)(?<=\S)__/g, (_, a, b) => `<strong>${a ?? b}</strong>`)
    .replace(/\*(?=\S)(.+?)(?<=\S)\*|(?<!\w)_(?=\S)(.+?)(?<=\S)_(?!\w)/g, (_, a, b) => `<em>${a ?? b}</em>`);
}

function inline(text: string, link: (url: string) => string): string {
  const anchors: string[] = [];
  // Links become placeholders so emphasis never touches an href; NUL is stripped from the input so it cannot fake one.
  const s = esc(text.replace(/\0/g, '')).replace(/\[([^\]\n]+)\]\(([^()\s]+)\)/g, (_, label: string, href: string) => {
    const url = httpUrl(unesc(href));
    if (!url) return label;
    anchors.push(`<a href="${esc(link(url))}" rel="nofollow noopener">${emphasis(label)}</a>`);
    return `\0${anchors.length - 1}\0`;
  });
  return emphasis(s).replace(/\0(\d+)\0/g, (_, i: string) => anchors[Number(i)]);
}

/**
 * Render the Markdown subset to HTML. `link` maps each allowed URL to the href actually emitted
 * (the blog routes it through the signed /r redirect). Markdown headings start at h3: the page owns h1/h2.
 */
export function renderMarkdown(md: unknown, link: (url: string) => string = (u) => u): string {
  const out: string[] = [];
  let para: string[] = [];
  let listTag = '';
  let items: string[] = [];
  const flush = () => {
    if (para.length) out.push(`<p>${inline(para.join('\n'), link)}</p>`);
    if (items.length) out.push(`<${listTag}>${items.map((i) => `<li>${inline(i, link)}</li>`).join('')}</${listTag}>`);
    para = [];
    items = [];
  };
  for (const line of String(md ?? '').replace(/\r\n?/g, '\n').split('\n')) {
    const heading = /^(#{1,6})\s+(.*?)(\s+#+)?\s*$/.exec(line);
    const item = /^\s*([-*+]|\d{1,9}[.)])\s+(.*)$/.exec(line);
    if (!line.trim()) {
      flush();
    } else if (heading) {
      flush();
      const h = `h${Math.min(heading[1].length + 2, 6)}`;
      out.push(`<${h}>${inline(heading[2], link)}</${h}>`);
    } else if (item) {
      const tag = /\d/.test(item[1]) ? 'ol' : 'ul';
      if (para.length || (items.length && tag !== listTag)) flush();
      listTag = tag;
      items.push(item[2]);
    } else if (items.length && /^\s/.test(line)) {
      items[items.length - 1] += ' ' + line.trim(); // indented continuation of a list item
    } else {
      if (items.length) flush();
      para.push(line.trim());
    }
  }
  flush();
  return out.join('\n');
}
