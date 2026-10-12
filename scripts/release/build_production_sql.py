#!/usr/bin/env python3
# =====================================================================
# בונה את קובץ המעבר ל-Production מתוך קובצי Staging שנבדקו (01 + 03 + 04 + 05),
# כך ששתי הסביבות מריצות בדיוק את אותו קוד שרת. אין להריץ את הקובץ שנוצר בלי אישור.
#   python3 scripts/release/build_production_sql.py  →  supabase/production/01_production_migration.sql
# =====================================================================
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / 'supabase' / 'staging_secure'
OUT = ROOT / 'supabase' / 'production' / '01_production_migration.sql'
s01 = (SRC / '01_staging_setup.sql').read_text(encoding='utf-8')
s03 = (SRC / '03_staging_fixes.sql').read_text(encoding='utf-8')
s04 = (SRC / '04_staging_profile_id_fix.sql').read_text(encoding='utf-8')
s05 = (SRC / '05_staging_profile_hardening.sql').read_text(encoding='utf-8')

def between(text, start, end, incl_start=True):
    i = text.index(start); j = text.index(end, i + len(start))
    return text[i if incl_start else i + len(start):j]

# ---- 01: טבלאות + פונקציות עזר + פונקציות הכתיבה (עד הטריגר), בלי יצירת docs ובלי הגנת Staging ----
part_tables = between(s01, '-- ---------------------------------------------------------------------\n-- 1. טבלאות', 'create trigger hdm_docs_guard')
part_tables = re.sub(r'create table public\.docs \(.*?\);\n', '-- (טבלת docs כבר קיימת ב-Production — לא נוצרת מחדש)\n', part_tables, count=1, flags=re.S)
OLD_RE = "check (profile_id ~ '^[A-Za-z0-9_-]{3,64}$' and position('__' in profile_id) = 0)"
assert OLD_RE in part_tables
part_tables = part_tables.replace(OLD_RE, "check (profile_id ~ '^[A-Za-z0-9-][A-Za-z0-9_-]{1,62}[A-Za-z0-9-]$' and position('__' in profile_id) = 0)")
# ---- 01: מהטריגר ועד ההרשאות (RLS, פונקציות שרת, ניהול מנויים, הרשאות) ----
part_rest = between(s01, 'create trigger hdm_docs_guard', '\ndo $$\nbegin\n  if exists (select 1 from pg_publication')
# ---- 03: כללי RLS נוספים ----
part_03 = between(s03, '-- ---------------------------------------------------------------------\n-- תיקון 2', 'insert into public.hdm_staging_marker')
# ---- 05: ניקוי פרופיל + מחיקת חשבון מלאה ----
part_05 = between(s05, '-- ---------------------------------------------------------------------\n-- 1. ניקוי הפרופיל', 'insert into public.hdm_staging_marker')
# רשימת השדות המותרים בפרופיל — אותה רשימה כמו ב-05
allowed = re.search(r"allowed constant jsonb := '(\{.*?\})';", part_05, re.S).group(1)

HEADER = r"""-- =====================================================================
-- חיים דרך מספרים — מעבר Production לשרת המאובטח (נוצר אוטומטית מ-scripts/release/build_production_sql.py)
--
-- ⚠️ להרצה רק בפרויקט הפעיל Haim Derech Misparim, רק אחרי אישור, ורק לפי docs/release-runbook.md
--    (המעבר מתבצע יחד עם פרסום index.html החדש — לפני כן האפליקציה הישנה תפסיק לעבוד).
--
-- מה הקובץ עושה, "הכול או כלום" (שגיאה אחת = שום דבר לא נשמר):
--   1. גיבוי מלא של טבלת docs ושל טבלאות hdm_* הקיימות לסכימה hdm_backup (באותו מסד, לא נמחק כלום).
--   2. מסיר את כללי הגישה הפתוחים, הטריגרים והפונקציות הישנות (הגבלת גיל, מנויים מ-PR #9 אם הותקנו).
--   3. מתקין את אותו שרת שנבדק ב-Staging: טבלאות, RLS, פונקציות שרת, מסלולים ומחירים, הקשחות 03/04/05.
--   4. מעביר נתונים קיימים בלי למחוק אותם:
--      * תאריך לידה, שם מלידה ומספרים — מהפרופיל הגלוי לטבלה הסגורה hdm_profile_private
--      * likes ישנים בפרופיל → רשומות 🎯 (interests)
--      * שיחות והתאמות קיימות → נרשמות כ"קיימות" ולא נספרות במכסה
--      * חשבונות קיימים (data/users) → hdm_legacy_accounts (אימייל ↔ פרופיל, בלי הסיסמאות הישנות),
--        ולמי שאין לו משתמש ב-Supabase Auth נוצר משתמש עם סיסמה אקראית — הכניסה הראשונה דרך "שכחתי סיסמה".
--      * מנויים קיימים (אם הותקנו מ-PR #9) → מועתקים לטבלת המנויים החדשה
--   5. פרטי ההתחברות הישנים (data/users, authSessions) לא נמחקים — רק נחסמים לגישה מהאפליקציה.
--
-- חשבון קיים מתחבר לפרופיל שלו רק אחרי הוכחת בעלות על המייל (קישור "שכחתי סיסמה" או קוד במייל).
-- ביטול: 99_production_rollback.sql
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. הגנות
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.hdm_staging_marker') is not null then
    raise exception 'עצירה: זה פרויקט הניסוי (Staging). הקובץ הזה מיועד ל-Production בלבד. שום דבר לא שונה.';
  end if;
  if to_regclass('public.docs') is null then
    raise exception 'עצירה: אין טבלת docs. זה לא הפרויקט של האפליקציה. שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_release_marker') is not null or to_regnamespace('hdm_backup') is not null then
    raise exception 'עצירה: המעבר כבר בוצע (או שקיים גיבוי קודם). שום דבר לא שונה.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 0א. גיבוי מלא (באותו מסד, סכימה סגורה)
-- ---------------------------------------------------------------------
create schema hdm_backup;
revoke all on schema hdm_backup from public, anon, authenticated;
create table hdm_backup.docs_before_migration as table public.docs;
create table hdm_backup.counts_before_migration as
  select collection, count(*) as n from public.docs group by collection;

-- טבלאות hdm_* קיימות (למשל מנויים מ-PR #9) עוברות לגיבוי, עם הנתונים שלהן
do $$
declare r record;
begin
  for r in select c.relname from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relname like 'hdm\_%' loop
    execute format('alter table public.%I set schema hdm_backup', r.relname);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 0ב. הסרת כללי הגישה, הטריגרים והפונקציות הישנים (קוד בלבד — הנתונים כבר בגיבוי)
-- ---------------------------------------------------------------------
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
end $$;
alter table public.docs add column if not exists updated_at timestamptz default now();

create table public.hdm_release_marker (
  version      text primary key,
  installed_at timestamptz not null default now(),
  note         text
);
insert into public.hdm_release_marker (version, note) values ('production_secure_v1', 'מעבר לשרת המאובטח (01+03+04+05)');

"""

DATA_MIGRATION = r"""
-- =====================================================================
-- העברת נתונים קיימים (לפני הפעלת הטריגרים — כדי שפרופילים ישנים בלי תאריך לידה לא ייחסמו)
-- =====================================================================
create function public.hdm_try_date(t text)
returns date language plpgsql immutable set search_path = '' as $$
begin
  if t is null or btrim(t) !~ '^\d{4}-\d{2}-\d{2}$' then return null; end if;
  return btrim(t)::date;
exception when others then return null;
end $$;

-- 🎯 ישנים מתוך רשימת likes בפרופיל
insert into public.docs (collection, id, data)
select 'interests', d.id || '__' || t, jsonb_build_object('from', d.id, 'to', t, 'ts', 0)
  from public.docs d,
       jsonb_array_elements_text(case when jsonb_typeof(d.data->'likes') = 'array' then d.data->'likes' else '[]'::jsonb end) t
 where d.collection = 'profiles' and t <> d.id and position('__' in t) = 0
   and exists (select 1 from public.docs p where p.collection = 'profiles' and p.id = t)
on conflict (collection, id) do nothing;

-- 🎯 קיימים: השדות from / to נקבעים לפי המזהה (המקור האמין)
update public.docs set data = jsonb_build_object('from', split_part(id, '__', 1), 'to', split_part(id, '__', 2), 'ts', coalesce(data->'ts', '0'::jsonb))
 where collection = 'interests' and split_part(id, '__', 3) = '' and split_part(id, '__', 2) <> '';

-- פרטי לידה ומספרים → הטבלה הסגורה
insert into public.hdm_profile_private
  (profile_id, birthdate, birth_first_name, birth_last_name, life_path, birthday_number, vowel_number, consonants_number, expression_number, age_blocked)
select x.id, x.b, x.fn, x.ln,
       public.hdm_life_path(x.b), public.hdm_birthday_number(x.b),
       public.hdm_name_number(coalesce(x.fn, '') || coalesce(x.ln, ''), 'vowels'),
       public.hdm_name_number(coalesce(x.fn, '') || coalesce(x.ln, ''), 'consonants'),
       public.hdm_name_number(coalesce(x.fn, '') || coalesce(x.ln, ''), 'all'),
       x.blocked or (x.b is not null and public.hdm_age_years(x.b) < 18)
  from (select d.id, public.hdm_try_date(d.data->>'birthdate') as b,
               nullif(btrim(coalesce(d.data->>'birthFirstName', '')), '') as fn,
               nullif(btrim(coalesce(d.data->>'birthLastName', '')), '') as ln,
               coalesce(d.data->>'ageBlocked', '') = 'true' as blocked
          from public.docs d where d.collection = 'profiles') x;

-- הפרופיל הגלוי: רק השדות המותרים (כמו ב-05), גיל ומספר דרך חיים מחושבים בשרת, likes ריק
update public.docs d set data =
  coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(d.data) e
             where e.key in (select jsonb_object_keys('__ALLOWED__'::jsonb))
               and e.key not in ('age', 'lifePathNumber', 'likes', 'ageBlocked')), '{}'::jsonb)
  || jsonb_strip_nulls(jsonb_build_object(
       'age', case when pp.birthdate is not null then public.hdm_age_years(pp.birthdate)::text end,
       'lifePathNumber', pp.life_path,
       'ageBlocked', case when pp.age_blocked then true end))
  || '{"likes": []}'::jsonb,
  updated_at = now()
  from public.hdm_profile_private pp
 where d.collection = 'profiles' and pp.profile_id = d.id;

-- שיחות והתאמות קיימות: לא נספרות במכסת החודש
insert into public.hdm_chat_openings (profile_id, pair_id, plan, opened_at)
select u, d.id, 'legacy', timestamptz '2000-01-01'
  from public.docs d, unnest(array[split_part(d.id, '__', 1), split_part(d.id, '__', 2)]) u
 where d.collection in ('matches', 'chats') and split_part(d.id, '__', 3) = '' and u <> ''
on conflict (profile_id, pair_id) do nothing;

-- חשבונות קיימים: אימייל ↔ פרופיל (בלי הסיסמאות הישנות)
create table public.hdm_legacy_accounts (
  email       text primary key,
  profile_id  text not null unique,
  imported_at timestamptz not null default now(),
  linked_at   timestamptz
);
alter table public.hdm_legacy_accounts enable row level security;
insert into public.hdm_legacy_accounts (email, profile_id)
select distinct on (lower(btrim(d.data->>'email'))) lower(btrim(d.data->>'email')), d.data->>'profileId'
  from public.docs d
 where d.collection like 'data/users/%' and coalesce(d.data->>'email', '') like '%@%' and coalesce(d.data->>'profileId', '') <> ''
   and exists (select 1 from public.docs p where p.collection = 'profiles' and p.id = d.data->>'profileId')
 order by lower(btrim(d.data->>'email')), coalesce((d.data->>'createdAt')::numeric, 0) desc
on conflict do nothing;

-- משתמש התחברות למי שעוד אין לו (סיסמה אקראית שאיש לא יודע — הכניסה הראשונה דרך "שכחתי סיסמה")
do $$
declare
  r record; uid uuid; cr text;
begin
  cr := case when exists (select 1 from pg_proc where proname = 'crypt' and pronamespace = to_regnamespace('extensions')) then 'extensions.' else 'public.' end;
  for r in select l.email from public.hdm_legacy_accounts l
            where not exists (select 1 from auth.users u where lower(u.email) = l.email) loop
    uid := gen_random_uuid();
    execute format($f$
      insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                              raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                              confirmation_token, recovery_token, email_change_token_new, email_change)
      values ('00000000-0000-0000-0000-000000000000', %L, 'authenticated', 'authenticated', %L,
              %scrypt(gen_random_uuid()::text, %sgen_salt('bf')), now(),
              '{"provider":"email","providers":["email"],"hdm_migrated":true}', '{}', now(), now(), '', '', '', '')$f$,
      uid, r.email, cr, cr);
    insert into auth.identities (id, provider_id, user_id, identity_data, provider, created_at, updated_at)
    values (gen_random_uuid(), uid::text, uid, jsonb_build_object('sub', uid::text, 'email', r.email, 'email_verified', true), 'email', now(), now());
  end loop;
end $$;
"""

AFTER = r"""
-- =====================================================================
-- 03: כללי RLS נוספים (דיווחים, פרטיות חסימות)
-- =====================================================================
__P03__
-- =====================================================================
-- 05: ניקוי פרופיל + מחיקת חשבון מלאה
-- =====================================================================
__P05__
-- =====================================================================
-- קישור משתמש Auth לפרופיל — כולל חשבונות קיימים (רק אחרי הוכחת בעלות על המייל)
-- =====================================================================
create or replace function public.hdm_claim_profile(p_proposed text default null)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  v   text;
  lp  text;
  amr jsonb := coalesce(auth.jwt()->'amr', '[]'::jsonb);
begin
  if uid is null then
    raise exception 'HDM_NOT_SIGNED_IN' using errcode = 'P0001', hint = 'נדרשת התחברות.';
  end if;
  select profile_id into v from public.hdm_accounts where auth_user_id = uid;
  if v is not null then return v; end if;

  -- חשבון קיים מהגרסה הקודמת: מקשרים רק אחרי שהמשתמש הוכיח בעלות על המייל (קישור / קוד שנשלח למייל)
  select l.profile_id into lp
    from public.hdm_legacy_accounts l join auth.users u on lower(u.email) = l.email
   where u.id = uid and not exists (select 1 from public.hdm_accounts a where a.profile_id = l.profile_id)
   limit 1;
  if lp is not null then
    if not exists (select 1 from jsonb_array_elements(case when jsonb_typeof(amr) = 'array' then amr else '[]'::jsonb end) x
                    where x->>'method' in ('recovery', 'otp', 'magiclink', 'email/signup', 'invite')) then
      raise exception 'HDM_LEGACY_VERIFY_EMAIL' using errcode = 'P0001',
        hint = 'כדי לחבר את החשבון הקיים, השתמשו פעם אחת ב"שכחתי סיסמה" והגדירו סיסמה מהקישור במייל.';
    end if;
    insert into public.hdm_accounts (auth_user_id, profile_id) values (uid, lp);
    update public.hdm_legacy_accounts set linked_at = now() where profile_id = lp;
    return lp;
  end if;

  if p_proposed is not null then
    if p_proposed !~ '^[A-Za-z0-9-][A-Za-z0-9_-]{1,62}[A-Za-z0-9-]$' or position('__' in p_proposed) > 0
       or exists (select 1 from public.hdm_accounts where profile_id = p_proposed)
       or exists (select 1 from public.hdm_legacy_accounts where profile_id = p_proposed)
       or exists (select 1 from public.docs where collection = 'profiles' and id = p_proposed)
       or exists (select 1 from public.hdm_profile_private where profile_id = p_proposed) then
      raise exception 'HDM_PROFILE_ID_TAKEN' using errcode = 'P0001', hint = 'מזהה הפרופיל אינו זמין.';
    end if;
    v := p_proposed;
  else
    v := 'p_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 20);
  end if;
  insert into public.hdm_accounts (auth_user_id, profile_id) values (uid, v);
  return v;
end $$;
revoke all on function public.hdm_claim_profile(text) from public, anon;
grant execute on function public.hdm_claim_profile(text) to authenticated;
revoke all on function public.hdm_try_date(text) from public, anon, authenticated;
revoke all on public.hdm_legacy_accounts, public.hdm_release_marker from public, anon, authenticated;

-- מנויים קיימים (אם PR #9 הותקן): מועתקים לטבלה החדשה, לפי אותם מסלולים
do $$
begin
  if to_regclass('hdm_backup.hdm_subscriptions') is not null then
    execute $q$
      insert into public.hdm_subscriptions (profile_id, plan, status, period_anchor, current_period_end, source, note)
      select s.profile_id, s.plan, s.status, s.period_anchor, s.current_period_end,
             case when s.source in ('test', 'manual', 'payment') then s.source else 'manual' end, s.note
        from hdm_backup.hdm_subscriptions s
       where s.plan in (select plan from public.hdm_plans)
         and exists (select 1 from public.docs d where d.collection = 'profiles' and d.id = s.profile_id)
      on conflict (profile_id) do nothing $q$;
  end if;
end $$;

-- עדכונים חיים (Realtime) — docs כבר רשומה ב-Production ברוב המקרים
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'docs') then
    alter publication supabase_realtime add table public.docs;
  end if;
end $$;

-- בדיקות אחרי המעבר — אם משהו לא תקין, הכול מתבטל
do $$
declare bad int;
begin
  if (select count(*) from public.docs where collection = 'profiles')
     <> (select n from hdm_backup.counts_before_migration where collection = 'profiles') then
    raise exception 'עצירה: מספר הפרופילים השתנה במעבר. שום דבר לא נשמר.';
  end if;
  if exists (select 1 from hdm_backup.counts_before_migration c
              where c.collection not in ('interests')
                and c.n <> (select count(*) from public.docs d where d.collection = c.collection)) then
    raise exception 'עצירה: מספר הרשומות באחד האוספים השתנה במעבר. שום דבר לא נשמר.';
  end if;
  select count(*) into bad from public.docs
   where collection = 'profiles' and data ?| array['birthdate','birthFirstName','birthLastName','vowelNumber','consonantsNumber','expressionNumber','birthdayNumber'];
  if bad > 0 then raise exception 'עצירה: נשארו פרטי לידה בפרופיל הגלוי. שום דבר לא נשמר.'; end if;
  if (select count(*) from public.hdm_profile_private) <> (select count(*) from public.docs where collection = 'profiles') then
    raise exception 'עצירה: לא לכל פרופיל נוצרה רשומה פרטית. שום דבר לא נשמר.';
  end if;
end $$;

commit;

select '✅ המעבר הושלם (production_secure_v1)' as "סטטוס",
       (select count(*) from public.docs where collection = 'profiles') as "פרופילים",
       (select count(*) from public.hdm_profile_private where birthdate is null) as "בלי תאריך לידה",
       (select count(*) from public.hdm_legacy_accounts) as "חשבונות קיימים לקישור",
       (select count(*) from public.hdm_chat_openings where plan = 'legacy') as "שיחות קיימות (לא במכסה)",
       (select count(*) from public.hdm_subscriptions) as "מנויים",
       (select count(*) from pg_policies where schemaname = 'public') as "כללי RLS";
"""

sql = (HEADER
       + part_tables
       + DATA_MIGRATION
       + part_rest
       + AFTER.replace('__P03__', part_03).replace('__P05__', part_05))
sql = sql.replace("'__ALLOWED__'", "'" + allowed + "'")
MARK = 'alter table public.hdm_staging_marker      enable row level security;'
assert sql.count(MARK) == 1
sql = sql.replace(MARK, 'alter table public.hdm_release_marker      enable row level security;')
rest = sql.replace("to_regclass('public.hdm_staging_marker')", '')
assert 'hdm_staging_marker' not in rest, 'נשאר אזכור ל-hdm_staging_marker'
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(sql, encoding='utf-8')
print(f'נוצר {OUT.relative_to(ROOT)} ({len(sql.splitlines())} שורות)')
