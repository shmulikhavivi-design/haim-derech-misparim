// בדיקת יצירת דף תשלום בדיוק כמו morning-checkout ב-Production (אותו קוד: _shared/morning.ts). לא נפתח ולא משולם — אין חיוב.
// לא מדפיס מפתחות, טוקנים או קישורים מלאים.
import { MorningClient, MorningError, paymentFormBody, notifyUrlFor, assertMoneyAllowed } from '../../supabase/functions/_shared/morning.ts';
const base: Record<string, string> = {
  HDM_ENV: 'production', MORNING_LIVE: '1', MORNING_API_BASE: 'https://api.greeninvoice.co.il/api/v1',
  MORNING_PLUGIN_ID: '53ed9395-02de-4902-a1dd-28dd3f74a5fa', HDM_APP_URL: 'https://haim-derech-misparim.pages.dev',
  SUPABASE_URL: 'https://qtspzigjlbtckqfyaubp.supabase.co', MORNING_WEBHOOK_TOKEN: 'probe-token-not-real',
};
const out: string[] = [];
const scrub = (s: string) => s.replace(/https?:\/\/\S+/g, '<קישור>').replace(/\b\d{6,}\b/g, '<מספר>').slice(0, 500);
async function attempt(label: string, extra: Record<string, string>, email: string | null) {
  const envMap = { ...base, ...extra };
  const env = (k: string) => envMap[k] ?? Deno.env.get(k) ?? '';
  const ck = { id: crypto.randomUUID(), userId: 'x', plan: 'basic', amountAgorot: 2990, status: 'pending', kind: 'initial', email } as any;
  try {
    assertMoneyAllowed(env);
    const m = new MorningClient(env, fetch);
    const body = paymentFormBody(env, ck, notifyUrlFor(env, ck.id));
    const form = await m.createPaymentForm(body) as Record<string, unknown>;
    const url = typeof form.url === 'string' ? form.url : String((form.url as Record<string, string>)?.he ?? '');
    out.push(`${/^https:\/\//.test(url) ? '✅' : '❌'} ${label}: ${/^https:\/\//.test(url) ? 'דף תשלום נוצר — מארח ' + new URL(url).host : 'אין כתובת: ' + scrub(JSON.stringify(form))}`);
  } catch (e) {
    const det = e instanceof MorningError ? `${e.code} ${scrub(e.message)} ${scrub(JSON.stringify((e as any).body ?? (e as any).data ?? ''))}` : scrub(String(e));
    out.push(`❌ ${label}: ${det}`);
  }
}
const rawId = Deno.env.get('MORNING_CLIENT_ID') ?? '';
const uuid = rawId.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i)?.[0] ?? '';
// כמו שהערך נשמר בסודות הפונקציה דרך env-file (שורה בלי מרכאות): ננסה גם את הגרסה החתוכה ברווח הראשון
const dotenvCut = rawId.split(/\s+/)[0];
await attempt('אותו קוד, ID כפי שהוא', {}, 'owner@example.invalid');
await attempt('אותו קוד, בלי אימייל לקוח', {}, null);
await attempt('ID נקי (UUID בלבד)', { MORNING_CLIENT_ID: uuid }, 'owner@example.invalid');
await attempt('ID חתוך ברווח הראשון (כמו env-file)', { MORNING_CLIENT_ID: dotenvCut }, 'owner@example.invalid');
out.push(`מבנה ה-ID: אורך ${rawId.length}, UUID ${uuid ? 'נמצא' : 'לא נמצא'}, חלק ראשון ${dotenvCut.length} תווים ${dotenvCut === uuid ? '(=UUID)' : '(שונה מה-UUID)'}`);
console.log(`::notice title=checkout-probe::${out.join('%0A')}`);
