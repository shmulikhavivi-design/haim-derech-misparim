-- =====================================================================
-- חיים דרך מספרים — משימת חידוש המנויים החודשית (פעם בשעה, דקה 17).
-- קוראת לפונקציה morning-renewals עם הסוד מ-Vault (hdm_cron_secret). הפונקציה מחייבת רק מנוי בתשלום
-- שהגיע מועד החידוש שלו, החידוש לא בוטל, ויש כרטיס שמור. ביטול מנוי = auto_renew כבוי = לא נתפס.
-- כל עוד DRY_RUN=1 בפונקציה — המשימה רצה ולא מחייבת. "הכול או כלום". הרצה חוזרת מחליפה את המשימה הקיימת באותו שם.
-- =====================================================================
begin;
create extension if not exists pg_cron;
create extension if not exists pg_net;
do $$ begin
  if not exists (select 1 from public.hdm_release_marker where version = 'production_billing_v1') then
    raise exception 'עצירה: קודם 08. שום דבר לא שונה.'; end if;
  if not exists (select 1 from vault.decrypted_secrets where name = 'hdm_cron_secret' and length(decrypted_secret) >= 32) then
    raise exception 'עצירה: חסר hdm_cron_secret ב-Vault. שום דבר לא שונה.'; end if;
end $$;
select cron.unschedule(jobid) from cron.job where jobname = 'hdm-morning-renewals';
select cron.schedule('hdm-morning-renewals', '17 * * * *', $job$
  select net.http_post(
    url := 'https://qtspzigjlbtckqfyaubp.supabase.co/functions/v1/morning-renewals',
    headers := jsonb_build_object('content-type', 'application/json',
                 'x-hdm-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'hdm_cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
$job$);
do $$ begin
  if (select count(*) from cron.job where jobname = 'hdm-morning-renewals' and active) <> 1 then raise exception 'עצירה: המשימה לא נוצרה.'; end if;
end $$;
commit;
