// "How it will look" mocks per platform (PB-8). Text is rendered as plain text (React escapes it); only the blog
// article goes through the safe markdown renderer. Content shapes: post {text}, thread {posts[]},
// article {title, slug, lead, sections[{heading, body_md}], seo_description}, email_block {title, body, link_label}.
import type { ReactNode } from 'react';
import type { Row } from '@/lib/db';
import { ArticleBody } from './blog';

type Props = { p: Row; img?: string };

function Head({ p, sub }: { p: Row; sub: string }) {
  return (
    <div className="mock-head">
      <span className="avatar">{String(p.brand_name ?? '?').slice(0, 1).toUpperCase()}</span>
      <div>
        <b>{p.brand_name}</b>
        <div className="muted">{sub}</div>
      </div>
    </div>
  );
}

const Img = ({ src, p }: { src?: string; p: Row }) =>
  src ? <img className="mock-img" src={src} alt="" width={p.visual_width ?? undefined} height={p.visual_height ?? undefined} /> : null;

const Text = ({ children }: { children: ReactNode }) => <div className="mock-text">{children}</div>;

function Telegram({ p, img }: Props) {
  return (
    <div className="mock tg">
      <Head p={p} sub="Telegram channel" />
      <Img src={img} p={p} />
      <Text>{p.content?.text ?? p.plain_text}</Text>
    </div>
  );
}

function Social({ p, img, kind }: Props & { kind: 'linkedin' | 'instagram' | 'facebook' }) {
  const text = p.content?.text ?? p.plain_text;
  if (kind === 'instagram') {
    return (
      <div className="mock ig">
        <Head p={p} sub={`@${p.brand_slug}`} />
        <Img src={img} p={p} />
        <div className="mock-actions">♡ 💬 ↗</div>
        <Text>
          <b>{p.brand_slug}</b> {text}
        </Text>
      </div>
    );
  }
  return (
    <div className={`mock ${kind}`}>
      <Head p={p} sub={kind === 'linkedin' ? 'Company page' : 'Page post'} />
      <Text>{text}</Text>
      <Img src={img} p={p} />
      <div className="mock-actions">{kind === 'linkedin' ? 'Like · Comment · Repost · Send' : 'Like · Comment · Share'}</div>
    </div>
  );
}

function XThread({ p, img }: Props) {
  const posts: string[] = Array.isArray(p.content?.posts) ? p.content.posts : [p.content?.text ?? p.plain_text];
  return (
    <div className="mock x">
      {posts.map((t, i) => (
        <div key={i} className="x-post">
          <span className="avatar">{String(p.brand_name ?? '?').slice(0, 1).toUpperCase()}</span>
          <div>
            <b>{p.brand_name}</b> <span className="muted">@{p.brand_slug}</span>
            <Text>{t}</Text>
            {i === 0 && <Img src={img} p={p} />}
            <div className="muted small">
              {i + 1}/{posts.length} · {String(t ?? '').length} chars
            </div>
          </div>
        </div>
      ))}
    </div>
  );
}

function EmailBlock({ p, img }: Props) {
  const c = p.content ?? {};
  return (
    <div className="mock email">
      <div className="email-bar">{p.brand_name} newsletter</div>
      <div className="email-block">
        <Img src={img} p={p} />
        <h2>{c.title}</h2>
        <Text>{c.body ?? p.plain_text}</Text>
        <span className="email-link">{c.link_label || 'Read more'} →</span>
      </div>
    </div>
  );
}

export function PreviewMock({ p, img }: Props) {
  switch (p.platform) {
    case 'telegram':
      return <Telegram p={p} img={img} />;
    case 'linkedin':
    case 'instagram':
    case 'facebook':
      return <Social p={p} img={img} kind={p.platform} />;
    case 'x':
      return <XThread p={p} img={img} />;
    case 'email':
      return <EmailBlock p={p} img={img} />;
    case 'blog':
      return (
        <article className="mock article">
          <ArticleBody content={p.content ?? {}} cover={img} link={(u) => u} />
        </article>
      );
    default:
      return (
        <div className="mock">
          <Text>{p.plain_text}</Text>
        </div>
      );
  }
}
