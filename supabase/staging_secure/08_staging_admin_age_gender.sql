-- =====================================================================
-- חיים דרך מספרים — Staging בלבד: לוח הניהול — פילוח לפי גיל ומין
-- להרצה פעם אחת, אחרי 06_staging_admin_dashboard.sql, רק בפרויקט Haim Derech Misparim Staging.
--
-- hdm_admin_age_gender() — לכל טווח גיל (18–24, 25–34, 35–44, 45–54, 55–64, 65+): גברים, נשים,
-- אחר/לא צוין וסך הכול. הגיל מחושב בשרת מתאריך הלידה הקיים (hdm_profile_private), לפי שעון ישראל.
-- בודקת בשרת שהמשתמש המחובר הוא מנהל (אחרת HDM_NOT_ADMIN). מחזירה מספרים בלבד:
-- בלי שמות, אימיילים, מזהים או תאריכי לידה.
--
-- לא מוחק ולא משנה נתונים קיימים, ולא משנה את hdm_admin_dashboard. "הכול או כלום".
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא שונה.';
  end if;
  if not exists (select 1 from public.hdm_staging_marker where version = 'staging_admin_dashboard_v1') then
    raise exception 'עצירה: צריך להתקין קודם את 06_staging_admin_dashboard.sql. שום דבר לא שונה.';
  end if;
  if exists (select 1 from public.hdm_staging_marker where version = 'staging_admin_age_gender_v1') then
    raise exception 'עצירה: פילוח הגיל והמין כבר הותקן. שום דבר לא שונה.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- פילוח משתמשים לפי טווחי גיל ומין — מספרים מצטברים בלבד
-- ---------------------------------------------------------------------
create function public.hdm_admin_age_gender()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  tz constant text := 'Asia/Jerusalem';
  today date := (now() at time zone tz)::date;
  res jsonb;
begin
  if not public.hdm_am_i_admin() then
    raise exception 'HDM_NOT_ADMIN' using errcode = '42501';
  end if;

  with base as (
    select case when lower(coalesce(p.data->>'gender','')) in ('גבר','זכר','male','m','man') then 'male'
                when lower(coalesce(p.data->>'gender','')) in ('אישה','אשה','נקבה','female','f','woman') then 'female'
                when coalesce(p.data->>'gender','') = '' then 'unknown'
                else 'other' end as g,
           case when pp.birthdate is null then null
                else extract(year from age(today, pp.birthdate))::int end as a
      from public.docs p
      left join public.hdm_profile_private pp on pp.profile_id = p.id
     where p.collection = 'profiles'
  ), tagged as (
    select g, case when a is null then 'noBirthdate' when a < 18 then 'under18'
                   when a < 25 then '18-24' when a < 35 then '25-34' when a < 45 then '35-44'
                   when a < 55 then '45-54' when a < 65 then '55-64' else '65+' end as b
      from base
  ), buckets(b, ord) as (
    values ('18-24',1),('25-34',2),('35-44',3),('45-54',4),('55-64',5),('65+',6)
  )
  select jsonb_build_object(
    'generatedAt', now(),
    'buckets', (select jsonb_agg(jsonb_build_object(
                   'key', k.b,
                   'male',    (select count(*) from tagged t where t.b = k.b and t.g = 'male'),
                   'female',  (select count(*) from tagged t where t.b = k.b and t.g = 'female'),
                   'other',   (select count(*) from tagged t where t.b = k.b and t.g in ('other','unknown')),
                   'total',   (select count(*) from tagged t where t.b = k.b)) order by k.ord)
                  from buckets k),
    'outside', jsonb_build_object(
                   'under18',     (select count(*) from tagged where b = 'under18'),
                   'noBirthdate', (select count(*) from tagged where b = 'noBirthdate')),
    'totalProfiles', (select count(*) from tagged))
  into res;
  return res;
end $$;
revoke all on function public.hdm_admin_age_gender() from public, anon;
grant execute on function public.hdm_admin_age_gender() to authenticated;   -- הבדיקה שהמשתמש מנהל נמצאת בתוך הפונקציה

insert into public.hdm_staging_marker (version, note)
values ('staging_admin_age_gender_v1', 'לוח ניהול: פילוח לפי טווחי גיל ומין (hdm_admin_age_gender)');

commit;

select '✅ פילוח הגיל והמין הותקן' as "סטטוס";
