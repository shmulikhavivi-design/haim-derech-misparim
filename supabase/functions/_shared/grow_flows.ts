// =====================================================================
// חיים דרך מספרים — הלוגיקה של פונקציות Grow, בלי תלות ב-Supabase או ב-Deno.serve.
// הפונקציות (grow-checkout / grow-webhook / grow-renewals) הן עטיפות דקות סביב הקובץ הזה,
// וכך אותו קוד בדיוק נבדק גם מקומית מול מסד בדיקה ותחליף Grow (scripts/grow_local/e2e_test.ts).
// =====================================================================
import {
  CheckoutInfo, EnvFn, FetchFn, GrowClient, GrowError, PLAN_HE, assertGrowMoneyAllowed, flattenGrowForm, notifyUrlFor,
  paymentProcessFields, safeEqual, tokenChargeFields, verifyGrowPayment,
} from './grow.ts';

/** גישה למסד כ-service_role. rpc מחזיר { data, error } כמו supabase-js. */
export interface Db {
  rpc(fn: string, args?: Record<string, unknown>): Promise<{ data: unknown; error: { message: string } | null }>;
  subscriptionPlan(profileId: string): Promise<string | null>;
}
export interface Out { status: number; body: Record<string, unknown> }
const R = (status: number, body: Record<string, unknown>): Out => ({ status, body });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function must(db: Db, fn: string, args: Record<string, unknown>) {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data;
}

// ---------------------------------------------------------------------
// grow-checkout: authUserId כבר אומת בעטיפה (טוקן המשתמש)
// ---------------------------------------------------------------------
export async function checkoutFlow(env: EnvFn, db: Db, fetchFn: FetchFn, authUserId: string | null, checkoutId: unknown): Promise<Out> {
  if (!authUserId) return R(401, { error: 'auth' });
  if (typeof checkoutId !== 'string' || !UUID.test(checkoutId)) return R(400, { error: 'checkout' });
  try {
    const c = await must(db, 'hdm_billing_checkout_lookup', { p_checkout: checkoutId }) as CheckoutInfo | null;
    if (!c || c.userId !== authUserId) return R(404, { error: 'checkout' });
    if (c.status !== 'pending' || c.expired) return R(409, { error: 'not_pending', status: c.status });
    if (String(c.processId ?? '').startsWith('grow-charge:')) return R(409, { error: 'in_progress' });

    assertGrowMoneyAllowed(env);   // לפני כל תפיסה — כשהסליקה כבויה שום דבר לא ננעל ולא נשלח
    const g = new GrowClient(env, fetchFn);

    if (c.kind === 'upgrade' && c.token) {
      const cd = (await must(db, 'hdm_billing_card_details', { p_profile: c.profileId }) ?? {}) as Record<string, string | null>;
      if (!cd.name || !cd.phone) return R(409, { error: 'payer_details_missing' });
      if (await must(db, 'hdm_billing_claim_checkout', { p_checkout: c.id, p_process_id: `grow-charge:${c.id}` }) !== true) {
        return R(409, { error: 'in_progress' });
      }
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
      const res = await must(db, 'hdm_billing_apply_grow_event', { p: event }) as Record<string, unknown>;
      return R(200, { mode: 'charged', result: res?.result ?? null });
    }

    const res = await g.createPaymentProcess(paymentProcessFields(env, c, notifyUrlFor(env, c.id)));
    const url = String(res.data.url ?? '');
    if (!/^https:\/\//.test(url)) throw new GrowError('NO_URL', 'Grow לא החזירה כתובת דף תשלום');
    if (res.data.processId) await db.rpc('hdm_billing_attach_process', { p_checkout: c.id, p_process_id: `grow-process:${res.data.processId}` });
    return R(200, { mode: 'redirect', url });
  } catch (e) {
    const code = e instanceof GrowError ? e.code : 'ERROR';
    console.error('grow-checkout', code, e instanceof Error ? e.message.slice(0, 300) : '');
    return R(code === 'GROW_OFF' || code === 'PRODUCTION_BLOCKED' ? 503 : 502, { error: code });
  }
}

// ---------------------------------------------------------------------
// grow-webhook: הודעת השרת של Grow. urlToken / ck מגיעים מכתובת ההודעה, body כבר פוענח (טופס/JSON)
// ---------------------------------------------------------------------
export async function webhookFlow(env: EnvFn, db: Db, fetchFn: FetchFn, urlToken: string, urlCk: string, body: Record<string, unknown>): Promise<Out> {
  const expected = env('GROW_WEBHOOK_TOKEN');
  if (!expected || expected.length < 32 || !safeEqual(urlToken, expected)) return R(401, { error: 'auth' });
  try {
    const note = flattenGrowForm(body);
    if (!note.transactionId || !note.transactionToken) return R(400, { error: 'fields' });
    const ckId = urlCk || note.cField1 || '';
    const ck = UUID.test(ckId) ? (await must(db, 'hdm_billing_checkout_lookup', { p_checkout: ckId }) as CheckoutInfo | null) : null;

    const g = new GrowClient(env, fetchFn);
    const info = await g.getTransactionInfo(note.transactionId, note.transactionToken);    // מקור האמת
    const v = verifyGrowPayment(note, info.data, ck);
    const res = await must(db, 'hdm_billing_apply_grow_event', { p: v.event }) as Record<string, unknown>;
    const result = String(res?.result ?? '');

    if ((result === 'started' || result === 'upgraded') && ck && v.card) {
      const { error } = await db.rpc('hdm_billing_save_grow_card', {
        p_profile: ck.profileId, p_token: v.card.token, p_last4: v.card.last4 ?? '', p_name: v.card.name ?? '',
        p_phone: v.card.phone ?? '', p_exp: v.card.exp ?? '',
      });
      if (error) console.warn('grow-webhook: card not saved', error.message);
    } else if (result === 'started' && !v.card) {
      console.warn('grow-webhook: no cardToken in update — renewals will not charge (Token permission?)');
    }
    try { await g.approveTransaction(note); } catch (e) { console.warn('grow-webhook: approve failed', e instanceof Error ? e.message.slice(0, 200) : ''); }
    return R(200, { ok: true, result });
  } catch (e) {
    const code = e instanceof GrowError ? e.code : 'ERROR';
    console.error('grow-webhook', code, e instanceof Error ? e.message.slice(0, 300) : '');
    return R(code === 'REJECTED' ? 400 : 500, { error: code });    // 5xx → Grow שולחת שוב
  }
}

// ---------------------------------------------------------------------
// grow-renewals: משימה מתוזמנת. cronHeader = הכותרת x-hdm-cron
// ---------------------------------------------------------------------
export async function renewalsFlow(env: EnvFn, db: Db, fetchFn: FetchFn, cronHeader: string): Promise<Out> {
  const secret = env('HDM_CRON_SECRET');
  if (!secret || secret.length < 32 || !safeEqual(cronHeader, secret)) return R(401, { error: 'auth' });
  if (env('DRY_RUN') === '1') return R(200, { dryRun: true });

  const summary: Record<string, unknown> = { cancelsConfirmed: 0, renewed: 0, failed: 0, review: 0, pending: 0 };
  const { data: nc } = await db.rpc('hdm_billing_grow_confirm_cancellations');
  summary.cancelsConfirmed = nc ?? 0;
  try { assertGrowMoneyAllowed(env); } catch (e) { summary.charges = e instanceof GrowError ? e.code : 'off'; return R(200, summary); }

  const { data, error } = await db.rpc('hdm_billing_claim_due_renewals', { p_limit: 25 });
  if (error) return R(500, { ...summary, error: 'claim' });
  const g = new GrowClient(env, fetchFn);
  const bump = (k: string) => { summary[k] = (summary[k] as number) + 1; };

  for (const c of (data ?? []) as Record<string, unknown>[]) {
    const chargeId = String(c.chargeId), amount = Number(c.amountAgorot), profile = String(c.profileId);
    const cd = ((await db.rpc('hdm_billing_card_details', { p_profile: profile })).data ?? {}) as Record<string, string | null>;
    const plan = await db.subscriptionPlan(profile);
    let event: Record<string, unknown>;
    if (!cd.token || !cd.name || !cd.phone) {
      event = { chargeId, transactionId: `grow-fail:${chargeId}:${c.attempt}`, outcome: 'failed', amountAgorot: amount,
                raw: { provider: 'grow', error: 'חסרים כרטיס שמור או שם/טלפון של המשלם' } };
    } else {
      try {
        const res = await g.createTransactionWithToken(await tokenChargeFields({
          token: cd.token, agorot: amount, name: cd.name, phone: cd.phone, key: `renewal:${chargeId}`,
          description: `חידוש מנוי ${PLAN_HE[String(plan)] ?? ''} חודשי - חיים דרך מספרים`.replace(/\s+/g, ' '),
          recurring: true, recurringDebitId: cd.recurringDebitId,
        }));
        const rid = String(res.data.recurringDebitId ?? '');
        if (rid && !cd.recurringDebitId) await db.rpc('hdm_billing_set_recurring_id', { p_profile: profile, p_id: rid });
        const tx = String(res.data.transactionId ?? '') || `renewal-${chargeId}`;
        event = { chargeId, transactionId: `grow:${tx}`, outcome: 'approved', amountAgorot: amount,
                  raw: { provider: 'grow', transactionId: tx, asmachta: res.data.asmachta ?? null } };
      } catch (e) {
        if (e instanceof GrowError && e.code === 'REJECTED') {
          event = { chargeId, transactionId: `grow-fail:${chargeId}:${c.attempt}`, outcome: 'failed', amountAgorot: amount,
                    raw: { provider: 'grow', error: e.message.slice(0, 300) } };
        } else {
          bump('pending');
          console.error('grow-renewals: no answer', chargeId, e instanceof Error ? e.message.slice(0, 200) : '');
          continue;
        }
      }
    }
    // לפי החיוב שנתפס (28) — עובד גם בחידוש הראשון, לפני ש-Grow נתנה מזהה סדרה
    const { data: res, error: e2 } = await db.rpc('hdm_billing_apply_card_renewal', { p: event });
    if (e2) { bump('review'); console.error('grow-renewals: apply failed', chargeId, e2.message); continue; }
    const r = String((res as Record<string, unknown>)?.result);
    bump(r === 'renewed' ? 'renewed' : r === 'failed' ? 'failed' : 'review');
  }
  return R(200, summary);
}

/** פענוח גוף ההודעה של Grow: טופס multipart, טופס רגיל או JSON. */
export async function readGrowBody(req: Request): Promise<Record<string, unknown>> {
  const ct = req.headers.get('content-type') ?? '';
  if (ct.includes('multipart/form-data')) {
    const o: Record<string, unknown> = {};
    for (const [k, v] of (await req.formData()).entries()) if (typeof v === 'string') o[k] = v;
    return o;
  }
  const text = await req.text();
  if (!text) return {};
  try { return JSON.parse(text); } catch { /* form-urlencoded */ }
  const o: Record<string, unknown> = {};
  for (const [k, v] of new URLSearchParams(text)) o[k] = v;
  return o;
}
