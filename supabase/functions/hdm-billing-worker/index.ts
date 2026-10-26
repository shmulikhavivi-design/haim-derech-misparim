// =====================================================================
// חיים דרך מספרים — hdm-billing-worker: שולח את מיילי ביטול המנוי מהתור דרך Brevo (משימה מתוזמנת כל 5 דקות).
// מופעל רק עם הכותרת x-hdm-cron = HDM_CRON_SECRET (כמו משימת החידוש).
// 26.10: בנוסף משלים הצטרפויות שבהן הלקוח שמר כרטיס אצל Grow וסגר את הדף (sweepCardCheckouts) — תפיסה אטומית, חיוב אחד לכל ניסיון.
// כבוי כשהסליקה כבויה (MORNING_LIVE) או DRY_RUN=1.
// סודות: BREVO_API_KEY, MAIL_FROM (שולח מאומת ב-Brevo), MAIL_REPLY_TO (לא חובה). DRY_RUN=1 — לא שולח.
// ביטול מנוי לא דורש פעולה מול Grow: החיובים נעשים מהשרת בכרטיס השמור, וביטול = החידוש כבוי (auto_renew).
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2';
import { MorningClient, MorningError, safeEqual } from '../_shared/morning.ts';
import { sweepCardCheckouts } from '../_shared/card_flow.ts';
import { makeFlowDb, pendingCheckouts } from '../_shared/flow_db.ts';
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
  // השלמת הצטרפויות (לא תלוי במיילים — תקלה באחד לא עוצרת את השני)
  let cards: unknown = null;
  if (env('DRY_RUN') === '1') cards = { skipped: 'dry_run' };
  else {
    try {
      const list = await pendingCheckouts(sb);
      cards = list.length ? await sweepCardCheckouts(list, new MorningClient(env, fetch), env, makeFlowDb(sb, 'hdm-billing-worker')) : { none: true };
    } catch (e) { cards = { skipped: e instanceof MorningError ? e.code : 'error' }; if (!(e instanceof MorningError)) console.error('sweep', String(e).slice(0, 200)); }
  }
  try {
    return out({ email: await sendQueuedEmails(env, rpc, fetch), cards });
  } catch (e) {
    return out({ error: String(e).slice(0, 200), cards }, 500);
  }
});
