// =====================================================================
// חיים דרך מספרים — morning-renewals: חידוש חודשי בכרטיס השמור (Staging בלבד עד אישור)
//
// משימה מתוזמנת (פעם בשעה). לכל מנוי שהגיע מועד החידוש שלו ושלא בוטל:
//   hdm_billing_claim_due_renewals (חיוב אחד לכל תקופה, גם בהרצה כפולה) → חיוב הכרטיס השמור ב-Morning →
//   hdm_billing_apply_morning_renewal. ההארכה רק אחרי תשובה חיובית מ-Morning.
// ביטול חידוש = auto_renew כבוי → המנוי לא נתפס כאן בכלל, ולכן לא מחויב. אין "הוראת קבע" שצריך לבטל אצל הספק.
// תשובה עסקית שלילית (כרטיס נדחה) = כישלון; עד 3 ניסיונות, 48 שעות ביניהם.
// תקלת רשת / אין תשובה = לא מנסים שוב אוטומטית (ייתכן שחויב); המסד מסמן לבדיקה ידנית אחרי שעתיים.
//
// הפעלה: רק עם הכותרת x-hdm-cron = HDM_CRON_SECRET. כבוי עד MORNING_LIVE=1. DRY_RUN=1 — בלי לתפוס ובלי לחייב.
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2';
import { MorningClient, MorningError, PLAN_HE, assertMoneyAllowed, safeEqual, toAgorot, tokenChargeBody } from '../_shared/morning.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const admin = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
const out = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'content-type': 'application/json' } });

Deno.serve(async (req) => {
  const secret = env('HDM_CRON_SECRET');
  if (!secret || secret.length < 32 || !safeEqual(req.headers.get('x-hdm-cron') ?? '', secret)) return out({ error: 'auth' }, 401);
  if (env('DRY_RUN') === '1') return out({ dryRun: true });
  try { assertMoneyAllowed(env); } catch (e) { return out({ skipped: e instanceof MorningError ? e.code : 'off' }); }

  const { data, error } = await admin.rpc('hdm_billing_claim_due_renewals', { p_limit: 25 });
  if (error) return out({ error: 'claim' }, 500);
  const m = new MorningClient(env, fetch);
  const summary = { renewed: 0, failed: 0, review: 0, pending: 0 };

  for (const c of (data ?? []) as Record<string, unknown>[]) {
    const chargeId = String(c.chargeId), amount = Number(c.amountAgorot);
    const { data: plan } = await admin.from('hdm_subscriptions').select('plan').eq('profile_id', c.profileId).maybeSingle();
    const desc = `חידוש מנוי ${PLAN_HE[String(plan?.plan)] ?? ''} חודשי — חיים דרך מספרים`.replace(/\s+/g, ' ');
    let event: Record<string, unknown>;
    try {
      const doc = await m.chargeToken(String(c.token), tokenChargeBody(desc, amount)) as Record<string, unknown>;
      const ref = String(doc.id ?? doc.transactionId ?? '') || `renewal-${chargeId}`;
      const amt = toAgorot(doc.amount ?? NaN);
      event = { chargeId, transactionId: `morning:${ref}`, outcome: 'approved', amountAgorot: Number.isFinite(amt) ? amt : amount,
                raw: { provider: 'morning', documentId: doc.id ?? null, transactionId: doc.transactionId ?? null } };
    } catch (e) {
      if (e instanceof MorningError && e.code === 'REJECTED') {
        event = { chargeId, transactionId: `morning-fail:${chargeId}:${c.attempt}`, outcome: 'failed', amountAgorot: amount,
                  raw: { provider: 'morning', status: e.status, error: e.message.slice(0, 300) } };
      } else {
        summary.pending++;           // לא יודעים אם חויב — נשאר "בתהליך", המסד יסמן לבדיקה
        console.error('morning-renewals: no answer', chargeId, e instanceof Error ? e.message.slice(0, 200) : '');
        continue;
      }
    }
    const { data: res, error: e2 } = await admin.rpc('hdm_billing_apply_morning_renewal', { p: event });
    if (e2) { summary.review++; console.error('morning-renewals: apply failed', chargeId, e2.message); continue; }
    const r = String((res as Record<string, unknown>)?.result);
    if (r === 'renewed') summary.renewed++; else if (r === 'failed') summary.failed++; else summary.review++;
  }
  return out(summary);
});
