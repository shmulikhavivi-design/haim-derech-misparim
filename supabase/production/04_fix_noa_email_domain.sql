-- =====================================================================
-- חיים דרך מספרים — Production: תיקון סיומת האימייל של נועה (.con → .com). אושר על ידי הבעלים 16.10.2026 20:53.
--
-- מתקן רק את הכתובת של פרופיל reg_muv7ffi3345nmx, ורק בשלושה מקומות שהמערכת משתמשת בהם לכניסה ולקישור:
--   auth.users.email, auth.identities.identity_data.email (ספק email), public.hdm_legacy_accounts.email
-- לא נוצר ולא נמחק שום חשבון. מזהה המשתמש, הסיסמה, הפרופיל, השיחות, ההתאמות והמנוי לא משתנים.
-- הרשומה הישנה ב-data/users (שימשה רק בזמן המעבר) לא משתנה.
-- "הכול או כלום": כל בדיקה שנכשלת עוצרת בלי לשמור.
-- =====================================================================
begin;

do $$
declare
  pid  text := 'reg_muv7ffi3345nmx';
  bad  text;
  good text;
  uid  uuid;
  n    int;
begin
  select email into bad from public.hdm_legacy_accounts where profile_id = pid;
  if bad is null or bad !~ '\.con$' then
    raise exception 'עצירה: לפרופיל אין כתובת שמסתיימת ב-.con. שום דבר לא שונה.';
  end if;
  good := regexp_replace(bad, '\.con$', '.com');

  -- זה החשבון הנכון: משתמש Auth אחד בדיוק עם הכתובת השגויה
  select count(*) into n from auth.users where lower(email) = lower(bad);
  if n <> 1 then raise exception 'עצירה: נמצאו % משתמשי Auth עם הכתובת השגויה (צפוי 1). שום דבר לא שונה.', n; end if;
  select id into uid from auth.users where lower(email) = lower(bad);

  -- אין אף חשבון אחר עם הכתובת המתוקנת
  if exists (select 1 from auth.users where lower(email) = lower(good))
     or exists (select 1 from auth.identities where lower(identity_data->>'email') = lower(good))
     or exists (select 1 from public.hdm_legacy_accounts where lower(email) = lower(good)) then
    raise exception 'עצירה: הכתובת המתוקנת כבר בשימוש. שום דבר לא שונה.';
  end if;

  update auth.users
     set email = good,
         raw_user_meta_data = case when raw_user_meta_data ? 'email'
                                   then jsonb_set(raw_user_meta_data, '{email}', to_jsonb(good)) else raw_user_meta_data end,
         updated_at = now()
   where id = uid;

  update auth.identities
     set identity_data = jsonb_set(identity_data, '{email}', to_jsonb(good)), updated_at = now()
   where user_id = uid and provider = 'email' and lower(identity_data->>'email') = lower(bad);

  update public.hdm_legacy_accounts set email = lower(good) where profile_id = pid;

  -- אימות לפני שמירה
  if (select count(*) from auth.users) <> 4 then raise exception 'עצירה: מספר המשתמשים השתנה. שום דבר לא נשמר.'; end if;
  if exists (select 1 from auth.users where email ~ '\.con$')
     or exists (select 1 from auth.identities where identity_data->>'email' ~ '\.con$')
     or exists (select 1 from public.hdm_legacy_accounts where email ~ '\.con$') then
    raise exception 'עצירה: הכתובת השגויה עדיין קיימת. שום דבר לא נשמר.';
  end if;
  if (select count(*) from auth.users where id = uid and lower(email) = lower(good)) <> 1
     or (select count(*) from public.hdm_legacy_accounts l join auth.users u on lower(u.email) = l.email where l.profile_id = pid and u.id = uid) <> 1 then
    raise exception 'עצירה: הקישור בין המשתמש לפרופיל לא תקין אחרי התיקון. שום דבר לא נשמר.';
  end if;
  if not exists (select 1 from public.hdm_subscriptions where profile_id = pid and plan = 'plus' and status = 'active' and current_period_end is null) then
    raise exception 'עצירה: מנוי Plus של הפרופיל לא תקין. שום דבר לא נשמר.';
  end if;
end $$;

commit;
