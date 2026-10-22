// יוצר קישור מאובטח של Grow/Morning לשמירת הכרטיס של הבעלים (POST /payments/tokens/url) — בלי חיוב. הקישור נכתב לקובץ בלבד (מוצפן אחר כך).
import { MorningClient } from '../../supabase/functions/_shared/morning.ts';
const envMap: Record<string, string> = { MORNING_API_BASE: 'https://api.greeninvoice.co.il/api/v1' };
const env = (k: string) => envMap[k] ?? Deno.env.get(k) ?? '';
const m = new MorningClient(env, fetch);
const fail = (w: string, e: unknown) => { console.log(`::error title=card-link::${w}: ${String((e as Error)?.message ?? e).replace(/https?:\/\/\S+/g, '<קישור>').slice(0, 300)}`); Deno.exit(1); };
globalThis.addEventListener('unhandledrejection', (ev) => { ev.preventDefault(); fail('שגיאה', ev.reason); });
const ds = await m.request('POST', '/documents/search', { page: 1, pageSize: 20, fromDate: '2026-10-22', toDate: '2026-10-22' }, false) as Record<string, unknown>;
const doc = ((ds.items as Record<string, unknown>[]) ?? []).find((d) => Number(d.number) === 358304) ?? {};
const cid = String(((doc.client ?? {}) as Record<string, unknown>).id ?? '');
if (!cid) { console.log('::error title=card-link::לקוח Morning של הבעלים לא נמצא'); Deno.exit(1); }
const r = await m.request('POST', '/payments/tokens/url', { lang: 'he', pluginId: '53ed9395-02de-4902-a1dd-28dd3f74a5fa', channel: 1,
  client: { id: cid }, externalKey: cid, successUrl: 'https://haim-derech-misparim.pages.dev/?billing=card' }, false) as Record<string, unknown>;
const url = typeof r.url === 'string' ? r.url : '';
if (!/^https:\/\//.test(url)) { console.log('::error title=card-link::לא התקבל קישור'); Deno.exit(1); }
Deno.writeTextFileSync(Deno.env.get('OUTF')!, JSON.stringify({ url, host: new URL(url).host, created: new Date().toISOString(), externalKey: 'morning-client-id' }));
console.log(`::notice title=card-link::✅ קישור שמירת כרטיס נוצר (מארח ${new URL(url).host}), נשמר מוצפן. בלי חיוב.`);
