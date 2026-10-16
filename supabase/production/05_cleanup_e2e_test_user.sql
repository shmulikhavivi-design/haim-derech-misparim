-- מחיקת חשבון בדיקה שנשאר מבדיקת הקצה (16.10, 18:21 UTC): משתמש Auth לא מאומת, בלי פרופיל, בכתובת זמנית hdmtest…@maxxspace.com.
-- לא נוגע בשום משתמש אחר. "הכול או כלום".
begin;
do $$
declare n int;
begin
  select count(*) into n from auth.users
   where email like 'hdmtest%@maxxspace.com' and email_confirmed_at is null
     and created_at between '2026-10-16 18:20:00+00' and '2026-10-16 18:23:00+00';
  if n <> 1 then raise exception 'עצירה: נמצאו % חשבונות בדיקה מתאימים (צפוי 1). שום דבר לא שונה.', n; end if;
  if exists (select 1 from auth.users u join public.hdm_legacy_accounts l on l.email = lower(u.email) where u.email like 'hdmtest%')
     or exists (select 1 from public.docs where collection = 'profiles' and data->>'currentName' = 'בדיקת מערכת') then
    raise exception 'עצירה: לחשבון הבדיקה יש פרופיל או קישור. שום דבר לא שונה.';
  end if;
  delete from auth.users
   where email like 'hdmtest%@maxxspace.com' and email_confirmed_at is null
     and created_at between '2026-10-16 18:20:00+00' and '2026-10-16 18:23:00+00';
  if (select count(*) from auth.users) <> 4 then raise exception 'עצירה: מספר המשתמשים אחרי הניקוי אינו 4. שום דבר לא נשמר.'; end if;
end $$;
commit;
