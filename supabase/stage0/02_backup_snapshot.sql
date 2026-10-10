-- =====================================================================
-- חיים דרך מספרים — גיבוי לפני שינויי האבטחה
-- ⚠️ לא להריץ עכשיו. מריצים רק באישור, ממש לפני השלב הראשון שמשנה את המסד.
--
-- למה צריך: בתוכנית החינמית של Supabase אין גיבויים אוטומטיים שאפשר לשחזר מהם.
--
-- מה זה עושה:
--   * יוצר סכמה נפרדת hdm_backup, שאינה חשופה ל-API של האפליקציה, וסגורה לכל התפקידים הציבוריים.
--   * מעתיק אליה את כל טבלת docs כמו שהיא, בטבלה עם תאריך ושעה בשם (למשל docs_20261012_2130).
--   * בודק שמספר השורות והתוכן זהים למקור, ומציג את התוצאה.
--
-- מה זה לא עושה: לא משנה ולא מוחק שום דבר בטבלת docs או בחשבונות המשתמשים.
--
-- חשוב: הגיבוי מכיל את כל המידע האישי. הוא נשאר סגור בתוך המסד, ונמחק רק באישור,
-- כשבטוח שאין בו צורך (מומלץ אחרי 30 יום של עבודה תקינה).
--
-- גיבוי נוסף מחוץ למסד (מומלץ): Table Editor ← docs ← Export ← Export table as CSV,
-- ולשמור את הקובץ במקום פרטי (לא במייל ולא בצ'אט).
-- =====================================================================

create schema if not exists hdm_backup;
revoke all on schema hdm_backup from public, anon, authenticated;

do $$
declare
  t text := 'docs_' || to_char(now() at time zone 'Asia/Jerusalem', 'YYYYMMDD_HH24MI');
begin
  if to_regclass('hdm_backup.' || t) is not null then
    raise exception 'גיבוי בשם % כבר קיים. מחכים דקה ומריצים שוב.', t;
  end if;
  execute format('create table hdm_backup.%I as table public.docs', t);
  execute format('revoke all on hdm_backup.%I from public, anon, authenticated', t);
  execute format('alter table hdm_backup.%I enable row level security', t);
  execute format('comment on table hdm_backup.%I is %L', t, 'גיבוי docs לפני שינויי האבטחה — לא למחוק בלי אישור');
end $$;

-- בדיקה: לכל גיבוי — מספר שורות וטביעת אצבע של התוכן, מול הטבלה המקורית
select b.table_name as "גיבוי",
       (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from hdm_backup.%I', b.table_name), false, true, '')))[1]::text as "שורות בגיבוי",
       (select count(*) from public.docs)::text as "שורות במקור",
       case when (xpath('/row/c/text()', query_to_xml(format(
                  'select md5(string_agg(collection || chr(31) || id || chr(31) || data::text, chr(30) order by collection, id)) as c from hdm_backup.%I', b.table_name), false, true, '')))[1]::text
               = (select md5(string_agg(collection || chr(31) || id || chr(31) || data::text, chr(30) order by collection, id)) from public.docs)
            then '✅ זהה למקור' else 'שונה מהמקור (תקין רק אם זה גיבוי ישן)' end as "תוכן"
  from information_schema.tables b
 where b.table_schema = 'hdm_backup' and b.table_name like 'docs\_%'
 order by b.table_name desc;

-- =====================================================================
-- שחזור — רק בתקלה חמורה ורק באישור. לא להריץ כחלק מהגיבוי.
-- מחזיר כל שורה שהייתה בגיבוי לתוכן שהיה לה בזמן הגיבוי.
-- שורות שנוצרו אחרי הגיבוי (פרופילים, הודעות חדשות) לא נמחקות.
-- לפני שחזור מריצים את קובצי הביטול של שלבי האבטחה, כדי שהטריגרים לא יחסמו את השחזור.
-- להחליף את <שם_הגיבוי> בשם מהטבלה למעלה:
--
-- insert into public.docs (collection, id, data, updated_at)
-- select collection, id, data, updated_at from hdm_backup.<שם_הגיבוי>
-- on conflict (collection, id) do update set data = excluded.data, updated_at = excluded.updated_at;
-- =====================================================================
