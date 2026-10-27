// =====================================================================
// חיים דרך מספרים — hdm-target-mailer: שולח את התראות "קיבלת חץ 🎯" מהתור דרך Brevo (משימה מתוזמנת כל 5 דקות).
// פונקציה נפרדת מ-hdm-billing-worker — לא נוגעת בסליקה, במנויים או במיילי הביטול.
// מופעל רק עם הכותרת x-hdm-cron = HDM_CRON_SECRET (כמו שאר המשימות המתוזמנות).
// סודות (קיימים כבר): BREVO_API_KEY, MAIL_FROM, MAIL_REPLY_TO. חדש: TARGET_EMAILS_LIVE=1 להפעלה (בלעדיו — כבוי).
// חיבור ישיר אחד למסד (SUPABASE_DB_URL, מצב session) — כדי שנעילת המשתמש תוחזק לאורך כל המסירה ל-Brevo.
// =====================================================================
import postgres from 'npm:postgres@3.4.5';
import { safeEqual } from '../_shared/morning.ts';
import { sendTargetEmails, type Outcome, type QueueDb, type TargetMail } from '../_shared/target_mailer.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const out = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'content-type': 'application/json' } });
// נעילות session דורשות חיבור קבוע: אם הכתובת היא של ה-pooler במצב transaction (6543) — עוברים למצב session (5432)
const dbUrl = () => env('SUPABASE_DB_URL').replace(/:6543\//, ':5432/');

Deno.serve(async (req) => {
  const secret = env('HDM_CRON_SECRET');
  if (!secret || secret.length < 32 || !safeEqual(req.headers.get('x-hdm-cron') ?? '', secret)) return out({ error: 'auth' }, 401);
  if (env('TARGET_EMAILS_LIVE') !== '1') return out({ target: { skipped: 'off' } });   // כבוי — בלי חיבור למסד בכלל
  const sql = postgres(dbUrl(), { max: 1, prepare: false, idle_timeout: 5, connect_timeout: 15 });
  const conn = await sql.reserve();
  try {
    const db: QueueDb = {
      async claim(limit) { return (await conn`select id from public.hdm_target_email_claim(${limit})`).map((r) => Number(r.id)); },
      async withUserLock(id, fn) {
        const r = await conn`select user_id::text as u from public.hdm_target_email_outbox where id = ${id}`;
        if (!r.length) return await fn();                       // השורה נמחקה (חשבון נמחק) — begin יחזיר כלום
        const key = 'hdm_target_email:' + r[0].u;
        await conn`select pg_advisory_lock(hashtextextended(${key}, 0))`;
        try { return await fn(); }
        finally { await conn`select pg_advisory_unlock(hashtextextended(${key}, 0))`; }
      },
      async begin(id) {
        const r = await conn`select id, to_email, subject, body_text from public.hdm_target_email_begin(${id})`;
        return r.length ? ({ id: Number(r[0].id), kind: 'target_received', to_email: r[0].to_email, subject: r[0].subject, body_text: r[0].body_text } as TargetMail) : null;
      },
      async done(id, outcome: Outcome, error) { await conn`select public.hdm_target_email_done(${id}, ${outcome}, ${error})`; },
    };
    return out({ target: await sendTargetEmails(env, db, fetch) });
  } catch (e) {
    return out({ error: String(e).slice(0, 200) }, 500);
  } finally {
    conn.release(); await sql.end({ timeout: 5 });   // סגירת החיבור משחררת כל נעילה שנשארה
  }
});
