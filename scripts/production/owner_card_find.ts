// מוצא את הכרטיס השמור של הבעלים ב-Morning (קריאה בלבד) לפי לקוח המסמך 358304. כותב לקובץ: token + last4. לא מדפיס את הטוקן.
import { MorningClient, findCardToken } from '../../supabase/functions/_shared/morning.ts';
const envMap: Record<string, string> = { MORNING_API_BASE: 'https://api.greeninvoice.co.il/api/v1' };
const env = (k: string) => envMap[k] ?? Deno.env.get(k) ?? '';
const m = new MorningClient(env, fetch);
const ds = await m.request('POST', '/documents/search', { page: 1, pageSize: 20, fromDate: '2026-10-22', toDate: '2026-10-22' }, false) as Record<string, unknown>;
const doc = ((ds.items as Record<string, unknown>[]) ?? []).find((d) => Number(d.number) === 358304) ?? {};
const cid = String(((doc.client ?? {}) as Record<string, unknown>).id ?? '');
const t = cid ? await findCardToken(m, cid, 0) : null;
if (!t) { console.log('::error title=owner-card::לא נמצא כרטיס שמור ללקוח של הבעלים'); Deno.exit(1); }
Deno.writeTextFileSync(Deno.env.get('OUTF')!, JSON.stringify({ token: t.id, last4: t.last4, client: cid }));
console.log(`::notice title=owner-card::✅ נמצא כרטיס שמור תקף ללקוח של הבעלים (מסתיים ${t.last4})`);
