// paycheck — מחפש ב-Morning את המסמך של תשלום הבדיקה (קריאה בלבד), מריץ את אותו אימות של morning-webhook (יבש),
// ומדפיס רק שדות לא-אישיים. כותב ל-$GITHUB_OUTPUT: doc=<id> ו-bound=true|false.
import { MorningClient, verifyDocumentAgainstCheckout, findCardToken } from '../../supabase/functions/_shared/morning.ts';
const envMap: Record<string, string> = { MORNING_API_BASE: 'https://api.greeninvoice.co.il/api/v1' };
const env = (k: string) => envMap[k] ?? Deno.env.get(k) ?? '';
const ck = JSON.parse(Deno.env.get('CK_JSON') ?? 'null');
const out: string[] = [];
const m = new MorningClient(env, fetch);
const today = new Date(Date.now() + 3 * 3600e3).toISOString().slice(0, 10);
const res = await m.request('POST', '/documents/search', { page: 1, pageSize: 20, fromDate: today, toDate: today }, false) as Record<string, unknown>;
const items = (Array.isArray(res.items) ? res.items : []) as Record<string, unknown>[];
out.push(`מסמכים היום ב-Morning: ${items.length}`);
const cand = items.filter((d) => Math.abs(Number(d.amount) - 29.9) < 0.001).sort((a, b) => Number(b.creationDate ?? 0) - Number(a.creationDate ?? 0));
let docId = '', bound = false;
for (const d of cand.slice(0, 3)) {
  const full = await m.getDocument(String(d.id)) as Record<string, unknown>;
  const v = verifyDocumentAgainstCheckout(full, ck);
  const cl = (full.client ?? {}) as Record<string, unknown>;
  const emails = ([] as unknown[]).concat(cl.emails ?? []).map((e) => String(e).toLowerCase());
  const pays = (Array.isArray(full.payment) ? full.payment : []) as Record<string, unknown>[];
  const tok = await findCardToken(m, typeof cl.id === 'string' ? cl.id : undefined, ck ? Date.parse(ck.createdAt) : 0).catch(() => null);
  out.push(`מסמך #${full.number} · סוג ${full.type} · סטטוס ${full.status} · ₪${full.amount} ${full.currency ?? ''} · נוצר ${new Date(Number(full.creationDate) * 1000).toISOString()} · מייל הלקוח תואם לחשבון: ${ck?.email ? emails.includes(ck.email.toLowerCase()) : '?'} · תשלומים במסמך: ${pays.map((p) => `סוג ${p.type} ₪${p.price}`).join(', ') || '—'} · custom ${full.custom ? (String(JSON.stringify(full.custom)).includes(ck?.id ?? '§') ? '= מזהה הניסיון ✅' : 'אחר') : 'אין'} · כרטיס שמור לחידושים: ${tok ? 'קיים ✅' : 'לא נמצא'} · אימות: ${v.bound ? '✅ תואם לניסיון התשלום' : '❌'} ${v.problems.join('; ')}`);
  if (!docId) { docId = String(full.id); bound = v.bound && v.problems.length === 0; }
}
if (!cand.length) out.push('לא נמצא מסמך של ₪29.90 היום');
console.log(`::notice title=paycheck::${out.join('%0A')}`);
const gh = Deno.env.get('GITHUB_OUTPUT'); if (gh) Deno.writeTextFileSync(gh, `doc=${docId}\nbound=${bound}\n`, { append: true });
