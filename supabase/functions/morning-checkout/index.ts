// =====================================================================
// חיים דרך מספרים — morning-checkout (Staging בלבד עד אישור)
//
// הדפדפן קורא לפונקציה אחרי hdm_billing_start_checkout / hdm_billing_start_upgrade, עם ה-checkoutId והטוקן של המשתמש.
//   * הצטרפות → דף תשלום מאובטח של Morning (Grow). המנוי מופעל רק כש-morning-webhook מאמת את המסמך מול Morning.
//   * שדרוג עם כרטיס שמור → חיוב יחסי בכרטיס השמור מהשרת, והפעלה רק אחרי תשובה חיובית מ-Morning.
// פרטי הכרטיס לא עוברים דרכנו. המפתחות של Morning נקראים רק מסודות הפונקציה.
// כבוי עד MORNING_LIVE=1. מול חשבון ה-Production של Morning — חסום מחוץ ל-HDM_ENV=production.
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2';
import {
  CheckoutInfo, MorningClient, MorningError, PLAN_HE, assertMoneyAllowed, notifyUrlFor, paymentFormBody, tokenChargeBody,
} from '../_shared/morning.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const admin = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, content-type, apikey, x-client-info',
  'access-control-allow-methods': 'POST, OPTIONS',
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'content-type': 'application/json' } });

async function claim(id: string, ref: string): Promise<boolean> {
  const { data, error } = await admin.rpc('hdm_billing_claim_checkout', { p_checkout: id, p_process_id: ref });
  if (error) throw error;
  return data === true;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });
  if (req.method !== 'POST') return reply(405, { error: 'method' });
  try {
    const jwt = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
    const { data: who } = await admin.auth.getUser(jwt);
    if (!who?.user) return reply(401, { error: 'auth' });

    // שלב בדיקה: כשמוגדר HDM_BILLING_ALLOWED_USERS (רשימת מזהי משתמש), רק הם יכולים לשלם. כל השאר — 403, בלי לגעת ב-Morning.
    const allowed = env('HDM_BILLING_ALLOWED_USERS').split(',').map((x) => x.trim()).filter(Boolean);
    if (allowed.length && !allowed.includes(who.user.id)) return reply(403, { error: 'not_open' });

    const { checkoutId } = await req.json().catch(() => ({}));
    if (typeof checkoutId !== 'string' || !/^[0-9a-f-]{36}$/i.test(checkoutId)) return reply(400, { error: 'checkout' });
    const { data: ck, error } = await admin.rpc('hdm_billing_checkout_lookup', { p_checkout: checkoutId });
    if (error) throw error;
    const c = ck as CheckoutInfo | null;
    if (!c || c.userId !== who.user.id) return reply(404, { error: 'checkout' });
    if (c.status !== 'pending' || c.expired) return reply(409, { error: 'not_pending', status: c.status });
    const processId = String((c as unknown as Record<string, unknown>).processId ?? '');
    if (processId.startsWith('morning-charge:')) return reply(409, { error: 'in_progress' });   // חיוב כבר נשלח

    const m = new MorningClient(env, fetch);

    // שדרוג עם כרטיס שמור: חיוב יחסי מיידי
    if (c.kind === 'upgrade' && c.token) {
      assertMoneyAllowed(env);                       // לפני התפיסה — כדי שכשהסליקה כבויה הניסיון לא "יינעל"
      if (!await claim(c.id, `morning-charge:${c.id}`)) return reply(409, { error: 'in_progress' });
      const desc = `שדרוג ל-${PLAN_HE[c.plan] ?? c.plan} (יתרת התקופה) — חיים דרך מספרים`;
      let event: Record<string, unknown>;
      try {
        const doc = await m.chargeToken(c.token, tokenChargeBody(desc, c.amountAgorot)) as Record<string, unknown>;
        const docId = String(doc.id ?? doc.documentId ?? '');
        const amt = Math.round(Number(doc.amount ?? NaN) * 100);
        const ref = docId || String(doc.transactionId ?? '') || `upgrade-${c.id}`;
        event = { transactionId: `morning:${ref}`, kind: 'upgrade', outcome: 'approved',
                  amountAgorot: Number.isFinite(amt) ? amt : c.amountAgorot, checkoutId: c.id,
                  raw: { provider: 'morning', documentId: docId, transactionId: doc.transactionId ?? null } };
      } catch (e) {
        if (e instanceof MorningError && e.code === 'REJECTED') {
          event = { transactionId: `morning-fail:${c.id}`, kind: 'upgrade', outcome: 'failed', amountAgorot: c.amountAgorot,
                    checkoutId: c.id, raw: { provider: 'morning', error: e.message.slice(0, 300) } };
        } else throw e;   // תקלת רשת / כבוי — לא משנים כלום; ניסיון התשלום יפוג מעצמו
      }
      const { data: res, error: e2 } = await admin.rpc('hdm_billing_apply_grow_event', { p: event });
      if (e2) throw e2;
      return reply(200, { mode: 'charged', result: (res as Record<string, unknown>)?.result ?? null });
    }

    // הצטרפות (או שדרוג בלי כרטיס שמור): דף תשלום
    // דף תשלום חדש מותר גם בניסיון חוזר (הלקוח סגר את הדף). תשלום שני לאותו ניסיון נתפס במסד כ-duplicate ומסומן להחזר.
    assertMoneyAllowed(env);
    const form = await m.createPaymentForm(paymentFormBody(env, c, notifyUrlFor(env, c.id))) as Record<string, unknown>;
    const url = typeof form.url === 'string' ? form.url : String((form.url as Record<string, string>)?.he ?? '');
    if (!/^https:\/\//.test(url)) throw new MorningError('NO_URL', 'Morning לא החזירה כתובת דף תשלום');
    return reply(200, { mode: 'redirect', url });
  } catch (e) {
    const code = e instanceof MorningError ? e.code : 'ERROR';
    console.error('morning-checkout', code, e instanceof Error ? e.message.slice(0, 300) : '');
    const status = code === 'MORNING_OFF' || code === 'PRODUCTION_BLOCKED' ? 503 : 502;
    return reply(status, { error: code });
  }
});
