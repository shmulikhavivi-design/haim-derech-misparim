#!/usr/bin/env python3
"""Builds the guarded SQL files for the Staging project from the real source files.

Every generated file starts with a check that it is running in the Staging project
(public.hdm_staging_marker exists). In the Supabase SQL Editor the whole file is sent as
one query, so if the check fails nothing after it runs. Files that change anything are
also wrapped in BEGIN/COMMIT, so they apply completely or not at all.

Run from the repo root:  python3 scripts/build_staging_sql.py
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "supabase"
OUT = ROOT / "supabase" / "staging"

GUARD = """do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט ה-Staging. שום דבר לא הורץ ולא שונה. בדקו בראש המסך שנבחר הפרויקט Haim Derech Misparim Staging.';
  end if;
end $$;
"""

def header(title, what):
    return (
        "-- =====================================================================\n"
        f"-- סביבת בדיקות (Staging) — {title}\n"
        "-- ⚠️ רק בפרויקט Haim Derech Misparim Staging. בפרויקט האמיתי הקובץ נעצר בשורה הראשונה.\n"
        "-- הקובץ נוצר אוטומטית מ-scripts/build_staging_sql.py — לא לערוך ידנית.\n"
        f"-- {what}\n"
        "-- =====================================================================\n\n"
    )

def src(name):
    return (SRC / name).read_text(encoding="utf-8").rstrip() + "\n"

def write(name, text):
    (OUT / name).write_text(text, encoding="utf-8")
    print("wrote", name)

# 02 — age gate, exactly as in production
write("02_staging_age_gate.sql",
      header("שלב 2: הגבלת גיל 18+", "אותו קובץ כמו supabase/age_gate.sql שכבר מותקן בפרויקט האמיתי.")
      + GUARD + "\nbegin;\n\n" + src("age_gate.sql")
      + "\ncommit;\n\nselect case when to_regprocedure('public.hdm_profiles_age_gate()') is not null"
        " then '✅ הגבלת הגיל הותקנה' else '❌ לא הותקן — שום דבר לא שונה' end as \"סטטוס\";\n")

# 04 — PR #9: tables, functions and enforcement
write("04_staging_subscriptions.sql",
      header("שלב 4: מערכת המנויים מ-PR #9", "subscriptions.sql ואחריו subscriptions_enforce.sql, ברצף אחד.")
      + GUARD + "\nbegin;\n\n" + src("subscriptions.sql") + "\n" + src("subscriptions_enforce.sql")
      + "\ncommit;\n\nselect case when to_regclass('public.hdm_subscriptions') is not null"
        " and exists (select 1 from pg_trigger where tgname = 'hdm_docs_subscription_guard')"
        " then '✅ מערכת המנויים הותקנה, כולל אכיפה' else '❌ לא הותקן — שום דבר לא שונה' end as \"סטטוס\";\n")

# 05 — plans for the four test accounts, found by the name they registered with
write("05_staging_set_plans.sql",
      header("שלב 5: מסלול לכל חשבון בדיקה",
             "מוצא את ארבעת חשבונות הבדיקה לפי השם שנרשמו איתו, ומגדיר לכל אחד את המסלול שלו.")
      + GUARD + """
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
""")

# 06 — automatic tests: PR #9 rules + permission baseline from the app's point of view
tests = src("subscriptions_test.sql")
tests = tests.replace("select * from pg_temp.hdm_run_subscription_tests();", "").rstrip() + "\n"
write("06_staging_tests.sql",
      header("שלב 6: בדיקות אוטומטיות",
             "בדיקות המנויים מ-PR #9 ובדיקות הרשאה. הכול מתבטל בסוף — שום דבר לא נשמר.")
      + GUARD + "\n" + tests + "\n" + (OUT / "src" / "security_baseline.sql").read_text(encoding="utf-8")
      + """
select 'מנויים' as "קבוצה", t.* from pg_temp.hdm_run_subscription_tests() t
union all
select 'הרשאות', s.* from pg_temp.hdm_security_baseline() s
order by 1 desc, 2;
""")

# 07 — read-only status
write("07_staging_status.sql",
      header("מצב הסביבה (קריאה בלבד)", "לא משנה כלום. מציג מה מותקן ומה מוגדר."))
(OUT / "07_staging_status.sql").write_text(
    (OUT / "07_staging_status.sql").read_text(encoding="utf-8") + GUARD + """
select 'רכיב' as "סוג", x.k as "פריט", x.v as "מצב" from (values
  ('סימון Staging', '✅'),
  ('טבלת docs', case when to_regclass('public.docs') is not null then '✅' else '❌' end),
  ('הגבלת גיל', case when exists (select 1 from pg_trigger where tgname = 'hdm_profiles_age_gate') then '✅' else 'עדיין לא' end),
  ('טבלאות מנויים', case when to_regclass('public.hdm_subscriptions') is not null then '✅' else 'עדיין לא' end),
  ('אכיפת מנויים', case when exists (select 1 from pg_trigger where tgname = 'hdm_docs_subscription_guard') then '✅' else 'עדיין לא' end)
) x(k, v)
union all
select 'נתונים', 'פרופילים מומצאים', count(*)::text from public.docs where collection = 'profiles' and id like 'stg\\_%'
union all
select 'נתונים', 'פרופילים שנרשמו באפליקציה', count(*)::text from public.docs where collection = 'profiles' and id not like 'stg\\_%'
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
""", encoding="utf-8")
print("wrote 07_staging_status.sql (with body)")
