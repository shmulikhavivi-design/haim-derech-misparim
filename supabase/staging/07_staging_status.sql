-- =====================================================================
-- סביבת בדיקות (Staging) — מצב הסביבה (קריאה בלבד)
-- ⚠️ רק בפרויקט Haim Derech Misparim Staging. בפרויקט האמיתי הקובץ נעצר בשורה הראשונה.
-- הקובץ נוצר אוטומטית מ-scripts/build_staging_sql.py — לא לערוך ידנית.
-- לא משנה כלום. מציג מה מותקן ומה מוגדר.
-- =====================================================================

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט ה-Staging. שום דבר לא הורץ ולא שונה. בדקו בראש המסך שנבחר הפרויקט Haim Derech Misparim Staging.';
  end if;
end $$;

select 'רכיב' as "סוג", x.k as "פריט", x.v as "מצב" from (values
  ('סימון Staging', '✅'),
  ('טבלת docs', case when to_regclass('public.docs') is not null then '✅' else '❌' end),
  ('הגבלת גיל', case when exists (select 1 from pg_trigger where tgname = 'hdm_profiles_age_gate') then '✅' else 'עדיין לא' end),
  ('טבלאות מנויים', case when to_regclass('public.hdm_subscriptions') is not null then '✅' else 'עדיין לא' end),
  ('אכיפת מנויים', case when exists (select 1 from pg_trigger where tgname = 'hdm_docs_subscription_guard') then '✅' else 'עדיין לא' end)
) x(k, v)
union all
select 'נתונים', 'פרופילים מומצאים', count(*)::text from public.docs where collection = 'profiles' and id like 'stg\_%'
union all
select 'נתונים', 'פרופילים שנרשמו באפליקציה', count(*)::text from public.docs where collection = 'profiles' and id not like 'stg\_%'
union all
select 'נתונים', 'שיחות', count(*)::text from public.docs where collection = 'chats'
union all
select 'חשבון בדיקה', btrim(d.data->>'currentName'),
       case when to_regclass('public.hdm_subscriptions') is null then 'מערכת המנויים עוד לא הותקנה'
            else (xpath('/row/p/text()', query_to_xml(format(
                    'select coalesce(max(s.plan || '' ('' || s.source || '')''), ''free — אין מנוי'') as p from public.hdm_subscriptions s where s.profile_id = %L',
                    d.id), false, true, '')))[1]::text end
  from public.docs d
 where d.collection = 'profiles' and btrim(d.data->>'currentName') like 'בדיקה %';
