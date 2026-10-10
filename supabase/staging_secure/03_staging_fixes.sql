-- =====================================================================
-- חיים דרך מספרים — סביבת ניסוי (Staging): תיקוני אבטחה אחרי בדיקת PR #12
-- להרצה פעם אחת, אחרי 01_staging_setup.sql, רק בפרויקט Haim Derech Misparim Staging
--
-- ⚠️ לפני ההרצה: בשורת הכתובת צריך להופיע ousepgdvzammgkxkweze
--
-- מה הקובץ משנה (כללי הרשאה בלבד):
--   תיקון 2 — דיווחים: האפליקציה שולחת דיווח בצורת upsert, ו-Postgres דורש לשם כך
--             כלל קריאה וכלל עדכון. נוספים שני כללים: מי שדיווח רואה רק את הדיווחים שלו,
--             ושינוי דיווח קיים נשאר חסום (הטריגר מחזיר HDM_READONLY).
--             זיוף "מי דיווח" נשאר בלתי אפשרי — השרת קובע את השדה by.
--   תיקון 3 — חסימות: מי שנחסם כבר לא יכול לגלות מי חסם אותו.
--             החוסם עדיין רואה את החסימות שלו. האכיפה בשרת לא משתנה:
--             מי שנחסם עדיין לא רואה את הפרופיל של החוסם ולא יכול לשלוח לו הודעות.
--   (תיקון 1 — ההגנה בתוך קובץ הבדיקות — נמצא בקובץ 02_staging_tests.sql עצמו.)
--
-- מה הקובץ לא עושה:
--   * לא מוחק, לא משנה ולא מעתיק שום נתון. אין כאן INSERT/UPDATE/DELETE על נתוני משתמשים.
--   * לא נוגע בטבלאות, בפונקציות או בטריגרים — רק בכללי RLS.
--
-- הגנות מובנות:
--   * נעצר אם זה לא פרויקט ניסוי שהוקם עם 01_staging_setup.sql (כמו הפרויקט הפעיל).
--   * נעצר אם התיקונים כבר הותקנו.
--   * "הכול או כלום": שגיאה אחת = שום דבר לא נשמר.
-- =====================================================================

begin;

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null or to_regclass('public.docs') is null then
    raise exception 'עצירה: זה לא פרויקט ניסוי שהוקם עם 01_staging_setup.sql. שום דבר לא שונה.';
  end if;
  if not exists (select 1 from public.hdm_staging_marker where version = 'staging_secure_v1') then
    raise exception 'עצירה: לא נמצאה התקנה של staging_secure_v1. שום דבר לא שונה.';
  end if;
  if exists (select 1 from public.hdm_staging_marker where version = 'staging_secure_v1_fixes') then
    raise exception 'עצירה: התיקונים כבר הותקנו בפרויקט הזה. שום דבר לא שונה.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- תיקון 2: דיווחים שנשלחים מהאפליקציה (upsert)
-- ---------------------------------------------------------------------
create policy reports_read_own on public.docs for select to authenticated
  using (collection = 'reports' and data->>'by' = public.hdm_me());

create policy reports_update_own on public.docs for update to authenticated
  using (collection = 'reports' and data->>'by' = public.hdm_me())
  with check (collection = 'reports' and data->>'by' = public.hdm_me());

-- ---------------------------------------------------------------------
-- תיקון 3: מי שנחסם לא רואה מי חסם אותו
-- ---------------------------------------------------------------------
drop policy blocks_read on public.docs;
create policy blocks_read on public.docs for select to authenticated
  using (collection = 'blocks' and split_part(id, '__', 1) = public.hdm_me());

insert into public.hdm_staging_marker (version, note)
values ('staging_secure_v1_fixes', 'תיקוני אבטחה: דיווחים (upsert) ופרטיות חסימות');

commit;

select '✅ תיקוני האבטחה הותקנו' as "סטטוס",
       (select count(*) from pg_policies where schemaname = 'public') as "כללי RLS";
