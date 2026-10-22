// בדיקת קישור שמירת כרטיס (POST /payments/tokens/url) — קישור בלבד, channel=1 (לא נשלח מייל), לא נפתח. אין חיוב.
import { MorningClient } from '../../supabase/functions/_shared/morning.ts';
const envMap: Record<string, string> = { MORNING_API_BASE: 'https://api.greeninvoice.co.il/api/v1' };
const env = (k: string) => envMap[k] ?? Deno.env.get(k) ?? '';
const m = new MorningClient(env, fetch);
const out: string[] = [];
const scrub = (s: string) => s.replace(/https?:\/\/\S+/g, '<קישור>').replace(/\b\d{6,}\b/g, '<מספר>').slice(0, 400);
const today = new Date(Date.now() + 3 * 3600e3).toISOString().slice(0, 10);
const ds = await m.request('POST', '/documents/search', { page: 1, pageSize: 5, fromDate: today, toDate: today }, false) as Record<string, unknown>;
const d0 = ((ds.items as Record<string, unknown>[]) ?? [])[0] ?? {};
const cid = String(((d0.client ?? {}) as Record<string, unknown>).id ?? '');
out.push(`לקוח מהמסמך של היום: ${cid ? 'נמצא' : 'לא נמצא'}`);
const P = '53ed9395-02de-4902-a1dd-28dd3f74a5fa';
const variants: [string, Record<string, unknown>][] = [
  ['client.id', { lang: 'he', pluginId: P, channel: 1, client: { id: cid }, externalKey: cid }],
  ['id ברמה העליונה', { id: cid, lang: 'he', pluginId: P, channel: 1, externalKey: cid }],
  ['clientId', { clientId: cid, lang: 'he', pluginId: P, channel: 1, externalKey: cid }],
  ['client.id + successUrl/notifyUrl', { lang: 'he', pluginId: P, channel: 1, client: { id: cid }, externalKey: cid,
     successUrl: 'https://haim-derech-misparim.pages.dev/?billing=card', notifyUrl: 'https://qtspzigjlbtckqfyaubp.supabase.co/functions/v1/morning-webhook?probe=1' }],

];
for (const [label, body] of variants) {
  try {
    const r = await m.request('POST', '/payments/tokens/url', body, false) as Record<string, unknown>;
    const url = typeof r.url === 'string' ? r.url : '';
    out.push(`${url ? '✅' : '❌'} ${label}: ${url ? 'קישור שמירת כרטיס נוצר — מארח ' + new URL(url).host + ' · שדות בתשובה: ' + Object.keys(r).join(',') : scrub(JSON.stringify(r))}`);
  } catch (e) { out.push(`❌ ${label}: ${scrub(String((e as Error).message))}`); }
}
console.log(`::notice title=token-link-probe::${out.join('%0A')}`);
