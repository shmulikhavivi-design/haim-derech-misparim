// =====================================================================
// חיים דרך מספרים — hdm-target-mailer: שולח את התראות "קיבלת חץ 🎯" מהתור דרך Brevo (משימה מתוזמנת כל 5 דקות).
// פונקציה נפרדת מ-hdm-billing-worker — לא נוגעת בסליקה, במנויים או במיילי הביטול.
// מופעל רק עם הכותרת x-hdm-cron = HDM_CRON_SECRET (כמו שאר המשימות המתוזמנות).
// סודות (קיימים כבר): BREVO_API_KEY, MAIL_FROM, MAIL_REPLY_TO. חדש: TARGET_EMAILS_LIVE=1 להפעלה (בלעדיו — כבוי).
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2';
import { safeEqual } from '../_shared/morning.ts';
import { type Rpc } from '../_shared/email_worker.ts';
import { sendTargetEmails } from '../_shared/target_mailer.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const sb = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
const out = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'content-type': 'application/json' } });

Deno.serve(async (req) => {
  const secret = env('HDM_CRON_SECRET');
  if (!secret || secret.length < 32 || !safeEqual(req.headers.get('x-hdm-cron') ?? '', secret)) return out({ error: 'auth' }, 401);
  const rpc: Rpc = async (fn, args) => {
    const { data, error } = await sb.rpc(fn, args);
    return { data, error: error ? { message: error.message } : null };
  };
  try {
    return out({ target: await sendTargetEmails(env, rpc, fetch) });
  } catch (e) {
    return out({ error: String(e).slice(0, 200) }, 500);
  }
});
