// ביקורת קריאה בלבד: כל המסמכים, התשלומים והכרטיסים השמורים של היום ב-Morning. בלי חיוב, בלי שינוי. בלי פרטים אישיים.
import { MorningClient } from '../../supabase/functions/_shared/morning.ts';
const envMap: Record<string, string> = { MORNING_API_BASE: 'https://api.greeninvoice.co.il/api/v1' };
const env = (k: string) => envMap[k] ?? Deno.env.get(k) ?? '';
const m = new MorningClient(env, fetch);
const out: string[] = [];
const il = (sec: unknown) => { const n = Number(sec); return n > 1e9 ? new Date(n * 1000).toLocaleTimeString('he-IL', { timeZone: 'Asia/Jerusalem', hour: '2-digit', minute: '2-digit' }) : '?'; };
const day = '2026-10-22';
try {
  const d = await m.request('POST', '/documents/search', { page: 1, pageSize: 50, fromDate: day, toDate: day }, false) as Record<string, unknown>;
  const items = (Array.isArray(d.items) ? d.items : []) as Record<string, unknown>[];
  out.push(`מסמכים היום: ${items.length} (סה"כ לפי Morning: ${d.total ?? '?'})`);
  for (const x of items) {
    const full = await m.getDocument(String(x.id)) as Record<string, unknown>;
    const pays = (Array.isArray(full.payment) ? full.payment : []) as Record<string, unknown>[];
    out.push(`• מסמך ${full.number} · סוג ${full.type} · ₪${full.amount} · נוצר ${il(full.creationDate)} · סטטוס ${full.status} · תקבולים: ${pays.map((p) => `סוג ${p.type} ₪${p.price}`).join(', ') || 'אין'}`);
  }
} catch (e) { out.push('מסמכים: שגיאה ' + String((e as Error).message).slice(0, 150)); }
try {
  const p = await m.request('POST', '/documents/payments/search', { page: 1, pageSize: 50, fromDate: day, toDate: day }, false) as Record<string, unknown>;
  const items = (Array.isArray(p.items) ? p.items : []) as Record<string, unknown>[];
  out.push(`תקבולים היום (payments/search): ${items.length}${items.length ? ' · ' + items.map((x) => `₪${x.price ?? x.amount} ${x.date ?? ''}`).join(' | ') : ''}`);
} catch (e) { out.push('תקבולים: ' + String((e as Error).message).slice(0, 150)); }
try {
  const t = await m.request('POST', '/payments/tokens/search', { page: 1, pageSize: 25 }, false) as Record<string, unknown>;
  const items = (Array.isArray(t.items) ? t.items : []) as Record<string, unknown>[];
  out.push(`כרטיסים שמורים: ${t.total ?? items.length}${items.length ? ' · ' + items.map((x) => `מסתיים ${String(x.number ?? '').slice(-4)} · סטטוס ${x.status} · נשמר ${il(x.creationDate)}`).join(' | ') : ''}`);
} catch (e) { out.push('כרטיסים: ' + String((e as Error).message).slice(0, 150)); }
console.log(`::notice title=today-audit::${out.join('%0A')}`);
