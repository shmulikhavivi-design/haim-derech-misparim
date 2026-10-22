-- מחיקת הגיבויים הפנימיים הישנים (9.10 ו-16.10) מסכימת hdm_backup — אישור הבעלים 22.10 11:32.
-- לא נוגע בנתונים הפעילים (public / auth). נעצר אם משהו במסד תלוי בטבלאות. "הכול או כלום".
begin;
create temp table pre on commit drop as select
  (select md5(string_agg(collection||'|'||id||'|'||data::text, ',' order by collection, id)) from public.docs) docs_h,
  (select count(*) from auth.users) au, (select md5(string_agg(row_to_json(s)::text, ',' order by profile_id)) from public.hdm_subscriptions s) subs_h;
do $$ declare n int; begin
  -- רק שלוש הטבלאות הצפויות, בלי טבלאות אחרות בסכימה
  if (select string_agg(relname, ',' order by relname) from pg_class where relnamespace = 'hdm_backup'::regnamespace and relkind in ('r','v','m','S','p'))
     <> 'counts_before_migration,docs_20261009,docs_before_migration' then raise exception 'עצירה: בסכימת הגיבוי יש אובייקטים לא צפויים'; end if;
  -- אין view / פונקציה / אילוץ שתלויים בהן
  select count(*) into n from pg_depend d join pg_class c on c.oid = d.refobjid
   where c.relnamespace = 'hdm_backup'::regnamespace and d.deptype = 'n' and d.classid <> 'pg_class'::regclass;
  if n > 0 then raise exception 'עצירה: % תלויות במסד', n; end if;
  select count(*) into n from pg_rewrite r join pg_depend d on d.objid = r.oid join pg_class c on c.oid = d.refobjid
   where c.relnamespace = 'hdm_backup'::regnamespace and r.ev_class not in (select oid from pg_class where relnamespace = 'hdm_backup'::regnamespace);
  if n > 0 then raise exception 'עצירה: % views תלויים', n; end if;
  select count(*) into n from pg_proc p where p.pronamespace <> 'hdm_backup'::regnamespace and p.prosrc ilike '%hdm_backup%';
  if n > 0 then raise exception 'עצירה: % פונקציות פעילות מפנות לגיבוי', n; end if;
end $$;
drop table hdm_backup.docs_20261009, hdm_backup.docs_before_migration, hdm_backup.counts_before_migration;
drop schema hdm_backup;   -- נכשל (והכול מבוטל) אם נשאר בה משהו
do $$ begin
  if (select md5(string_agg(collection||'|'||id||'|'||data::text, ',' order by collection, id)) from public.docs) <> (select docs_h from pre)
     or (select count(*) from auth.users) <> (select au from pre)
     or (select md5(string_agg(row_to_json(s)::text, ',' order by profile_id)) from public.hdm_subscriptions s) is distinct from (select subs_h from pre)
  then raise exception 'עצירה: נתונים פעילים השתנו'; end if;
end $$;
__FINAL__
