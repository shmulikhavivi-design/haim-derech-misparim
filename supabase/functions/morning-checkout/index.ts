// =====================================================================
// חיים דרך מספרים — morning-checkout (Staging בלבד עד אישור)
//
// הדפדפן קורא לפונקציה אחרי hdm_billing_start_checkout / hdm_billing_start_upgrade, עם ה-checkoutId והטוקן של המשתמש.
//   * הצטרפות (אפשרות 2, 22.10): הלקוח מזין כרטיס פעם אחת בדף מאובטח של Grow (שמירת כרטיס, בלי חיוב) →
//     step:'complete' — השרת מוצא את הכרטיס השמור, "תופס" את ניסיון התשלום (פעם אחת בלבד) ומחייב את החודש הראשון.
//     המנוי מופעל רק אחרי שחיוב אושר ומסמך Morning אומת (_shared/card_flow.ts). החידושים — באותו כרטיס (morning-renewals).
//   * step:'sync' — מנוי בתשלום קיים בלי כרטיס שמור: קישור הכרטיס שהלקוח שמר אצל Grow למנוי (בלי חיוב).
//   * שדרוג עם כרטיס שמור → חיוב יחסי בכרטיס השמור מהשרת, והפעלה רק אחרי תשובה חיובית מ-Morning.
// פרטי הכרטיס לא עוברים דרכנו. המפתחות של Morning נקראים רק מסודות הפונקציה.
// כבוי עד MORNING_LIVE=1. מול חשבון ה-Production של Morning — חסום מחוץ ל-HDM_ENV=production.
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2';
import { CheckoutInfo, MorningClient, MorningError, PLAN_HE, assertMoneyAllowed, findCardToken, tokenChargeBody } from '../_shared/morning.ts';
import { FlowDb, runCardCheckout } from '../_shared/card_flow.ts';
import { makeFlowDb } from '../_shared/flow_db.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const admin = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, content-type, apikey, x-client-info',
  'access-control-allow-methods': 'POST, OPTIONS',
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'content-type': 'application/json' } });

const flowDb: FlowDb = makeFlowDb(admin, 'morning-checkout');
const claim = (id: string, ref: string) => flowDb.claim(id, ref);

// מנוי בתשלום קיים בלי כרטיס שמור (למשל תשלום ראשון בדף תשלום): מקשר את הכרטיס שהלקוח שמר אצל Grow. בלי חיוב.
async function syncCard(userId: string): Promise<Response> {
  const { data: acc } = await admin.from('hdm_accounts').select('profile_id').eq('auth_user_id', userId).maybeSingle();
  const pid = acc?.profile_id as string | undefined;
  if (!pid) return reply(404, { error: 'profile' });
  const { data: sub } = await admin.from('hdm_subscriptions').select('source').eq('profile_id', pid).maybeSingle();
  if (!sub || sub.source !== 'payment') return reply(409, { error: 'no_paid_subscription' });
  const m = new MorningClient(env, fetch);
  let cid = await flowDb.customerId(pid) ?? undefined;
  if (!cid) {   // לקוח Morning מהמסמך של התשלום האחרון
    const { data: pay } = await admin.from('hdm_payments').select('raw').eq('profile_id', pid).eq('outcome', 'approved')
      .order('received_at', { ascending: false }).limit(1).maybeSingle();
    const docId = String(((pay?.raw ?? {}) as Record<string, unknown>).documentId ?? '');
    if (docId) cid = String((((await m.getDocument(docId)) as Record<string, unknown>).client as Record<string, unknown> | undefined)?.id ?? '') || undefined;
    if (cid) await flowDb.saveCustomer(pid, cid);
  }
  if (!cid) return reply(409, { error: 'no_customer' });
  const t = await findCardToken(m, cid, 0);
  if (!t) return reply(202, { mode: 'waiting' });
  await flowDb.saveToken(pid, t.id, t.last4);
  return reply(200, { mode: 'card_saved', last4: t.last4 });
}

Deno.serve(async (req) => {
  let stepOf = 'start';
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });
  if (req.method !== 'POST') return reply(405, { error: 'method' });
  try {
    const jwt = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
    const { data: who } = await admin.auth.getUser(jwt);
    if (!who?.user) return reply(401, { error: 'auth' });

    // שלב בדיקה: כשמוגדר HDM_BILLING_ALLOWED_USERS (רשימת מזהי משתמש), רק הם יכולים לשלם. כל השאר — 403, בלי לגעת ב-Morning.
    const allowed = env('HDM_BILLING_ALLOWED_USERS').split(',').map((x) => x.trim()).filter(Boolean);
    if (allowed.length && !allowed.includes(who.user.id)) return reply(403, { error: 'not_open' });

    const body = await req.json().catch(() => ({})) as Record<string, unknown>;
    const step = body.step === 'complete' ? 'complete' : body.step === 'sync' ? 'sync' : 'start';
    stepOf = step;
    if (step === 'sync') return await syncCard(who.user.id);
    let checkoutId = body.checkoutId;
    if (step === 'complete' && typeof checkoutId !== 'string') {   // חזרה מהדף בלי מזהה — הניסיון האחרון של המשתמש
      const { data: last } = await admin.from('hdm_checkouts').select('id').eq('user_id', who.user.id)
        .order('created_at', { ascending: false }).limit(1).maybeSingle();
      checkoutId = last?.id;
    }
    if (typeof checkoutId !== 'string' || !/^[0-9a-f-]{36}$/i.test(checkoutId)) return reply(400, { error: 'checkout' });
    const { data: ck, error } = await admin.rpc('hdm_billing_checkout_lookup', { p_checkout: checkoutId });
    if (error) throw error;
    const c = ck as CheckoutInfo | null;
    if (!c || c.userId !== who.user.id) return reply(404, { error: 'checkout' });
    if (c.status === 'paid') return reply(200, { mode: 'charged', result: 'already_paid' });
    if (c.status === 'failed') return reply(200, { mode: 'failed' });
    if (c.status !== 'pending' || c.expired) return reply(409, { error: 'not_pending', status: c.status });
    const processId = String((c as unknown as Record<string, unknown>).processId ?? '');
    if (processId.startsWith('morning-charge:')) return reply(202, { mode: 'processing' });   // חיוב כבר נשלח — לא שולחים שוב

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

    // הצטרפות (או שדרוג בלי כרטיס שמור): כרטיס שמור → חיוב מהשרת; אין כרטיס → קישור שמירת כרטיס של Grow
    const r = await runCardCheckout(step, c, m, env, flowDb, body.origin);
    return reply(r.status, r.body);
  } catch (e) {
    const code = e instanceof MorningError ? e.code : 'ERROR';
    console.error('morning-checkout', stepOf, code, e instanceof Error ? e.message.slice(0, 300) : '');
    const status = code === 'MORNING_OFF' || code === 'PRODUCTION_BLOCKED' ? 503 : 502;
    return reply(status, { error: code, step: stepOf });
  }
});
