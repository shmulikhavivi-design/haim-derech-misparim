-- =====================================================================
-- חיים דרך מספרים — Production: בדיקה מקדימה לקריאה בלבד (לפני המעבר)
-- לא משנה שום דבר. מחזירה רק ספירות ומזהים טכניים — בלי שמות, אימיילים או תוכן אישי.
-- כל השורות בעמודה "תקין" צריכות להיות ✅ (או ℹ️ למידע בלבד) לפני הרצת 01_production_migration.sql.
-- =====================================================================
begin transaction read only;

with
  prof as (select id, data from public.docs where collection = 'profiles'),
  chk as (
    select 1 as n, 'זה הפרויקט הפעיל (אין סימון Staging)' as "בדיקה",
           (to_regclass('public.hdm_staging_marker') is null)::text as "ערך",
           to_regclass('public.hdm_staging_marker') is null as ok
    union all select 2, 'המעבר עוד לא בוצע', (to_regclass('public.hdm_release_marker') is null and to_regclass('hdm_backup.docs_before_migration') is null)::text,
           to_regclass('public.hdm_release_marker') is null and to_regclass('hdm_backup.docs_before_migration') is null
    union all select 2.5, 'גיבויים ידניים קיימים ב-hdm_backup (נשמרים, המעבר לא נוגע בהם)',
           coalesce((select string_agg(relname, ', ' order by relname) from pg_class where to_regnamespace('hdm_backup') is not null and relnamespace = to_regnamespace('hdm_backup') and relkind = 'r'), '—'), true
    union all select 3, 'פרופילים', (select count(*) from prof)::text, true
    union all select 4, 'פרופילים בלי תאריך לידה תקין (יתבקשו להשלים בכניסה)',
           (select count(*) from prof where coalesce(data->>'birthdate', '') !~ '^\d{4}-\d{2}-\d{2}$')::text, true
    union all select 5, 'מזהי פרופיל שלא יתאימו לקישור חשבון (קו תחתון בקצה, __, תווים אחרים)',
           (select count(*) from prof where id !~ '^[A-Za-z0-9-][A-Za-z0-9_-]{1,62}[A-Za-z0-9-]$' or position('__' in id) > 0)::text,
           (select count(*) from prof where id !~ '^[A-Za-z0-9-][A-Za-z0-9_-]{1,62}[A-Za-z0-9-]$' or position('__' in id) > 0) = 0
    union all select 6, 'חשבונות קיימים (data/users) עם אימייל ופרופיל קיים',
           (select count(distinct lower(btrim(d.data->>'email'))) from public.docs d
             where d.collection like 'data/users/%' and coalesce(d.data->>'email', '') like '%@%'
               and exists (select 1 from prof p where p.id = d.data->>'profileId'))::text, true
    union all select 7, 'פרופיל אחד עם כמה אימיילים שונים (לא יקושר אוטומטית — החלטה ידנית אחרי המעבר)',
           (select count(*) from (select d.data->>'profileId' from public.docs d where d.collection like 'data/users/%' and coalesce(d.data->>'email','') like '%@%'
                                  group by 1 having count(distinct lower(btrim(d.data->>'email'))) > 1) z)::text,
           (select count(*) from (select d.data->>'profileId' from public.docs d where d.collection like 'data/users/%' and coalesce(d.data->>'email','') like '%@%'
                                  group by 1 having count(distinct lower(btrim(d.data->>'email'))) > 1) z) = 0
    union all select 8, 'משתמשי Auth קיימים', (select count(*) from auth.users)::text, true
    union all select 9, '🎯 (interests) / likes בפרופילים',
           (select count(*) from public.docs where collection = 'interests')::text || ' / ' ||
           (select coalesce(sum(jsonb_array_length(data->'likes')), 0) from prof where jsonb_typeof(data->'likes') = 'array')::text, true
    union all select 10, 'שיחות / התאמות', (select count(*) from public.docs where collection = 'chats')::text || ' / ' ||
           (select count(*) from public.docs where collection = 'matches')::text, true
    union all select 11, 'מזהי שיחה שאינם בפורמט a__b',
           (select count(*) from public.docs where collection in ('chats','matches','interests') and (split_part(id,'__',2) = '' or split_part(id,'__',3) <> ''))::text,
           (select count(*) from public.docs where collection in ('chats','matches','interests') and (split_part(id,'__',2) = '' or split_part(id,'__',3) <> '')) = 0
    union all select 12, 'טבלאות hdm_* קיימות (יעברו לגיבוי)',
           coalesce((select string_agg(relname, ', ') from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' and relname like 'hdm\_%'), '—'), true
    union all select 13, 'טריגרים על docs (יוחלפו)',
           coalesce((select string_agg(tgname, ', ') from pg_trigger where tgrelid = 'public.docs'::regclass and not tgisinternal), '—'), true
    union all select 14, 'כללי RLS על docs (יוחלפו)',
           coalesce((select string_agg(policyname, ', ') from pg_policies where schemaname = 'public' and tablename = 'docs'), '—'), true
    union all select 15, 'pgcrypto זמין (ליצירת משתמשי Auth לחשבונות קיימים)',
           (exists (select 1 from pg_proc where proname = 'crypt'))::text, exists (select 1 from pg_proc where proname = 'crypt')
    union all select 16, 'טבלאות נוספות בסכימה public (מלבד docs ו-hdm_*) — יקבלו "revoke" מהאפליקציה',
           coalesce((select string_agg(relname, ', ') from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' and relname <> 'docs' and relname not like 'hdm\_%'), '—'),
           not exists (select 1 from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' and relname <> 'docs' and relname not like 'hdm\_%')
    union all select 17, 'גודל טבלת docs', pg_size_pretty(pg_total_relation_size('public.docs')), true
  )
select n, "בדיקה", "ערך", case when ok then '✅' else '⚠️' end as "תקין" from chk order by n;

rollback;
