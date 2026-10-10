-- =====================================================================
-- חיים דרך מספרים — שלב 0: בדיקת מצב האבטחה (קריאה בלבד)
-- להרצה ב-Supabase: SQL Editor ← New query ← להדביק ← Run
--
-- השאילתה רק קוראת. היא לא יוצרת, לא משנה ולא מוחקת שום דבר.
-- היא לא מציגה תוכן אישי: אין אימיילים, שמות, תאריכי לידה, הודעות או סיסמאות —
-- רק הגדרות של המסד ומספרים מסכמים.
-- התוצאה: טבלה אחת עם שלוש עמודות (סעיף, פריט, ערך). אפשר לצלם מסך או ללחוץ Export → CSV.
-- =====================================================================

with
-- 1. טבלאות בסכמה public: האם RLS פעיל, וכמה שורות
t as (
  select c.relname as name, c.relrowsecurity as rls, c.relforcerowsecurity as rls_forced, c.reltuples::bigint as approx_rows
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm')
),
-- 2. הרשאות טבלה לתפקידים הציבוריים
g as (
  select table_name, grantee, string_agg(privilege_type, ',' order by privilege_type) as privs
    from information_schema.role_table_grants
   where table_schema = 'public' and grantee in ('anon', 'authenticated', 'PUBLIC')
   group by table_name, grantee
),
-- 3. פונקציות בסכמה public וההרשאות שלהן
f as (
  select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as sig,
         p.prosecdef as secdef,
         has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec,
         has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
),
-- 4. ספירה לפי אוסף בטבלת docs (שם האוסף בלבד; תיקיות data/users מקובצות)
dc as (
  select case when collection like 'data/users/%' then regexp_replace(collection, '^(data/users)/[^/]+(.*)$', '\1/<מזהה>\2')
              else collection end as col,
         count(*) as n
    from public.docs group by 1
),
-- 5. פרופילים: אילו שדות קיימים (ספירה בלבד)
pf as (
  select count(*) as total,
         count(*) filter (where coalesce(data->>'birthdate', '') <> '')        as with_birthdate,
         count(*) filter (where coalesce(data->>'birthFirstName', '') <> '')   as with_birth_first,
         count(*) filter (where coalesce(data->>'birthLastName', '') <> '')    as with_birth_last,
         count(*) filter (where data ? 'lifePathNumber')                        as with_lifepath,
         count(*) filter (where data ? 'birthdayNumber')                        as with_birthday_no,
         count(*) filter (where data ? 'expressionNumber')                      as with_expression_no,
         count(*) filter (where data ? 'vowelNumber')                           as with_vowel_no,
         count(*) filter (where data ? 'consonantsNumber')                      as with_consonants_no,
         count(*) filter (where coalesce(data->>'email', '') <> '')             as with_email_field,
         count(*) filter (where coalesce(data->>'photoUrl', '') like 'data:%') as photo_inline,
         count(*) filter (where data->>'ageBlocked' = 'true')                  as age_blocked,
         count(*) filter (where data->>'deleted' = 'true')                     as marked_deleted,
         coalesce(round(avg(pg_column_size(data)))::bigint, 0)                 as avg_bytes
    from public.docs where collection = 'profiles'
),
-- 6. חשבונות Supabase Auth (ספירה בלבד) והקישור שלהם לפרופילים
au as (
  select count(*) as users,
         count(*) filter (where email_confirmed_at is not null)                as confirmed,
         count(*) filter (where confirmation_sent_at is not null)              as confirmation_sent,
         count(*) filter (where coalesce(raw_user_meta_data->>'profileId', '') <> '') as with_profile_meta,
         count(*) filter (where raw_user_meta_data->>'deleted' = 'true')       as marked_deleted,
         count(*) filter (where last_sign_in_at > now() - interval '30 days')  as signed_in_30d
    from auth.users
),
link as (
  select
    (select count(*) from public.docs d where d.collection = 'profiles'
        and exists (select 1 from auth.users u where u.raw_user_meta_data->>'profileId' = d.id)) as profiles_with_auth,
    (select count(*) from public.docs d where d.collection = 'profiles'
        and not exists (select 1 from auth.users u where u.raw_user_meta_data->>'profileId' = d.id)) as profiles_without_auth,
    (select count(*) from (select raw_user_meta_data->>'profileId' as pid from auth.users
                            where coalesce(raw_user_meta_data->>'profileId', '') <> ''
                            group by 1 having count(*) > 1) x) as profile_ids_on_several_users,
    (select count(*) from public.docs d where d.collection like 'data/users/%'
        and coalesce(d.data->>'hash', '') <> '') as legacy_password_records
),
-- 7. טריגרים על docs
tr as (
  select tgname, pg_get_triggerdef(oid) as def from pg_trigger
   where tgrelid = 'public.docs'::regclass and not tgisinternal
),
-- 8. Realtime: אילו טבלאות משודרות
rt as (
  select schemaname || '.' || tablename as tbl from pg_publication_tables where pubname = 'supabase_realtime'
),
-- 9. עמודות של docs
cols as (
  select column_name, data_type, is_nullable, coalesce(column_default, '') as def, ordinal_position
    from information_schema.columns where table_schema = 'public' and table_name = 'docs'
)
select 'א. טבלאות' as "סעיף", name as "פריט",
       'RLS=' || case when rls then 'פעיל' else 'כבוי' end || case when rls_forced then ' (forced)' else '' end
       || ' · שורות≈' || approx_rows as "ערך"
  from t
union all
select 'ב. מדיניות RLS', tablename || ' · ' || policyname,
       cmd || ' · roles=' || array_to_string(roles, ',') || ' · using=' || coalesce(qual, '—') || ' · check=' || coalesce(with_check, '—')
  from pg_policies where schemaname = 'public'
union all
select 'ב. מדיניות RLS', '(סיכום)', count(*)::text || ' מדיניות בסכמה public' from pg_policies where schemaname = 'public'
union all
select 'ג. הרשאות טבלה', table_name || ' → ' || grantee, privs from g
union all
select 'ד. פונקציות', sig,
       case when secdef then 'SECURITY DEFINER' else 'רגילה' end
       || ' · anon=' || case when anon_exec then 'כן' else 'לא' end
       || ' · authenticated=' || case when auth_exec then 'כן' else 'לא' end
  from f
union all
select 'ה. אוספים ב-docs', col, n::text from dc
union all
select 'ו. פרופילים', k, v from pf,
  lateral (values ('סה״כ', total::text), ('עם תאריך לידה', with_birthdate::text),
                  ('עם שם פרטי מלידה', with_birth_first::text), ('עם שם משפחה מלידה', with_birth_last::text),
                  ('עם מספר דרך חיים', with_lifepath::text), ('עם מספר יום לידה', with_birthday_no::text),
                  ('עם מספר שם מלא', with_expression_no::text), ('עם מספר אותיות הנשמה', with_vowel_no::text),
                  ('עם מספר עיצורים', with_consonants_no::text), ('עם שדה אימייל בפרופיל', with_email_field::text),
                  ('תמונה שמורה בתוך הפרופיל', photo_inline::text), ('חסומי גיל', age_blocked::text),
                  ('מסומנים כמחוקים', marked_deleted::text), ('גודל ממוצע (בתים)', avg_bytes::text)) x(k, v)
union all
select 'ז. חשבונות Auth', k, v from au,
  lateral (values ('משתמשים', users::text), ('אימייל מאומת', confirmed::text),
                  ('נשלח אליהם אימייל אישור', confirmation_sent::text), ('עם profileId', with_profile_meta::text),
                  ('מסומנים כמחוקים', marked_deleted::text), ('התחברו ב-30 יום', signed_in_30d::text)) x(k, v)
union all
select 'ח. קישור חשבון↔פרופיל', k, v from link,
  lateral (values ('פרופילים עם חשבון Auth', profiles_with_auth::text), ('פרופילים בלי חשבון Auth', profiles_without_auth::text),
                  ('מזהה פרופיל שמופיע אצל כמה חשבונות', profile_ids_on_several_users::text),
                  ('רשומות סיסמה ישנות ב-docs', legacy_password_records::text)) x(k, v)
union all
select 'ט. טריגרים על docs', tgname, def from tr
union all
select 'י. Realtime', tbl, 'משודרת' from rt
union all
select 'כ. עמודות docs', column_name, data_type || ' · null=' || is_nullable || case when def <> '' then ' · ברירת מחדל=' || def else '' end from cols
union all
select 'ל. טבלאות מנויים / PR #5', x.n, case when to_regclass('public.' || x.n) is null then 'לא קיימת (תקין)' else 'קיימת!' end
  from (values ('hdm_subscriptions'), ('hdm_chat_openings'), ('hdm_profile_registry'), ('hdm_profile_owners'), ('hdm_data_requests')) x(n)
union all
select 'מ. גרסה', 'Postgres', split_part(version(), ' on ', 1)
order by 1, 2;
