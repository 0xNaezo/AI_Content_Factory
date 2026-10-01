import type { SP } from '@/lib/format';

export default async function Expired({ searchParams }: { searchParams: Promise<SP> }) {
  const out = (await searchParams).out === '1';
  return (
    <main className="narrow card">
      <h1>{out ? 'You are logged out' : 'Your panel link has expired'}</h1>
      <p>
        {out ? 'To open the panel again,' : 'Panel links work once and for a short time. To get a new one,'} send <code>/panel</code> to the bot
        in Telegram.
      </p>
    </main>
  );
}
