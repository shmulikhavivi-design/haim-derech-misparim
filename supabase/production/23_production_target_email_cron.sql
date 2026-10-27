-- =====================================================================
-- חיים דרך מספרים — משימה מתוזמנת לשליחת התראות "קיבלת חץ 🎯" (כל 5 דקות) דרך הפונקציה hdm-target-mailer.
-- ⚠️ לא להריץ בלי אישור מפורש של הבעלים. סדר ההפעלה ב-Production (כל שלב באישור):
--   1. supabase/staging_secure/49_staging_target_email.sql (אותו קובץ בדיוק) — מתחיל לאסוף התראות לתור. שום מייל לא נשלח עדיין.
--   2. פריסת הפונקציה hdm-target-mailer. היא כבויה עד שמוגדר הסוד TARGET_EMAILS_LIVE=1.
--      משתמשת בסודות הקיימים BREVO_API_KEY / MAIL_FROM / MAIL_REPLY_TO — אין שינוי בהגדרות SMTP.
--   3. הקובץ הזה (המשימה המתוזמנת), ואז TARGET_EMAILS_LIVE=1.
-- משתמש באותו סוד מ-Vault כמו שאר המשימות (hdm_cron_secret). לא נוגע בסליקה, במנויים או במיילי הביטול. "הכול או כלום".
-- כיבוי מיידי בכל עת: TARGET_EMAILS_LIVE=0 (או: select cron.unschedule('hdm-target-mailer');)
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.hdm_staging_marker') is not null then raise exception 'עצירה: זה לא Production. שום דבר לא שונה.'; end if;
  if not exists (select 1 from public.hdm_release_marker where version = 'target_email_v1') then raise exception 'עצירה: קודם 49 (התראת מייל על 🎯). שום דבר לא שונה.'; end if;
  if to_regclass('cron.job') is null then raise exception 'עצירה: pg_cron לא מותקן. שום דבר לא שונה.'; end if;
  if not exists (select 1 from vault.decrypted_secrets where name = 'hdm_cron_secret' and length(decrypted_secret) >= 32) then
    raise exception 'עצירה: חסר hdm_cron_secret ב-Vault. שום דבר לא שונה.'; end if;
end $$;
select cron.unschedule(jobid) from cron.job where jobname = 'hdm-target-mailer';
select cron.schedule('hdm-target-mailer', '*/5 * * * *', $job$
  select net.http_post(
    url := 'https://qtspzigjlbtckqfyaubp.supabase.co/functions/v1/hdm-target-mailer',
    headers := jsonb_build_object('content-type', 'application/json',
                 'x-hdm-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'hdm_cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
$job$);
do $$ begin
  if (select count(*) from cron.job where jobname = 'hdm-target-mailer' and active) <> 1 then raise exception 'עצירה: המשימה לא נוצרה.'; end if;
  if (select count(*) from cron.job where jobname = 'hdm-billing-worker' and active) <> 1 then raise exception 'עצירה: משימת מיילי הביטול לא במצב הצפוי.'; end if;
end $$;
insert into public.hdm_release_marker (version, note) values ('target_email_cron_v1', 'שליחת התראות 🎯 דרך Brevo כל 5 דקות');
commit;
