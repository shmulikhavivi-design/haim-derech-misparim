// plusdoc — קריאה בלבד: המסמך ב-Morning מול ניסיון התשלום; כמה מסמכים ללקוח הזה מאז אתמול.
import { MorningClient, verifyChargeDocument } from '../../supabase/functions/_shared/morning.ts';
const envMap: Record<string, string> = { MORNING_API_BASE: 'https://api.greeninvoice.co.il/api/v1' };
const env = (k: string) => envMap[k] ?? Deno.env.get(k) ?? '';
const m = new MorningClient(env, fetch); const out: string[] = [];
const ck = JSON.parse(Deno.env.get('CK_JSON') || 'null');
try {
  const d = await m.getDocument(Deno.env.get('DOC') ?? '') as Record<string, unknown>;
  const c = (d.client ?? {}) as Record<string, unknown>;
  out.push(`מסמך: סוג ${d.type} (320=חשבונית מס/קבלה) | ₪${d.amount} | סטטוס ${d.status} | מבוטל ${Number(d.status) === 3 || Number(d.status) === 4 ? 'כן ❌' : 'לא ✅'}`);
  if (ck) { const v = verifyChargeDocument(d, ck); out.push(`תואם לניסיון התשלום: ${v.bound && !v.problems.length ? '✅' : '❌ ' + v.problems.join('; ')}`); }
  const r = await m.searchDocuments({ fromDate: '2026-10-26', toDate: '2026-10-28', page: 1, pageSize: 50 }) as Record<string, unknown>;
  const mine = ((r.items ?? []) as Record<string, unknown>[]).filter((x) => (x.client as Record<string, unknown> | undefined)?.id === c.id);
  out.push(`מסמכי חיוב ללקוח הזה מאתמול: ${mine.length} (${mine.map((x) => '₪' + x.amount).join(', ')})`);
} catch (e) { out.push(`❌ ${String(e).slice(0, 160)}`); }
console.log(`::notice title=pc-8-morning::${out.join(' | ')}`);
