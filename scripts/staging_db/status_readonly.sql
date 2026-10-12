-- =====================================================================
-- חיים דרך מספרים — Staging: בדיקת מצב לקריאה בלבד
-- לא משנה שום דבר. רץ בטרנזקציה לקריאה בלבד (default_transaction_read_only=on).
-- =====================================================================
\pset footer off

\echo '== 1. זהות הפרויקט'
select case when to_regclass('public.hdm_staging_marker') is not null then '✅ פרויקט ניסוי (יש hdm_staging_marker)'
            else '❌ אין hdm_staging_marker — זה לא פרויקט הניסוי' end as "זהות",
       current_setting('transaction_read_only') as "קריאה בלבד";

\echo '== 2. מה מותקן'
select version as "גרסה", installed_at::date as "תאריך" from public.hdm_staging_marker order by installed_at;
select (exists (select 1 from public.hdm_staging_marker where version = 'staging_secure_v1_fixes'))  as "03 מותקן",
       (exists (select 1 from public.hdm_staging_marker where version = 'staging_secure_v1_fixes2')) as "04 מותקן",
       (exists (select 1 from public.hdm_staging_marker where version = 'staging_secure_v1_fixes3')) as "05 מותקן",
       (select count(*) from pg_policies where schemaname = 'public') as "כללי RLS";

\echo '== 3. טבלאות ו-RLS (מספר שורות בלבד — בלי תוכן)'
select c.relname as "טבלה", c.relrowsecurity as "RLS",
       (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from public.%I', c.relname), false, true, '')))[1]::text::int as "שורות"
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'r' order by 1;

\echo '== 4. מסלולים ומחירים'
select plan as "מסלול", name_he as "שם", price_agorot / 100.0 as "מחיר ₪", monthly_new_chats as "שיחות בחודש",
       extended_analysis as "ניתוח מורחב", limor_discount_pct as "הנחה %"
  from public.hdm_plans order by sort_order;

\echo '== 5. הרשאות לאפליקציה (anon / authenticated)'
select grantee as "תפקיד", string_agg(table_name || ':' || privilege_type, ', ' order by table_name, privilege_type) as "הרשאות על טבלאות"
  from information_schema.role_table_grants
 where table_schema = 'public' and grantee in ('anon', 'authenticated') group by grantee order by 1;
select count(*) filter (where has_function_privilege('anon', p.oid, 'EXECUTE')) as "פונקציות שאורח יכול להפעיל",
       count(*) filter (where has_function_privilege('authenticated', p.oid, 'EXECUTE')) as "פונקציות שמשתמש מחובר יכול להפעיל",
       bool_or(p.proname like 'hdm_admin%' and has_function_privilege('authenticated', p.oid, 'EXECUTE')) as "❗ פונקציית מנהל פתוחה לאפליקציה"
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'hdm\_%';

\echo '== 6. סיכום'
select case
  when to_regclass('public.hdm_staging_marker') is null then '❌ לא פרויקט ניסוי — לא להריץ שום דבר נוסף'
  when not exists (select 1 from public.hdm_staging_marker where version = 'staging_secure_v1_fixes') then 'ℹ️ צריך להריץ את 03 (בעורך ה-SQL), ואז 04 ו-02'
  when not exists (select 1 from public.hdm_staging_marker where version = 'staging_secure_v1_fixes2') then 'ℹ️ מוכן ל-04 ואז 02'
  when not exists (select 1 from public.hdm_staging_marker where version = 'staging_secure_v1_fixes3') then 'ℹ️ מוכן ל-05 ואז 02'
  else '✅ 01, 03, 04 ו-05 מותקנים — מוכן ל-02' end as "המצב";
