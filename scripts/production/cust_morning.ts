// custmorning — קריאה בלבד ב-Morning עבור לקוח אחד (מזהה הלקוח מגיע מהמסד, לא מודפס): מסמכי חיוב, כרטיסים שמורים.
import { MorningClient, findCardToken } from '../../supabase/functions/_shared/morning.ts';
const envMap: Record<string, string> = { MORNING_API_BASE: 'https://api.greeninvoice.co.il/api/v1' };
const env = (k: string) => envMap[k] ?? Deno.env.get(k) ?? '';
const m = new MorningClient(env, fetch); const cid = Deno.env.get('CID') ?? ''; const out: string[] = [];
try {
  const r = await m.searchDocuments({ clientId: cid, fromDate: '2026-10-20', toDate: '2026-10-27', page: 1, pageSize: 20 }) as Record<string, unknown>;
  const items = ((r.items ?? []) as Record<string, unknown>[]).filter((d) => (d.client as Record<string, unknown> | undefined)?.id === cid);
  out.push(`מסמכי חיוב/קבלה ללקוח: ${items.length}${items.length ? ' — ' + items.map((d) => `סוג ${d.type} ₪${d.amount} סטטוס ${d.status}`).join(', ') : ''}`);
} catch (e) { out.push(`חיפוש מסמכים ❌ ${String(e).slice(0, 120)}`); }
try {
  const all = await m.searchDocuments({ fromDate: '2026-10-26', toDate: '2026-10-27', page: 1, pageSize: 50 }) as Record<string, unknown>;
  out.push(`כל המסמכים בעסק היום: ${((all.items ?? []) as unknown[]).length}`);
} catch (e) { out.push(`מסמכים היום ❌ ${String(e).slice(0, 100)}`); }
try { const t = await findCardToken(m, cid, 0); out.push(`כרטיס שמור אצל Grow ללקוח: ${t ? `כן ✅ (4 ספרות: ${t.last4 ? 'קיימות' : 'לא'})` : 'לא'}`); } catch (e) { out.push(`כרטיסים ❌ ${String(e).slice(0, 100)}`); }
console.log(`::notice title=cm-morning::${out.join(' | ')}`);
