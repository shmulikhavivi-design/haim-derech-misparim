-- =====================================================================
-- חיים דרך מספרים — Production: Plus בחינם וללא הגבלת זמן לאלון יפרח (alon72ifrach@gmail.com)
--
-- מה הקובץ עושה (הכול או כלום, בטרנזקציה אחת):
--   • מוודא שיש בדיוק חשבון אחד עם המייל, שהוא החשבון שאותר (af049f7f…) ושהוא מקושר לפרופיל reg_mvsgolyrptxuqg "אלון יפרח"
--   • נעצר בלי לשנות כלום אם יש לו מנוי בתשלום, הוראת קבע, כרטיס שמור, תשלום, ניסיון תשלום פתוח או חיוב חידוש
--   • מוסיף מנוי Plus: מקור manual (לא payment), בלי תאריך תפוגה, בלי חידוש אוטומטי, בלי הוראת קבע ב-Grow
--   • רושם אירוע אחד ביומן המנויים
-- מה הוא לא עושה: לא נוגע בשום משתמש אחר, בתשלומים, במחירים, בטבלת המסלולים, ב-Grow/Morning או בהגדרות.
-- הרצה חוזרת: לא משנה כלום ("כבר קיים").
-- =====================================================================
begin;
do $$
declare
  v_email constant text := 'alon72ifrach@gmail.com';
  v_uid   constant uuid := 'af049f7f-0026-410a-9941-cf5d592c902c';
  v_pid   constant text := 'reg_mvsgolyrptxuqg';
  v_note  constant text := 'Plus בחינם ללא הגבלת זמן — באישור הבעלים (29.10.2026). בלי חיוב ובלי חידוש.';
  n int; cur text; s public.hdm_subscriptions%rowtype;
begin
  if to_regclass('public.hdm_staging_marker') is not null then
    raise exception 'עצירה: זה מסד Staging. שום דבר לא שונה.';
  end if;

  -- 1. החשבון הנכון
  select count(*) into n from auth.users where lower(email) = v_email;
  if n <> 1 then raise exception 'עצירה: נמצאו % חשבונות עם המייל. שום דבר לא שונה.', n; end if;
  if not exists (select 1 from auth.users where id = v_uid and lower(email) = v_email and deleted_at is null) then
    raise exception 'עצירה: החשבון עם המייל אינו החשבון שאותר. שום דבר לא שונה.';
  end if;
  if (select profile_id from public.hdm_accounts where auth_user_id = v_uid) is distinct from v_pid then
    raise exception 'עצירה: החשבון לא מקושר לפרופיל שאותר. שום דבר לא שונה.';
  end if;
  if not exists (select 1 from public.docs where collection = 'profiles' and id = v_pid
                   and coalesce(data->>'currentName', '') = 'אלון יפרח') then
    raise exception 'עצירה: הפרופיל לא נמצא או שהשם השתנה. שום דבר לא שונה.';
  end if;

  perform pg_advisory_xact_lock(hashtext('hdm_billing:' || v_pid));

  -- 2. אין שום דבר בתשלום
  select * into s from public.hdm_subscriptions where profile_id = v_pid for update;
  if s.profile_id is not null and (s.source = 'payment' or s.auto_renew or s.grow_direct_debit_id is not null) then
    raise exception 'עצירה: יש לו מנוי בתשלום / חידוש אוטומטי. שום דבר לא שונה.';
  end if;
  if exists (select 1 from public.hdm_billing_tokens   where profile_id = v_pid)
  or exists (select 1 from public.hdm_payments         where profile_id = v_pid)
  or exists (select 1 from public.hdm_renewal_charges  where profile_id = v_pid)
  or exists (select 1 from public.hdm_checkouts        where profile_id = v_pid and status = 'pending') then
    raise exception 'עצירה: נמצא כרטיס שמור / תשלום / חיוב / ניסיון תשלום פתוח. שום דבר לא שונה.';
  end if;

  -- הרצה חוזרת
  if s.profile_id is not null and s.plan = 'plus' and s.status = 'active' and s.source = 'manual'
     and s.current_period_end is null and not s.auto_renew then
    raise notice 'כבר קיים: אלון יפרח ב-Plus ללא הגבלת זמן. לא שונה כלום.';
    return;
  end if;

  -- 3. הענקת Plus
  cur := public.hdm_plan_of(v_pid);
  insert into public.hdm_subscriptions as x
    (profile_id, plan, status, period_anchor, current_period_end, canceled_at, source, note, auto_renew, grow_direct_debit_id, failed_attempts, last_payment_at)
  values (v_pid, 'plus', 'active', now(), null, null, 'manual', v_note, false, null, 0, null)
  on conflict (profile_id) do update set
    plan = 'plus', status = 'active', period_anchor = now(), current_period_end = null, canceled_at = null,
    source = 'manual', note = excluded.note, auto_renew = false, grow_direct_debit_id = null,
    failed_attempts = 0, updated_at = now();
  insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan, note)
  values (v_pid, case when cur = 'free' then 'start' else 'upgrade' end, cur, 'plus', v_note);
end $$;
commit;

-- אימות (קריאה בלבד): מה האפליקציה תחזיר לאלון
select public.hdm_plan_of('reg_mvsgolyrptxuqg') as "מסלול",
       (select current_period_end is null from public.hdm_subscriptions where profile_id = 'reg_mvsgolyrptxuqg') as "ללא תפוגה",
       (select not auto_renew and source = 'manual' from public.hdm_subscriptions where profile_id = 'reg_mvsgolyrptxuqg') as "ללא חיוב",
       (select count(*) from public.hdm_checkouts where profile_id = 'reg_mvsgolyrptxuqg')
     + (select count(*) from public.hdm_payments where profile_id = 'reg_mvsgolyrptxuqg') as "תשלומים";
