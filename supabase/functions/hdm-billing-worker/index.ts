// =====================================================================
// חיים דרך מספרים — hdm-billing-worker: שולח את מיילי ביטול המנוי מהתור דרך Brevo (משימה מתוזמנת כל 5 דקות).
// מופעל רק עם הכותרת x-hdm-cron = HDM_CRON_SECRET (כמו משימת החידוש). לא מחייב ולא נוגע בתשלומים.
// סודות: BREVO_API_KEY, MAIL_FROM (noreply@ על דומיין מאומת ב-Brevo — לא כתובת Gmail, ראו docs/email-sender-domain.md), MAIL_REPLY_TO (לא חובה). DRY_RUN=1 — לא שולח.
// ביטול מנוי לא דורש פעולה מול Grow: החיובים נעשים מהשרת בכרטיס השמור, וביטול = החידוש כבוי (auto_renew).
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2';
import { safeEqual } from '../_shared/morning.ts';
import { sendQueuedEmails, type Rpc } from '../_shared/email_worker.ts';

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
    return out({ email: await sendQueuedEmails(env, rpc, fetch) });
  } catch (e) {
    return out({ error: String(e).slice(0, 200) }, 500);
  }
});
