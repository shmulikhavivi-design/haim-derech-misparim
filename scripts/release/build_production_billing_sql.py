#!/usr/bin/env python3
# =====================================================================
# בונה את קובץ המעבר של מנגנון המנויים בתשלום ל-Production מתוך קובצי Staging שנבדקו:
#   17 (מנויים מתחדשים) + 19 (שדרוג וחידוש בכרטיס שמור) + 21 (ביטול) + 23 (ביטול עסקה לפי החוק) + 24 (Morning)
# אותו קוד שרת בדיוק; רק הבדיקה המקדימה וסימון הגרסה מותאמים ל-Production. הכול בעסקה אחת — "הכול או כלום".
# אין להריץ את הקובץ שנוצר בלי אישור מפורש של הבעלים.
#   python3 scripts/release/build_production_billing_sql.py  →  supabase/production/08_production_billing.sql
# =====================================================================
import pathlib, re

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / 'supabase' / 'staging_secure'
OUT = ROOT / 'supabase' / 'production' / '08_production_billing.sql'
FILES = ['17_staging_billing', '19_staging_billing_upgrade', '21_staging_billing_cancel',
         '23_staging_billing_statutory_cancel', '24_staging_billing_morning']

def body(name: str) -> str:
    s = (SRC / f'{name}.sql').read_text(encoding='utf-8')
    # מתחילים אחרי בלוק הבדיקה המקדימה של Staging (ה-do $$ הראשון), ועוצרים לפני סימון הגרסה של Staging
    start = s.index('begin;\n')
    guard_end = s.index('end $$;\n', start) + len('end $$;\n')
    assert 'hdm_staging_marker' in s[start:guard_end], f'{name}: לא נמצאה בדיקת Staging בתחילת הקובץ'
    stop = s.index('insert into public.hdm_staging_marker', guard_end)
    tail = s[stop:]
    m = re.match(r"insert into public\.hdm_staging_marker \(version, note\)\nvalues \('[^']+', '[^']*'\);\n\s*commit;\s*", tail)
    assert m, f'{name}: סוף לא צפוי'
    after = tail[m.end():]   # אחרי commit מותר רק דוח קריאה (select), והוא לא נכלל בקובץ ל-Production
    assert not re.search(r'\b(insert|update|delete|alter|create|drop|grant|revoke|truncate)\b', re.sub(r"'[^']*'|\"[^\"]*\"", '', after), re.I), f'{name}: יש פעולה אחרי commit'
    part = s[guard_end:stop]
    assert 'hdm_staging_marker' not in part, f'{name}: יש התייחסות ל-Staging בגוף הקובץ'
    assert not re.search(r'^\s*(begin|commit|rollback);', part, re.M), f'{name}: עסקה פנימית'
    return f'-- ===================== {name}.sql (ללא שינוי) =====================\n' + part.strip() + '\n'

HEADER = """-- =====================================================================
-- חיים דרך מספרים — מנויים בתשלום ב-Production (נוצר אוטומטית מ-scripts/release/build_production_billing_sql.py)
-- אותו קוד שרת שנבדק ב-Staging: 17 + 19 + 21 + 23 + 24. לא לערוך ידנית.
--
-- מה הקובץ עושה: מוסיף טבלאות ופונקציות שרת לתשלומים, חידושים, שדרוגים וביטולים.
-- מה הוא לא עושה: לא מחייב, לא מתחבר ל-Morning, לא משנה מחירים, לא משנה מסלול של אף משתמש,
--   ולא מוחק נתונים. הסליקה נשארת כבויה עד שהאפליקציה והפונקציות מופעלות בנפרד, באישור.
-- "הכול או כלום": עסקה אחת; כל בדיקה שנכשלת מבטלת הכול. הרצה חוזרת נעצרת בלי לשנות דבר.
-- להרצה רק אחרי גיבוי מלא ואישור מפורש של הבעלים.
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_release_marker') is null or to_regclass('public.hdm_staging_marker') is not null then
    raise exception 'עצירה: זה לא מסד ה-Production אחרי המעבר המאובטח. שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_consents') is null or to_regclass('public.hdm_subscriptions') is null or to_regclass('public.hdm_plans') is null then
    raise exception 'עצירה: חסרים רכיבי בסיס (אישור תנאים / מנויים / מסלולים). שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_payments') is not null or exists (select 1 from public.hdm_release_marker where version = 'production_billing_v1') then
    raise exception 'עצירה: מנגנון המנויים בתשלום כבר מותקן. שום דבר לא שונה.';
  end if;
end $$;

-- תמונת מצב לפני: מסלולים ומחירים, ומסלול כל משתמש (לבדיקה בסוף שלא השתנה דבר)
create temp table hdm_pre_plans on commit drop as
  select string_agg(plan || ':' || price_agorot || ':' || coalesce(monthly_new_chats::text, '∞') || ':' || limor_discount_pct, ',' order by sort_order) as v from public.hdm_plans;
create temp table hdm_pre_subs on commit drop as
  select profile_id, public.hdm_plan_of(profile_id) as plan from public.hdm_subscriptions;
create temp table hdm_pre_counts on commit drop as
  select (select count(*) from public.docs) as docs, (select count(*) from auth.users) as users, (select count(*) from public.hdm_accounts) as accounts;

"""

FOOTER = """
-- ===================== בדיקות אחרי ההתקנה (באותה עסקה) =====================
do $$
declare bad int;
begin
  if (select string_agg(plan || ':' || price_agorot || ':' || coalesce(monthly_new_chats::text, '∞') || ':' || limor_discount_pct, ',' order by sort_order) from public.hdm_plans)
     <> (select v from hdm_pre_plans) then
    raise exception 'עצירה: מסלול או מחיר השתנו. שום דבר לא נשמר.';
  end if;
  select count(*) into bad from hdm_pre_subs p where public.hdm_plan_of(p.profile_id) is distinct from p.plan;
  if bad > 0 then raise exception 'עצירה: המסלול של % משתמשים השתנה. שום דבר לא נשמר.', bad; end if;
  if (select docs from hdm_pre_counts) <> (select count(*) from public.docs)
     or (select users from hdm_pre_counts) <> (select count(*) from auth.users)
     or (select accounts from hdm_pre_counts) <> (select count(*) from public.hdm_accounts) then
    raise exception 'עצירה: מספר הרשומות השתנה. שום דבר לא נשמר.';
  end if;
  if (select count(*) from public.hdm_payments) + (select count(*) from public.hdm_checkouts) + (select count(*) from public.hdm_billing_tokens) <> 0 then
    raise exception 'עצירה: נוצרו רשומות תשלום. שום דבר לא נשמר.';
  end if;
  if to_regprocedure('public.hdm_billing_checkout_lookup(uuid)') is null or to_regprocedure('public.hdm_billing_apply_morning_renewal(jsonb)') is null then
    raise exception 'עצירה: פונקציות Morning לא הותקנו. שום דבר לא נשמר.';
  end if;
end $$;

insert into public.hdm_release_marker (version, note)
values ('production_billing_v1', 'מנויים בתשלום (17+19+21+23+24 מ-Staging) — מותקן, הסליקה כבויה עד הפעלה נפרדת');

commit;
"""

out = HEADER + '\n'.join(body(f) for f in FILES) + FOOTER
OUT.write_text(out, encoding='utf-8')
print('נוצר', OUT.relative_to(ROOT), f'({out.count(chr(10))} שורות)')
