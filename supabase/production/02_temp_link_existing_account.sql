-- =====================================================================
-- חיים דרך מספרים — פתרון זמני כל עוד שליחת מיילים (SMTP) לא עובדת
--
-- מחבר חשבון קיים (מהגרסה הקודמת) לפרופיל שלו, וקובע לו סיסמה זמנית — בלי מייל.
-- רק לאנשים שזהותם ידועה לכם אישית (שמוליק, לימור, נועה, דני). לא לבקשות מאנשים לא מוכרים.
-- מריצים ב-Production ← SQL Editor, אחרי 01_production_migration.sql, פעם אחת לכל אדם.
--
-- מחליפים רק את שתי השורות המסומנות ⬅️. הסיסמה נקלדת כאן בלבד — לא בצ'אט ולא ב-GitHub.
-- את הסיסמה הזמנית מוסרים לאדם עצמו; אחרי שה-SMTP יעבוד הוא יכול לבחור חדשה דרך "שכחתי סיסמה".
-- בטוח להרצה חוזרת: אם החשבון כבר מחובר — נעצר בלי לשנות כלום. הכול בטרנזקציה אחת.
-- =====================================================================
do $$
declare
  e   text := lower(btrim('EMAIL_HERE'));          -- ⬅️ האימייל של החשבון הקיים
  pw  text := 'TEMP_PASSWORD_HERE';                -- ⬅️ סיסמה זמנית (לפחות 10 תווים)
  uid uuid; pid text; cr text;
begin
  if position('email' || '_here' in e) > 0 or position('PASSWORD' || '_HERE' in pw) > 0 then raise exception 'יש להחליף את האימייל ואת הסיסמה הזמנית.'; end if;
  if length(pw) < 10 then raise exception 'הסיסמה הזמנית קצרה מדי (לפחות 10 תווים).'; end if;
  select l.profile_id into pid from public.hdm_legacy_accounts l where l.email = e;
  if pid is null then raise exception 'האימייל לא נמצא בחשבונות הקיימים (hdm_legacy_accounts). לא שונה כלום.'; end if;
  select id into uid from auth.users where lower(email) = e;
  if uid is null then raise exception 'לא נמצא משתמש התחברות לאימייל הזה. לא שונה כלום.'; end if;
  if exists (select 1 from public.hdm_accounts where auth_user_id = uid or profile_id = pid) then
    raise exception 'החשבון כבר מחובר לפרופיל. לא שונה כלום.';
  end if;
  insert into public.hdm_accounts (auth_user_id, profile_id) values (uid, pid);
  update public.hdm_legacy_accounts set linked_at = now() where profile_id = pid;
  cr := case when exists (select 1 from pg_proc where proname = 'crypt' and pronamespace = to_regnamespace('extensions')) then 'extensions.' else 'public.' end;
  execute format('update auth.users set encrypted_password = %scrypt($1, %sgen_salt(''bf'')), updated_at = now() where id = $2', cr, cr) using pw, uid;
  raise notice '✅ החשבון % מחובר לפרופיל %. אפשר להיכנס עם הסיסמה הזמנית.', e, pid;
end $$;
