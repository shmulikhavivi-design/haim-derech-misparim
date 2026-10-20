// =====================================================================
// חיים דרך מספרים — grow-checkout (Staging בלבד עד אישור)
//
// נקראת עם ה-checkoutId שנוצר ב-hdm_billing_start_checkout / hdm_billing_start_upgrade, ועם הטוקן של המשתמש.
//   * הצטרפות → דף תשלום של Grow (createPaymentProcess) עם שמירת הכרטיס. המנוי מופעל רק ב-grow-webhook אחרי אימות.
//   * שדרוג עם כרטיס שמור → חיוב יחסי בכרטיס (createTransactionWithToken), והמסלול מתעדכן רק אחרי תשובה חיובית.
// פרטי הכרטיס לא עוברים דרכנו. כבוי עד GROW_LIVE=1; חשבון ה-Production של Grow חסום מחוץ ל-HDM_ENV=production.
// הערה: עמוד התשלום הקיים באפליקציה לא שונה — הוא יחובר לפונקציה הזו רק באישור.
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2';
import {
  CheckoutInfo, GrowClient, GrowError, PLAN_HE, assertGrowMoneyAllowed, notifyUrlFor, paymentProcessFields, tokenChargeFields,
} from '../_shared/grow.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const admin = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
const CORS = {
  'access-control-allow-origin': env('HDM_APP_ORIGIN') || '*',
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

    const { checkoutId } = await req.json().catch(() => ({}));
    if (typeof checkoutId !== 'string' || !/^[0-9a-f-]{36}$/i.test(checkoutId)) return reply(400, { error: 'checkout' });
    const { data, error } = await admin.rpc('hdm_billing_checkout_lookup', { p_checkout: checkoutId });
    if (error) throw error;
    const c = data as CheckoutInfo | null;
    if (!c || c.userId !== who.user.id) return reply(404, { error: 'checkout' });
    if (c.status !== 'pending' || c.expired) return reply(409, { error: 'not_pending', status: c.status });
    if (String(c.processId ?? '').startsWith('grow-charge:')) return reply(409, { error: 'in_progress' });

    assertGrowMoneyAllowed(env);   // לפני כל תפיסה — כשהסליקה כבויה שום דבר לא ננעל ולא נשלח
    const g = new GrowClient(env, fetch);

    // שדרוג עם כרטיס שמור: חיוב יחסי מיידי
    if (c.kind === 'upgrade' && c.token) {
      const { data: card } = await admin.rpc('hdm_billing_card_details', { p_profile: c.profileId });
      const cd = (card ?? {}) as Record<string, string | null>;
      if (!cd.name || !cd.phone) return reply(409, { error: 'payer_details_missing' });
      if (!await claim(c.id, `grow-charge:${c.id}`)) return reply(409, { error: 'in_progress' });
      let event: Record<string, unknown>;
      try {
        const res = await g.createTransactionWithToken(await tokenChargeFields({
          token: c.token, agorot: c.amountAgorot, name: cd.name, phone: cd.phone, key: `upgrade:${c.id}`, checkoutId: c.id,
          description: `שדרוג ל-${PLAN_HE[c.plan] ?? c.plan} (יתרת התקופה) - חיים דרך מספרים`, recurring: false,
        }));
        const tx = String(res.data.transactionId ?? res.data.transaction_id ?? '') || `upgrade-${c.id}`;
        event = { transactionId: `grow:${tx}`, kind: 'upgrade', outcome: 'approved', amountAgorot: c.amountAgorot, checkoutId: c.id,
                  raw: { provider: 'grow', transactionId: tx, asmachta: res.data.asmachta ?? null } };
      } catch (e) {
        if (!(e instanceof GrowError && e.code === 'REJECTED')) throw e;   // אין תשובה ברורה — לא נוגעים; לבדיקה ידנית
        event = { transactionId: `grow-fail:${c.id}`, kind: 'upgrade', outcome: 'failed', amountAgorot: c.amountAgorot, checkoutId: c.id,
                  raw: { provider: 'grow', error: e.message.slice(0, 300) } };
      }
      const { data: res, error: e2 } = await admin.rpc('hdm_billing_apply_grow_event', { p: event });
      if (e2) throw e2;
      return reply(200, { mode: 'charged', result: (res as Record<string, unknown>)?.result ?? null });
    }

    // הצטרפות: דף תשלום (פתיחה חוזרת מותרת אם הלקוח סגר את הדף; תשלום כפול נתפס במסד כ-duplicate ולהחזר)
    const res = await g.createPaymentProcess(paymentProcessFields(env, c, notifyUrlFor(env, c.id)));
    const url = String(res.data.url ?? '');
    if (!/^https:\/\//.test(url)) throw new GrowError('NO_URL', 'Grow לא החזירה כתובת דף תשלום');
    if (res.data.processId) await admin.rpc('hdm_billing_attach_process', { p_checkout: c.id, p_process_id: `grow-process:${res.data.processId}` });
    return reply(200, { mode: 'redirect', url });
  } catch (e) {
    const code = e instanceof GrowError ? e.code : 'ERROR';
    console.error('grow-checkout', code, e instanceof Error ? e.message.slice(0, 300) : '');
    return reply(code === 'GROW_OFF' || code === 'PRODUCTION_BLOCKED' ? 503 : 502, { error: code });
  }
});
