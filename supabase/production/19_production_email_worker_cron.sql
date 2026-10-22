-- =====================================================================
-- חיים דרך מספרים — משימה מתוזמנת לשליחת מיילי ביטול המנוי (כל 5 דקות) דרך הפונקציה hdm-billing-worker.
-- להתקין רק אחרי: (1) הפונקציה פרוסה, (2) BREVO_API_KEY ו-MAIL_FROM מוגדרים בסודות הפונקציות, (3) אישור מפורש של הבעלים.
-- משתמש באותו סוד מ-Vault כמו משימת החידוש (hdm_cron_secret). לא מחייב ולא נוגע בתשלומים. "הכול או כלום".
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.hdm_staging_marker') is not null then raise exception 'עצירה: זה לא Production. שום דבר לא שונה.'; end if;
  if not exists (select 1 from public.hdm_release_marker where version = 'production_billing_v1') then raise exception 'עצירה: קודם 08. שום דבר לא שונה.'; end if;
  if to_regclass('cron.job') is null then raise exception 'עצירה: pg_cron לא מותקן. שום דבר לא שונה.'; end if;
  if not exists (select 1 from vault.decrypted_secrets where name = 'hdm_cron_secret' and length(decrypted_secret) >= 32) then
    raise exception 'עצירה: חסר hdm_cron_secret ב-Vault. שום דבר לא שונה.'; end if;
end $$;
select cron.unschedule(jobid) from cron.job where jobname = 'hdm-billing-worker';
select cron.schedule('hdm-billing-worker', '*/5 * * * *', $job$
  select net.http_post(
    url := 'https://qtspzigjlbtckqfyaubp.supabase.co/functions/v1/hdm-billing-worker',
    headers := jsonb_build_object('content-type', 'application/json',
                 'x-hdm-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'hdm_cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
$job$);
do $$ begin
  if (select count(*) from cron.job where jobname = 'hdm-billing-worker' and active) <> 1 then raise exception 'עצירה: המשימה לא נוצרה.'; end if;
end $$;
insert into public.hdm_release_marker (version, note) values ('production_email_worker_cron', 'שליחת מיילי ביטול דרך Brevo כל 5 דקות');
commit;
