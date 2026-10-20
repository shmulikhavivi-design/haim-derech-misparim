// =====================================================================
// חיים דרך מספרים — grow-renewals: חידוש חודשי בכרטיס השמור + אישור ביטולים (Staging בלבד עד אישור)
//
// משימה מתוזמנת (פעם בשעה):
//   1. ביטולים: hdm_billing_grow_confirm_cancellations — במודל הזה Grow לא מחייבת לבד; ביטול מאושר כשהחידוש אצלנו כבוי.
//   2. חידושים: hdm_billing_claim_due_renewals (חיוב אחד לכל תקופה, גם בהרצה כפולה) → createTransactionWithToken →
//      hdm_billing_apply_grow_event. הארכה רק אחרי תשובה חיובית. מנוי שבוטל לא נתפס בכלל, ולכן לא מחויב.
//      בחיוב הראשון בכרטיס: isRecurringDebitPayment=1 ושמירת recurringDebitId; אחר כך שולחים אותו.
//   כרטיס נדחה = כישלון (עד 3 ניסיונות, 48 שעות ביניהם). אין תשובה = לא מנסים שוב (ייתכן שחויב) — לבדיקה ידנית.
//
// הפעלה: רק עם הכותרת x-hdm-cron = HDM_CRON_SECRET. חיובים כבויים עד GROW_LIVE=1. DRY_RUN=1 — בלי לתפוס ובלי לחייב.
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2';
import { GrowClient, GrowError, PLAN_HE, assertGrowMoneyAllowed, safeEqual, tokenChargeFields } from '../_shared/grow.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const admin = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
const out = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'content-type': 'application/json' } });

Deno.serve(async (req) => {
  const secret = env('HDM_CRON_SECRET');
  if (!secret || secret.length < 32 || !safeEqual(req.headers.get('x-hdm-cron') ?? '', secret)) return out({ error: 'auth' }, 401);
  if (env('DRY_RUN') === '1') return out({ dryRun: true });

  const summary: Record<string, unknown> = { cancelsConfirmed: 0, renewed: 0, failed: 0, review: 0, pending: 0 };
  const { data: nc } = await admin.rpc('hdm_billing_grow_confirm_cancellations');
  summary.cancelsConfirmed = nc ?? 0;

  try { assertGrowMoneyAllowed(env); } catch (e) { summary.charges = e instanceof GrowError ? e.code : 'off'; return out(summary); }

  const { data, error } = await admin.rpc('hdm_billing_claim_due_renewals', { p_limit: 25 });
  if (error) return out({ ...summary, error: 'claim' }, 500);
  const g = new GrowClient(env, fetch);

  for (const c of (data ?? []) as Record<string, unknown>[]) {
    const chargeId = String(c.chargeId), amount = Number(c.amountAgorot), profile = String(c.profileId);
    const { data: card } = await admin.rpc('hdm_billing_card_details', { p_profile: profile });
    const cd = (card ?? {}) as Record<string, string | null>;
    const { data: sub } = await admin.from('hdm_subscriptions').select('plan').eq('profile_id', profile).maybeSingle();
    let event: Record<string, unknown>;
    if (!cd.token || !cd.name || !cd.phone) {
      event = { chargeId, kind: 'renewal', transactionId: `grow-fail:${chargeId}:${c.attempt}`, outcome: 'failed', amountAgorot: amount,
                raw: { provider: 'grow', error: 'חסרים כרטיס שמור או שם/טלפון של המשלם' } };
    } else {
      try {
        const res = await g.createTransactionWithToken(await tokenChargeFields({
          token: cd.token, agorot: amount, name: cd.name, phone: cd.phone, key: `renewal:${chargeId}`,
          description: `חידוש מנוי ${PLAN_HE[String(sub?.plan)] ?? ''} חודשי - חיים דרך מספרים`.replace(/\s+/g, ' '),
          recurring: true, recurringDebitId: cd.recurringDebitId,
        }));
        const rid = String(res.data.recurringDebitId ?? '');
        if (rid && !cd.recurringDebitId) await admin.rpc('hdm_billing_set_recurring_id', { p_profile: profile, p_id: rid });
        const tx = String(res.data.transactionId ?? '') || `renewal-${chargeId}`;
        event = { chargeId, kind: 'renewal', transactionId: `grow:${tx}`, outcome: 'approved', amountAgorot: amount,
                  raw: { provider: 'grow', transactionId: tx, asmachta: res.data.asmachta ?? null } };
      } catch (e) {
        if (e instanceof GrowError && e.code === 'REJECTED') {
          event = { chargeId, kind: 'renewal', transactionId: `grow-fail:${chargeId}:${c.attempt}`, outcome: 'failed', amountAgorot: amount,
                    raw: { provider: 'grow', error: e.message.slice(0, 300) } };
        } else {
          (summary.pending as number)++;
          console.error('grow-renewals: no answer', chargeId, e instanceof Error ? e.message.slice(0, 200) : '');
          continue;
        }
      }
    }
    const { data: res, error: e2 } = await admin.rpc('hdm_billing_apply_grow_event', { p: event });
    if (e2) { (summary.review as number)++; console.error('grow-renewals: apply failed', chargeId, e2.message); continue; }
    const r = String((res as Record<string, unknown>)?.result);
    if (r === 'renewed') (summary.renewed as number)++; else if (r === 'failed') (summary.failed as number)++; else (summary.review as number)++;
  }
  return out(summary);
});
