-- =====================================================================
-- חיים דרך מספרים — Staging בלבד: לוח בקרה למנהל (קריאה בלבד של נתונים מצטברים)
-- להרצה פעם אחת, אחרי 01, 03, 04 ו-05, רק בפרויקט Haim Derech Misparim Staging
--
-- 1. hdm_admins — רשימת חשבונות המנהלים (לפי משתמש ההתחברות). סגורה לגמרי לאפליקציה:
--    אין לה כללי RLS, ואין הרשאה לקרוא או לכתוב בה דרך ה-API. מנהל נוסף רק מ-SQL Editor:
--      select public.hdm_admin_grant('<email>');
-- 2. hdm_am_i_admin() — מחזירה רק כן/לא על המשתמש המחובר עצמו (כדי שהדף ידע מה להציג).
-- 3. hdm_admin_dashboard() — כל הנתונים המצטברים. בודקת בשרת שהמשתמש המחובר הוא מנהל,
--    ואחרת נעצרת בשגיאה HDM_NOT_ADMIN. מחזירה מספרים בלבד: בלי שמות, אימיילים, סיסמאות,
--    תאריכי לידה או תוכן שיחות.
--
-- הכנסות: אין עדיין מערכת תשלום, ולכן אין עסקאות מאומתות. הפונקציה מחזירה זאת במפורש
-- (payments.connected = false) ולא מציגה מספר מומצא. מנויים שהוגדרו ידנית / לבדיקה נספרים בנפרד.
--
-- לא מוחק ולא משנה נתונים קיימים. "הכול או כלום".
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא שונה.';
  end if;
  if not exists (select 1 from public.hdm_staging_marker where version = 'staging_secure_v1_fixes3') then
    raise exception 'עצירה: צריך להריץ קודם את 05_staging_profile_hardening.sql. שום דבר לא שונה.';
  end if;
  if exists (select 1 from public.hdm_staging_marker where version = 'staging_admin_dashboard_v1') then
    raise exception 'עצירה: לוח הניהול כבר הותקן. שום דבר לא שונה.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. רשימת המנהלים
-- ---------------------------------------------------------------------
create table public.hdm_admins (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  added_at     timestamptz not null default now(),
  note         text
);
alter table public.hdm_admins enable row level security;   -- בלי policies = סגור לגמרי
revoke all on table public.hdm_admins from public, anon, authenticated;

-- הוספת מנהל — רק מ-SQL Editor (אין הרשאה לאפליקציה)
create function public.hdm_admin_grant(p_email text)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare uid uuid;
begin
  select u.id into uid from auth.users u where lower(u.email) = lower(trim(p_email));
  if uid is null then raise exception 'לא נמצא משתמש התחברות עם האימייל הזה'; end if;
  insert into public.hdm_admins (auth_user_id, note) values (uid, 'נוסף ב-' || now()::date)
  on conflict (auth_user_id) do nothing;
  return '✅ מנהל: ' || p_email;
end $$;
revoke all on function public.hdm_admin_grant(text) from public, anon, authenticated;

create function public.hdm_admin_revoke(p_email text)
returns text language plpgsql volatile security definer set search_path = '' as $$
begin
  delete from public.hdm_admins a using auth.users u
   where u.id = a.auth_user_id and lower(u.email) = lower(trim(p_email));
  return case when found then '✅ ההרשאה הוסרה' else 'לא היה מנהל' end;
end $$;
revoke all on function public.hdm_admin_revoke(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. האם אני מנהל (רק על עצמי)
-- ---------------------------------------------------------------------
create function public.hdm_am_i_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null
     and exists (select 1 from public.hdm_admins a where a.auth_user_id = auth.uid())
$$;
revoke all on function public.hdm_am_i_admin() from public, anon;
grant execute on function public.hdm_am_i_admin() to authenticated;

-- ---------------------------------------------------------------------
-- 3. נתוני הלוח
-- ---------------------------------------------------------------------
create function public.hdm_admin_dashboard()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  tz         constant text := 'Asia/Jerusalem';
  today0     timestamptz := date_trunc('day',   now() at time zone tz) at time zone tz;
  week0      timestamptz := date_trunc('week',  (now() at time zone tz) + interval '1 day') at time zone tz - interval '1 day'; -- שבוע מתחיל ביום ראשון
  month0     timestamptz := date_trunc('month', now() at time zone tz) at time zone tz;
  users      jsonb; subs jsonb; act jsonb; ages jsonb;
begin
  if not public.hdm_am_i_admin() then
    raise exception 'HDM_NOT_ADMIN' using errcode = '42501';
  end if;

  -- בסיס: כל פרופיל רשום, עם המין, תאריך ההצטרפות, הפעילות האחרונה והמסלול בפועל
  drop table if exists pg_temp.hdm_dash_base;
  create temp table hdm_dash_base on commit drop as
  select p.id,
         case when lower(coalesce(p.data->>'gender','')) in ('גבר','זכר','male','m','man') then 'male'
              when lower(coalesce(p.data->>'gender','')) in ('אישה','אשה','נקבה','female','f','woman') then 'female'
              when coalesce(p.data->>'gender','') = '' then 'unknown'
              else 'other' end as gender,
         coalesce(u.created_at,
                  case when (p.data->>'createdAt') ~ '^[0-9]{12,14}$'
                       then to_timestamp((p.data->>'createdAt')::bigint / 1000.0) end) as joined_at,
         greatest(u.last_sign_in_at,
                  (select max(s.updated_at) from auth.sessions s where s.user_id = u.id)) as last_active,
         (a.auth_user_id is not null) as has_login,
         pp.birthdate,
         public.hdm_plan_of(p.id) as plan
    from public.docs p
    left join public.hdm_accounts a on a.profile_id = p.id
    left join auth.users u on u.id = a.auth_user_id
    left join public.hdm_profile_private pp on pp.profile_id = p.id
   where p.collection = 'profiles';

  select jsonb_build_object(
    'total',        count(*),
    'withLogin',    count(*) filter (where has_login),
    'male',         count(*) filter (where gender = 'male'),
    'female',       count(*) filter (where gender = 'female'),
    'other',        count(*) filter (where gender = 'other'),
    'genderUnknown',count(*) filter (where gender = 'unknown'),
    'malePct',      case when count(*) = 0 then 0 else round(100.0 * count(*) filter (where gender = 'male')   / count(*), 1) end,
    'femalePct',    case when count(*) = 0 then 0 else round(100.0 * count(*) filter (where gender = 'female') / count(*), 1) end,
    'newToday',     count(*) filter (where joined_at >= today0),
    'newWeek',      count(*) filter (where joined_at >= week0),
    'newMonth',     count(*) filter (where joined_at >= month0),
    'joinedUnknown',count(*) filter (where joined_at is null),
    'active24h',    count(*) filter (where last_active >= now() - interval '24 hours'),
    'active30d',    count(*) filter (where last_active >= now() - interval '30 days'),
    'activityUnknown', count(*) filter (where last_active is null)
  ) into users from hdm_dash_base;

  select jsonb_object_agg(g, n) into ages from (
    select g, count(*) as n from (
      select case
        when birthdate is null then 'unknown'
        else case
          when a < 18 then 'under18' when a < 25 then '18-24' when a < 35 then '25-34'
          when a < 45 then '35-44'   when a < 55 then '45-54' when a < 65 then '55-64' else '65+' end
        end as g
      from (select birthdate, extract(year from age((now() at time zone tz)::date, birthdate))::int as a from hdm_dash_base) z
    ) y group by g
  ) x;

  select jsonb_build_object(
    'byPlan', (select jsonb_object_agg(pl.plan, (select count(*) from hdm_dash_base b where b.plan = pl.plan)) from public.hdm_plans pl),
    'prices', (select jsonb_object_agg(pl.plan, pl.price_agorot) from public.hdm_plans pl),
    -- משלם = מסלול בתשלום שהגיע ממערכת תשלום (source = payment) ועדיין בתוקף
    'payingActive', (select count(*) from public.hdm_subscriptions s
                      where s.source = 'payment' and s.plan <> 'free' and s.status = 'active'
                        and (s.current_period_end is null or s.current_period_end > now())),
    -- מסלול בתשלום שהוגדר ידנית / לבדיקה (לא הכנסה)
    'manualActive', (select count(*) from public.hdm_subscriptions s
                      where s.source in ('manual','test') and s.plan <> 'free' and s.status in ('active','canceled')
                        and (s.current_period_end is null or s.current_period_end > now())),
    'canceledStillValid', (select count(*) from public.hdm_subscriptions s
                      where s.status = 'canceled' and (s.current_period_end is null or s.current_period_end > now())),
    'expired',      (select count(*) from public.hdm_subscriptions s
                      where s.status = 'expired' or (s.current_period_end is not null and s.current_period_end <= now())),
    'canceled30d',  (select count(*) from public.hdm_subscription_events e where e.action = 'cancel' and e.at >= now() - interval '30 days'),
    'expired30d',   (select count(*) from public.hdm_subscription_events e where e.action = 'expire' and e.at >= now() - interval '30 days'),
    -- MRR רק ממנויים משלמים אמיתיים (כרגע אין)
    'mrrAgorot',    (select coalesce(sum(pl.price_agorot), 0) from public.hdm_subscriptions s join public.hdm_plans pl on pl.plan = s.plan
                      where s.source = 'payment' and s.status = 'active'
                        and (s.current_period_end is null or s.current_period_end > now())),
    'payments', jsonb_build_object(
        'connected', false,
        'verifiedTransactions', 0,
        'revenueAgorot', null,
        'note', 'אין עדיין מערכת תשלום מחוברת — אין עסקאות מאומתות')
  ) into subs;

  select jsonb_build_object(
    'targets',   (select count(*) from public.docs d where d.collection = 'interests'),
    'targets30d',(select count(*) from public.docs d where d.collection = 'interests' and d.updated_at >= now() - interval '30 days'),
    'mutual',    (select count(*) from public.docs i
                   where i.collection = 'interests'
                     and split_part(i.id, '__', 1) < split_part(i.id, '__', 2)
                     and exists (select 1 from public.docs j where j.collection = 'interests'
                                  and j.id = split_part(i.id, '__', 2) || '__' || split_part(i.id, '__', 1))),
    'chats',     (select count(*) from public.docs d where d.collection = 'chats'),
    'chats30d',  (select count(distinct o.pair_id) from public.hdm_chat_openings o where o.opened_at >= now() - interval '30 days'),
    'reports',   (select count(*) from public.docs d where d.collection = 'reports'),
    'reports30d',(select count(*) from public.docs d where d.collection = 'reports' and d.updated_at >= now() - interval '30 days'),
    'blocks',    (select count(*) from public.docs d where d.collection = 'blocks')
  ) into act;

  return jsonb_build_object(
    'generatedAt', now(),
    'timezone', tz,
    'users', users,
    'ages', coalesce(ages, '{}'::jsonb),
    'subscriptions', subs,
    'activity', act,
    'definitions', jsonb_build_object(
      'active', 'כניסה או רענון התחברות (session) בפועל בטווח הזמן',
      'newUsers', 'לפי תאריך יצירת משתמש ההתחברות; לפרופיל ישן בלי משתמש התחברות — לפי createdAt בפרופיל',
      'paying', 'מנוי בתשלום שהגיע ממערכת תשלום (source=payment) ובתוקף'));
end $$;
revoke all on function public.hdm_admin_dashboard() from public, anon;
grant execute on function public.hdm_admin_dashboard() to authenticated;   -- הבדיקה שהמשתמש מנהל נמצאת בתוך הפונקציה

insert into public.hdm_staging_marker (version, note)
values ('staging_admin_dashboard_v1', 'לוח בקרה למנהל: hdm_admins, hdm_am_i_admin, hdm_admin_dashboard');

commit;

select '✅ לוח הניהול הותקן' as "סטטוס",
       (select string_agg(version, ' · ' order by installed_at) from public.hdm_staging_marker) as "מה מותקן";
