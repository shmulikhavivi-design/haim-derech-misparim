-- =====================================================================
-- חיים דרך מספרים — Production: ביטול המעבר (חירום בלבד, באישור)
--
-- מחזיר את המסד למצב שלפני 01_production_migration.sql:
--   * טבלת docs חוזרת בדיוק לגיבוי (hdm_backup.docs_before_migration)
--     ⚠️ כל מה שנכתב אחרי המעבר (הודעות, 🎯, פרופילים חדשים) לא יישמר. נשמר עותק שלו ב-hdm_backup.docs_after_migration.
--   * טבלאות hdm_* הישנות חוזרות מהגיבוי; הטבלאות והפונקציות החדשות נמחקות
--   * הגישה ל-docs נפתחת כמו לפני המעבר (האפליקציה הישנה עובדת רק כך), והגבלת הגיל הישנה מותקנת מחדש בנפרד:
--     אחרי הקובץ הזה מריצים את supabase/age_gate.sql מ-main.
--   * משתמשי Auth שנוצרו במעבר לחשבונות קיימים נמחקים (רק אלה שסומנו hdm_migrated).
-- יחד עם הקובץ: מחזירים את index.html הקודם (Revert ל-PR של הגרסה).
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_release_marker') is null or to_regclass('hdm_backup.docs_before_migration') is null then
    raise exception 'עצירה: לא נמצא מעבר או גיבוי. שום דבר לא שונה.';
  end if;
end $$;

create table hdm_backup.docs_after_migration as table public.docs;
create table hdm_backup.private_after_migration as table public.hdm_profile_private;

do $$
declare r record;
begin
  for r in select policyname from pg_policies where schemaname = 'public' and tablename = 'docs' loop
    execute format('drop policy %I on public.docs', r.policyname);
  end loop;
  for r in select tgname from pg_trigger where tgrelid = 'public.docs'::regclass and not tgisinternal loop
    execute format('drop trigger %I on public.docs', r.tgname);
  end loop;
  for r in select p.oid::regprocedure as f from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'hdm\_%' loop
    execute 'drop function ' || r.f::text || ' cascade';
  end loop;
  for r in select c.relname from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relname like 'hdm\_%' loop
    execute format('drop table public.%I cascade', r.relname);
  end loop;
  for r in select c.relname from pg_class c where c.relnamespace = 'hdm_backup'::regnamespace and c.relkind = 'r' and c.relname like 'hdm\_%' loop
    execute format('alter table hdm_backup.%I set schema public', r.relname);
  end loop;
end $$;

delete from public.docs;
insert into public.docs select * from hdm_backup.docs_before_migration;

delete from auth.users where (raw_app_meta_data->>'hdm_migrated') = 'true';

-- גישה כמו לפני המעבר
alter table public.docs enable row level security;
create policy docs_open_legacy on public.docs for all to anon, authenticated using (true) with check (true);
grant select, insert, update, delete on public.docs to anon, authenticated;

commit;

select '↩️ המעבר בוטל. עכשיו: להריץ supabase/age_gate.sql ולהחזיר את index.html הקודם.' as "סטטוס",
       (select count(*) from public.docs) as "רשומות ב-docs";
