-- =====================================================================
-- סביבת בדיקות (Staging) — שלב 1: מבנה המסד
-- ⚠️ רק בפרויקט Supabase חדש ונפרד לבדיקות. אסור בפרויקט האמיתי.
--
-- יוצר את טבלת docs באותו מבנה ובאותן הרשאות כמו בפרויקט האמיתי היום (כולל הפתיחות
-- הקיימת), כדי שהבדיקות ישקפו את המצב האמיתי לפני תיקוני האבטחה.
-- לא מועתק שום נתון מהפרויקט האמיתי.
--
-- הגנה: אם כבר קיימת טבלת docs עם נתונים, הקובץ נעצר בלי לשנות כלום.
-- (את העמודות וההרשאות נעדכן לפי תוצאות 01_audit_readonly.sql מהפרויקט האמיתי.)
--
-- סדר מלא בפרויקט ה-Staging (ההסבר המלא: supabase/staging/README.md):
--   01 מבנה ← 02 הגבלת גיל ← 03 נתונים מומצאים ← הרשמת 4 חשבונות בדיקה באפליקציה
--   ← 04 מנויים (PR #9) ← 05 מסלולים לחשבונות ← 06 בדיקות ← 07 מצב
-- =====================================================================

do $$
begin
  if to_regclass('public.docs') is not null then
    if exists (select 1 from public.docs limit 1) then
      raise exception 'כבר קיימת טבלת docs עם נתונים — כנראה שזה הפרויקט האמיתי. שום דבר לא שונה.';
    end if;
  end if;
end $$;

begin;

create table if not exists public.docs (
  collection text        not null,
  id         text        not null,
  data       jsonb       not null default '{}'::jsonb,
  updated_at timestamptz default now(),
  primary key (collection, id)
);

-- כמו היום בפרויקט האמיתי: פתוח לקריאה ולכתיבה עם המפתח הציבורי (זה בדיוק מה שנתקן)
grant select, insert, update, delete on public.docs to anon, authenticated;

-- עדכונים חיים (האפליקציה מאזינה לשינויים בטבלה)
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'docs') then
    alter publication supabase_realtime add table public.docs;
  end if;
end $$;

-- סימון שזה פרויקט Staging (קובצי הבדיקה בודקים אותו לפני שהם רצים)
create table if not exists public.hdm_staging_marker (
  created_at timestamptz not null default now(),
  note       text not null default 'פרויקט בדיקות — אין כאן משתמשים אמיתיים'
);
alter table public.hdm_staging_marker enable row level security;
revoke all on public.hdm_staging_marker from public, anon, authenticated;
insert into public.hdm_staging_marker select where not exists (select 1 from public.hdm_staging_marker);

commit;

select '✅ מבנה ה-Staging מוכן' as "סטטוס";
