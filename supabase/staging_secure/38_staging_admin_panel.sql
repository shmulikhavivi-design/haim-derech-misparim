-- =====================================================================
-- חיים דרך מספרים — לוח ניהול למנהלים, גרסה 2 (Staging). אותו גוף כמו Production 20. "הכול או כלום".
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.hdm_staging_marker') is null then raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא שונה.'; end if;
end $$;
-- ---------------------------------------------------------------------
-- 1. מנהלים מורשים (סגור לגמרי ל-API; מוסיפים רק מ-SQL Editor) + משתמשי בדיקה
-- ---------------------------------------------------------------------
create table if not exists public.hdm_admins (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  added_at     timestamptz not null default now(),
  note         text
);
alter table public.hdm_admins enable row level security;
revoke all on table public.hdm_admins from public, anon, authenticated;
-- חשבונות שסומנו ידנית כבדיקה (בנוסף לכלל האוטומטי)
create table if not exists public.hdm_test_accounts (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  added_at     timestamptz not null default now(),
  note         text
);
alter table public.hdm_test_accounts enable row level security;
revoke all on table public.hdm_test_accounts from public, anon, authenticated;

create or replace function public.hdm_admin_grant(p_email text)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare uid uuid;
begin
  select u.id into uid from auth.users u where lower(u.email) = lower(trim(p_email));
  if uid is null then raise exception 'לא נמצא משתמש התחברות עם האימייל הזה'; end if;
  insert into public.hdm_admins (auth_user_id, note) values (uid, 'נוסף ב-' || now()::date) on conflict (auth_user_id) do nothing;
  return '✅ מנהל נוסף';
end $$;
create or replace function public.hdm_admin_revoke(p_email text)
returns text language plpgsql volatile security definer set search_path = '' as $$
begin
  delete from public.hdm_admins a using auth.users u where u.id = a.auth_user_id and lower(u.email) = lower(trim(p_email));
  return case when found then '✅ ההרשאה הוסרה' else 'לא היה מנהל' end;
end $$;
revoke all on function public.hdm_admin_grant(text), public.hdm_admin_revoke(text) from public, anon, authenticated;

create or replace function public.hdm_am_i_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and exists (select 1 from public.hdm_admins a where a.auth_user_id = auth.uid())
$$;
revoke all on function public.hdm_am_i_admin() from public, anon;
grant execute on function public.hdm_am_i_admin() to authenticated;

-- משתמש בדיקה: כתובות בדיקה (example.invalid, כינויי ‎+‎ של תיבת האפליקציה) או שסומן ידנית
create or replace function public.hdm_admin_is_test(p_uid uuid, p_email text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(lower(p_email) like '%@example.invalid', false)
      or coalesce(lower(p_email) like 'life.through.numbers333+%@gmail.com', false)
      or (p_uid is not null and exists (select 1 from public.hdm_test_accounts t where t.auth_user_id = p_uid))
$$;
revoke all on function public.hdm_admin_is_test(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. בסיס משותף (פנימי, לא נגיש לאפליקציה): פרופיל + חשבון + מנוי
-- ---------------------------------------------------------------------
create or replace function public.hdm_admin_base()
returns table (profile_id text, auth_user_id uuid, email text, is_test boolean, name text, gender text, age int,
               city text, occupation text, has_photo boolean, joined_at timestamptz, last_active timestamptz,
               plan text, sub_status text, sub_source text, auto_renew boolean, period_end timestamptz)
language sql stable security definer set search_path = '' as $$
  select p.id, u.id, u.email::text,
         public.hdm_admin_is_test(u.id, u.email),
         nullif(trim(coalesce(p.data->>'currentName', '')), ''),
         case when lower(coalesce(p.data->>'gender','')) in ('גבר','זכר','male','m','man') then 'male'
              when lower(coalesce(p.data->>'gender','')) in ('אישה','אשה','נקבה','female','f','woman') then 'female'
              when coalesce(p.data->>'gender','') = '' then 'unknown' else 'other' end,
         case when pp.birthdate is null then null
              else extract(year from age((now() at time zone 'Asia/Jerusalem')::date, pp.birthdate))::int end,
         nullif(trim(coalesce(p.data->>'location', '')), ''),
         nullif(trim(coalesce(p.data->>'occupation', '')), ''),
         coalesce(p.data->>'photoUrl', p.data->>'photoAssetId', '') <> '',
         coalesce(u.created_at, case when (p.data->>'createdAt') ~ '^[0-9]{12,14}$' then to_timestamp((p.data->>'createdAt')::bigint / 1000.0) end),
         greatest(u.last_sign_in_at, (select max(s.updated_at) from auth.sessions s where s.user_id = u.id)),
         public.hdm_plan_of(p.id),
         s.status, s.source, (to_jsonb(s)->>'auto_renew')::boolean, s.current_period_end
    from public.docs p
    left join public.hdm_accounts a on a.profile_id = p.id
    left join auth.users u on u.id = a.auth_user_id
    left join public.hdm_profile_private pp on pp.profile_id = p.id
    left join public.hdm_subscriptions s on s.profile_id = p.id
   where p.collection = 'profiles'
$$;
revoke all on function public.hdm_admin_base() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. סיכום ללוח (מספרים מצטברים). p_include_tests=false → רק משתמשים אמיתיים
-- ---------------------------------------------------------------------
drop function if exists public.hdm_admin_dashboard();
create or replace function public.hdm_admin_dashboard(p_include_tests boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  tz     constant text := 'Asia/Jerusalem';
  today0 timestamptz := date_trunc('day',   now() at time zone tz) at time zone tz;
  week0  timestamptz := date_trunc('week',  (now() at time zone tz) + interval '1 day') at time zone tz - interval '1 day';  -- ראשון
  month0 timestamptz := date_trunc('month', now() at time zone tz) at time zone tz;
  r jsonb;
begin
  if not public.hdm_am_i_admin() then raise exception 'HDM_NOT_ADMIN' using errcode = '42501'; end if;
  with b as (select * from public.hdm_admin_base() x where p_include_tests or not x.is_test),
       allb as (select * from public.hdm_admin_base()),
       pay as (select p.* from public.hdm_payments p
                where p.outcome = 'approved'
                  and (p_include_tests or not exists (select 1 from allb t where t.profile_id = p.profile_id and t.is_test))),
       orphan as (select u.id, u.email, u.email_confirmed_at from auth.users u
                   where not exists (select 1 from public.hdm_accounts a join public.docs d on d.collection = 'profiles' and d.id = a.profile_id where a.auth_user_id = u.id)
                     and (p_include_tests or not public.hdm_admin_is_test(u.id, u.email)))
  select jsonb_build_object(
    'generatedAt', now(), 'includeTests', p_include_tests,
    'users', jsonb_build_object(
      'total', (select count(*) from b),
      'real', (select count(*) from allb where not is_test), 'test', (select count(*) from allb where is_test),
      'male', (select count(*) from b where gender = 'male'), 'female', (select count(*) from b where gender = 'female'),
      'other', (select count(*) from b where gender = 'other'), 'genderUnknown', (select count(*) from b where gender = 'unknown'),
      'newToday', (select count(*) from b where joined_at >= today0), 'newWeek', (select count(*) from b where joined_at >= week0),
      'newMonth', (select count(*) from b where joined_at >= month0),
      'active24h', (select count(*) from b where last_active >= now() - interval '24 hours'),
      'active30d', (select count(*) from b where last_active >= now() - interval '30 days'),
      'withoutProfile', (select count(*) from orphan where email_confirmed_at is not null),
      'unconfirmed', (select count(*) from orphan where email_confirmed_at is null)),
    'ages', (select jsonb_agg(jsonb_build_object('key', k.key, 'male', (select count(*) from b where gender = 'male' and age between k.lo and k.hi),
                     'female', (select count(*) from b where gender = 'female' and age between k.lo and k.hi),
                     'other', (select count(*) from b where gender in ('other','unknown') and age between k.lo and k.hi),
                     'total', (select count(*) from b where age between k.lo and k.hi)) order by k.lo)
               from (values ('18-24',18,24),('25-34',25,34),('35-44',35,44),('45-54',45,54),('55-64',55,64),('65+',65,200)) k(key, lo, hi)),
    'ageUnknown', (select count(*) from b where age is null),
    'plans', jsonb_build_object(
      'byPlan', (select jsonb_object_agg(pl.plan, (select count(*) from b where b.plan = pl.plan)) from public.hdm_plans pl),
      'prices', (select jsonb_object_agg(pl.plan, pl.price_agorot) from public.hdm_plans pl),
      'payingActive', (select count(*) from b where sub_source = 'payment' and plan <> 'free' and sub_status = 'active'),
      'autoRenewOn', (select count(*) from b where sub_source = 'payment' and sub_status = 'active' and coalesce(auto_renew, false)),
      'canceledStillValid', (select count(*) from b where sub_status = 'canceled' and (period_end is null or period_end > now())),
      'canceledTotal', (select count(*) from b where sub_status = 'canceled'),
      'canceledMonth', (select count(*) from public.hdm_subscription_events e join b on b.profile_id = e.profile_id where e.action = 'cancel' and e.at >= month0),
      'expired', (select count(*) from b where sub_status = 'expired'),
      'manualOrTest', (select count(*) from b where sub_source in ('manual','test') and plan <> 'free'),
      'mrrAgorot', (select coalesce(sum(pl.price_agorot), 0) from b join public.hdm_plans pl on pl.plan = b.plan
                     where b.sub_source = 'payment' and b.sub_status = 'active' and coalesce(b.auto_renew, false))),
    'revenue', jsonb_build_object(
      'note', 'רק תשלומים שאושרו בפועל (outcome=approved), בשקלים כולל מע"מ',
      'totalAgorot', (select coalesce(sum(amount_agorot), 0) from pay), 'count', (select count(*) from pay),
      'todayAgorot', (select coalesce(sum(amount_agorot), 0) from pay where received_at >= today0),
      'weekAgorot', (select coalesce(sum(amount_agorot), 0) from pay where received_at >= week0),
      'monthAgorot', (select coalesce(sum(amount_agorot), 0) from pay where received_at >= month0),
      'byKind', (select coalesce(jsonb_object_agg(kind, s), '{}') from (select kind, sum(amount_agorot) s from pay group by kind) z),
      'needsReview', (select count(*) from public.hdm_payments where needs_review),
      'lastPaymentAt', (select max(received_at) from pay)),
    'payments', jsonb_build_object(
      'approved', (select count(*) from pay),
      'failed', (select count(*) from public.hdm_payments p where p.outcome = 'failed' and (p_include_tests or not exists (select 1 from allb t where t.profile_id = p.profile_id and t.is_test))),
      'needsReview', (select count(*) from public.hdm_payments where needs_review),
      'checkoutsPending', (select count(*) from public.hdm_checkouts where status = 'pending'),
      'checkoutsFailed30d', (select count(*) from public.hdm_checkouts where status = 'failed' and created_at >= now() - interval '30 days'),
      'renewals', (select coalesce(jsonb_object_agg(status, n), '{}') from (select status, count(*) n from public.hdm_renewal_charges group by status) z),
      'nextRenewalAt', (select min(period_end) from b where sub_source = 'payment' and sub_status = 'active' and coalesce(auto_renew, false)),
      'renewalsNext7d', (select count(*) from b where sub_source = 'payment' and sub_status = 'active' and coalesce(auto_renew, false) and period_end <= now() + interval '7 days'),
      'lastPaymentAt', (select max(received_at) from pay)),
    'activity', jsonb_build_object(
      'targets30d', (select count(*) from public.docs d where d.collection = 'interests' and d.updated_at >= now() - interval '30 days'),
      'chats30d', (select count(distinct o.pair_id) from public.hdm_chat_openings o where o.opened_at >= now() - interval '30 days'),
      'reports30d', (select count(*) from public.docs d where d.collection = 'reports' and d.updated_at >= now() - interval '30 days')),
    'onlineNow', (select count(distinct a.profile_id) from public.hdm_accounts a join auth.sessions s on s.user_id = a.auth_user_id
                   join b on b.profile_id = a.profile_id
                  where greatest(s.created_at, s.updated_at, (to_jsonb(s)->>'refreshed_at')::timestamp at time zone 'UTC') >= now() - interval '60 minutes'
                    and coalesce((to_jsonb(s)->>'not_after')::timestamptz, 'infinity') > now())
  ) into r;
  return r;
end $$;
revoke all on function public.hdm_admin_dashboard(boolean) from public, anon;
grant execute on function public.hdm_admin_dashboard(boolean) to authenticated;   -- ההרשאה נבדקת בתוך הפונקציה

-- ---------------------------------------------------------------------
-- 4. רשימת משתמשים (למנהלים בלבד) — סינון לפי חיפוש, מין, גיל, מסלול; עד 200 בעמוד
-- ---------------------------------------------------------------------
create or replace function public.hdm_admin_users(p_search text default null, p_gender text default null, p_min_age int default null,
  p_max_age int default null, p_plan text default null, p_include_tests boolean default false, p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r jsonb; q text := nullif(lower(trim(coalesce(p_search, ''))), '');
begin
  if not public.hdm_am_i_admin() then raise exception 'HDM_NOT_ADMIN' using errcode = '42501'; end if;
  with f as (
    select * from public.hdm_admin_base() x
     where (p_include_tests or not x.is_test)
       and (p_gender is null or p_gender = '' or x.gender = p_gender)
       and (p_min_age is null or x.age >= p_min_age) and (p_max_age is null or x.age <= p_max_age)
       and (p_plan is null or p_plan = '' or x.plan = p_plan)
       and (q is null or lower(coalesce(x.name, '')) like '%' || q || '%' or lower(coalesce(x.email, '')) like '%' || q || '%'
            or lower(coalesce(x.city, '')) like '%' || q || '%'))
  select jsonb_build_object('total', (select count(*) from f),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', profile_id, 'name', name, 'email', email, 'gender', gender, 'age', age, 'city', city,
               'occupation', occupation, 'photo', has_photo, 'joined', joined_at, 'lastActive', last_active, 'plan', plan,
               'subStatus', sub_status, 'autoRenew', auto_renew, 'periodEnd', period_end, 'test', is_test) order by joined_at desc nulls last)
       from (select * from f order by joined_at desc nulls last limit least(greatest(coalesce(p_limit, 50), 1), 200) offset greatest(coalesce(p_offset, 0), 0)) z), '[]'::jsonb))
  into r;
  return r;
end $$;
revoke all on function public.hdm_admin_users(text, text, int, int, text, boolean, int, int) from public, anon;
grant execute on function public.hdm_admin_users(text, text, int, int, text, boolean, int, int) to authenticated;
insert into public.hdm_staging_marker (version, note) values ('staging_admin_panel_v2', 'לוח ניהול למנהלים — גרסה 2');
commit;
