-- =====================================================================
-- סביבת בדיקות (Staging) — שלב 5: מסלול לכל חשבון בדיקה
-- ⚠️ רק בפרויקט Haim Derech Misparim Staging. בפרויקט האמיתי הקובץ נעצר בשורה הראשונה.
-- הקובץ נוצר אוטומטית מ-scripts/build_staging_sql.py — לא לערוך ידנית.
-- מוצא את ארבעת חשבונות הבדיקה לפי השם שנרשמו איתו, ומגדיר לכל אחד את המסלול שלו.
-- =====================================================================

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט ה-Staging. שום דבר לא הורץ ולא שונה. בדקו בראש המסך שנבחר הפרויקט Haim Derech Misparim Staging.';
  end if;
end $$;

begin;

create temporary table hdm_stg_plans (account_name text, plan text) on commit drop;
insert into hdm_stg_plans values
  ('בדיקה חינם', 'free'), ('בדיקה בסיסי', 'basic'), ('בדיקה פלוס', 'plus'), ('בדיקה VIP', 'vip');

create temporary table hdm_stg_result on commit preserve rows as
select p.account_name as "חשבון", p.plan as "מסלול",
       (select count(*) from public.docs d where d.collection = 'profiles' and btrim(d.data->>'currentName') = p.account_name) as found
  from hdm_stg_plans p;

select public.hdm_admin_set_plan(d.id, p.plan, 'test', 'Staging: ' || p.account_name)
  from hdm_stg_plans p
  join public.docs d on d.collection = 'profiles' and btrim(d.data->>'currentName') = p.account_name
 where (select count(*) from public.docs x where x.collection = 'profiles' and btrim(x.data->>'currentName') = p.account_name) = 1;

commit;

select "חשבון", "מסלול",
       case when found = 1 then '✅ הוגדר'
            when found = 0 then 'לא נמצא — צריך להירשם באפליקציה בשם הזה בדיוק'
            else 'נמצאו כמה פרופילים בשם הזה — לא הוגדר' end as "תוצאה"
  from hdm_stg_result;
