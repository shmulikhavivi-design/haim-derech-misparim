// בדיקת קישור שמירת כרטיס (POST /payments/tokens/url) — קישור בלבד, channel=1 (לא נשלח מייל), לא נפתח. אין חיוב.
import { MorningClient } from '../../supabase/functions/_shared/morning.ts';
const envMap: Record<string, string> = { MORNING_API_BASE: 'https://api.greeninvoice.co.il/api/v1' };
const env = (k: string) => envMap[k] ?? Deno.env.get(k) ?? '';
const m = new MorningClient(env, fetch);
const out: string[] = [];
const scrub = (s: string) => s.replace(/https?:\/\/\S+/g, '<קישור>').replace(/\b\d{6,}\b/g, '<מספר>').slice(0, 400);
const variants: [string, Record<string, unknown>][] = [
  ['בסיסי', { lang: 'he', pluginId: '53ed9395-02de-4902-a1dd-28dd3f74a5fa', channel: 1, externalKey: 'probe-' + crypto.randomUUID() }],
  ['עם successUrl/notifyUrl', { lang: 'he', pluginId: '53ed9395-02de-4902-a1dd-28dd3f74a5fa', channel: 1, externalKey: 'probe-' + crypto.randomUUID(),
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
