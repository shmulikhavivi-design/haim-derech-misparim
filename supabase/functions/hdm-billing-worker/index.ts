// =====================================================================
// חיים דרך מספרים — משימת רקע לביטולי מנוי (טיוטה; לא פרוסה ולא הורצה)
//
// 1. מיילים: שולחת את מיילי הביטול מהתור (hdm_email_outbox_pending) דרך ה-API של Brevo,
//    ומסמנת כל מייל כנשלח / נכשל (hdm_email_outbox_done). מייל שנכשל נשאר בתור (עד 5 ניסיונות).
// 2. Grow: ביטול סדרת חיובים (hdm_billing_outbox_pending → Grow → hdm_billing_outbox_done).
//    כבוי עד שתתקבל הרשאה ותיעוד מ-Grow (GROW_LIVE=1). כשהוא כבוי — לא נוגעים בתור בכלל,
//    כדי שבקשות לא יסומנו ככושלות. הביטול מסומן "אושר" רק אחרי תשובה חיובית מ-Grow.
//
// סודות (Supabase Function Secrets, לא בקוד): SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY,
//   BREVO_API_KEY, MAIL_FROM (כתובת שולח מאומתת ב-Brevo). Grow: GROW_LIVE + פרטי API (בהמשך).
// הפעלה: משימה מתוזמנת כל כמה דקות. DRY_RUN=1 — מדפיס בלי לשלוח ובלי לסמן.
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2';

const env = (k: string) => Deno.env.get(k) ?? '';
const sb = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
const DRY = env('DRY_RUN') === '1';

async function sendEmails() {
  const { data, error } = await sb.rpc('hdm_email_outbox_pending', { p_limit: 20 });
  if (error) throw error;
  let sent = 0, failed = 0;
  for (const m of data ?? []) {
    if (DRY) { console.log('DRY email', m.id, m.kind); continue; }
    let ok = false, err = '';
    try {
      const r = await fetch('https://api.brevo.com/v3/smtp/email', {
        method: 'POST',
        headers: { 'api-key': env('BREVO_API_KEY'), 'content-type': 'application/json', accept: 'application/json' },
        body: JSON.stringify({
          sender: { name: 'חיים דרך מספרים', email: env('MAIL_FROM') },
          to: [{ email: m.to_email }],
          subject: m.subject,
          textContent: m.body_text,
        }),
      });
      ok = r.ok; if (!ok) err = `brevo ${r.status}`;
    } catch (e) { err = String(e).slice(0, 200); }
    await sb.rpc('hdm_email_outbox_done', { p_id: m.id, p_ok: ok, p_error: ok ? null : err });
    ok ? sent++ : failed++;
  }
  return { sent, failed };
}

async function cancelAtGrow() {
  if (env('GROW_LIVE') !== '1') return { skipped: 'GROW_LIVE off — ממתין לאישור Grow' };
  // TODO אחרי אישור Grow: קריאה ל-API של Grow לביטול הסדרה (recurringDebitId / directDebitId),
  // ואז hdm_billing_outbox_done(id, true) רק אם Grow החזירה הצלחה; אחרת (id, false, שגיאה).
  throw new Error('Grow cancel API not implemented yet');
}

Deno.serve(async () => {
  const out: Record<string, unknown> = {};
  try { out.grow = await cancelAtGrow(); } catch (e) { out.grow = { error: String(e).slice(0, 200) }; }
  try { out.email = await sendEmails(); } catch (e) { out.email = { error: String(e).slice(0, 200) }; }
  return new Response(JSON.stringify(out), { headers: { 'content-type': 'application/json' } });
});
