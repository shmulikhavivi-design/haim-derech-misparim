-- =====================================================================
-- חיים דרך מספרים — Staging בלבד: תיקון מזהי פרופיל (קו תחתון בתחילה/בסוף)
-- להרצה פעם אחת, אחרי 01 ו-03, רק בפרויקט Haim Derech Misparim Staging
-- ⚠️ לפני ההרצה: בשורת הכתובת צריך להופיע ousepgdvzammgkxkweze
--
-- הבעיה: מזהה כמו "abc_" יוצר מזהה שיחה "abc___def", שהשרת מפרש כשיחה של "abc".
-- התיקון: מזהה פרופיל לא יכול להתחיל או להסתיים בקו תחתון.
-- לא נוגע בשום נתון. "הכול או כלום".
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא שונה.';
  end if;
  if not exists (select 1 from public.hdm_staging_marker where version = 'staging_secure_v1_fixes') then
    raise exception 'עצירה: צריך להריץ קודם את 03_staging_fixes.sql. שום דבר לא שונה.';
  end if;
  if exists (select 1 from public.hdm_staging_marker where version = 'staging_secure_v1_fixes2') then
    raise exception 'עצירה: התיקון כבר הותקן. שום דבר לא שונה.';
  end if;
  if exists (select 1 from public.hdm_accounts where profile_id like '\_%' or profile_id like '%\_') then
    raise exception 'עצירה: קיים פרופיל עם קו תחתון בתחילה או בסוף. שלחו צילום מסך. שום דבר לא שונה.';
  end if;
end $$;

-- כלל חדש לטבלת החשבונות
do $$
declare c text;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.hdm_accounts'::regclass and contype = 'c' loop
    execute format('alter table public.hdm_accounts drop constraint %I', c);
  end loop;
end $$;
alter table public.hdm_accounts add constraint hdm_accounts_profile_id_check
  check (profile_id ~ '^[A-Za-z0-9-][A-Za-z0-9_-]{1,62}[A-Za-z0-9-]$' and position('__' in profile_id) = 0);

-- אותה פונקציה, רק עם הכלל החדש
create or replace function public.hdm_claim_profile(p_proposed text default null)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  v   text;
begin
  if uid is null then
    raise exception 'HDM_NOT_SIGNED_IN' using errcode = 'P0001', hint = 'נדרשת התחברות.';
  end if;
  select profile_id into v from public.hdm_accounts where auth_user_id = uid;
  if v is not null then return v; end if;
  if p_proposed is not null then
    if p_proposed !~ '^[A-Za-z0-9-][A-Za-z0-9_-]{1,62}[A-Za-z0-9-]$' or position('__' in p_proposed) > 0
       or exists (select 1 from public.hdm_accounts where profile_id = p_proposed)
       or exists (select 1 from public.docs where collection = 'profiles' and id = p_proposed)
       or exists (select 1 from public.hdm_profile_private where profile_id = p_proposed) then
      raise exception 'HDM_PROFILE_ID_TAKEN' using errcode = 'P0001', hint = 'מזהה הפרופיל אינו זמין.';
    end if;
    v := p_proposed;
  else
    v := 'p_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 20);
  end if;
  insert into public.hdm_accounts (auth_user_id, profile_id) values (uid, v);
  return v;
end $$;
revoke all on function public.hdm_claim_profile(text) from public, anon;
grant execute on function public.hdm_claim_profile(text) to authenticated;

insert into public.hdm_staging_marker (version, note)
values ('staging_secure_v1_fixes2', 'תיקון מזהי פרופיל: בלי קו תחתון בתחילה או בסוף');

commit;

select '✅ תיקון מזהי הפרופיל הותקן' as "סטטוס",
       (select string_agg(version, ' · ' order by installed_at) from public.hdm_staging_marker) as "מה מותקן",
       (select count(*) from pg_policies where schemaname = 'public') as "כללי RLS";
