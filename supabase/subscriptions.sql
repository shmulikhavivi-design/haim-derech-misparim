-- =====================================================================
-- חיים דרך מספרים — מערכת מנויים, שלב 1 מתוך 3: טבלאות ופונקציות
-- להרצה ב-Supabase: SQL Editor ← New query ← להדביק ← Run (רק אחרי אישור)
--
-- סדר ההתקנה:
--   1. הקובץ הזה          — יוצר טבלאות ופונקציות. לא משנה שום התנהגות באפליקציה.
--   2. subscriptions_test_accounts.sql — מגדיר מסלול פלוס לחשבונות הבדיקה.
--   3. subscriptions_enforce.sql        — מפעיל את האכיפה בשרת (טריגרים).
--   בדיקה: subscriptions_test.sql (רץ בתוך טרנזקציה שמבוטלת — לא נשמר כלום).
--   ביטול: subscriptions_rollback.sql.
--
-- מה זה עושה:
--   * hdm_subscriptions  — מסלול לכל פרופיל: free / basic / plus / vip.
--                          פרופיל בלי שורה כאן, או שהמנוי שלו פג, נחשב free.
--   * hdm_chat_openings  — יומן שיחות חדשות לכל משתמש (לספירת 5 השיחות במסלול בסיסי).
--   * hdm_my_entitlements(profile) — מה שהאפליקציה קוראת: מסלול, מכסה ומה נוצל.
--   * hdm_admin_set_plan(profile, plan) — החלפת מסלול ידנית לבדיקות.
--                          ניתנת להרצה רק מה-SQL Editor, לא מהאפליקציה.
--
-- מה זה לא עושה:
--   * לא מוחק ולא משנה שום נתון קיים בטבלת docs.
--   * לא מפעיל חיובים. אין כאן פרטי תשלום מכל סוג.
--
-- הטבלאות סגורות לגמרי לאפליקציה (RLS בלי policies + ביטול הרשאות).
-- כל הפונקציות SECURITY DEFINER עם search_path ריק ושמות מלאים.
-- =====================================================================

create table if not exists public.hdm_subscriptions (
  profile_id         text primary key,
  plan               text not null check (plan in ('free', 'basic', 'plus', 'vip')),
  status             text not null default 'active' check (status in ('active', 'canceled', 'expired')),
  period_anchor      timestamptz not null default now(),   -- תחילת מחזור החיוב; ממנו נגזר "חודש החיוב"
  current_period_end timestamptz,                           -- NULL = ללא תאריך סיום (בדיקה / ידני)
  source             text not null default 'manual' check (source in ('test', 'manual', 'payment')),
  note               text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table if not exists public.hdm_chat_openings (
  profile_id   text not null,
  pair_id      text not null,            -- מזהה השיחה: <id1>__<id2> ממוין, כמו באפליקציה
  period_start timestamptz,              -- חודש החיוב שבו נפתחה; NULL = שיחה שהייתה קיימת לפני ההתקנה
  opened_at    timestamptz not null default now(),
  primary key (profile_id, pair_id)
);
create index if not exists hdm_chat_openings_period on public.hdm_chat_openings (profile_id, period_start);

alter table public.hdm_subscriptions enable row level security;
alter table public.hdm_chat_openings enable row level security;
revoke all on public.hdm_subscriptions from public, anon, authenticated;
revoke all on public.hdm_chat_openings from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- תחילת חודש החיוב הנוכחי, לפי יום התחלת המנוי (למשל מנוי מה-14 בחודש → כל 14 בחודש)
-- ---------------------------------------------------------------------
create or replace function public.hdm_period_start(anchor timestamptz, at_time timestamptz default now())
returns timestamptz
language plpgsql
stable
set search_path = ''
as $$
declare
  n int;
begin
  if anchor is null then return null; end if;
  if at_time <= anchor then return anchor; end if;
  n := (extract(year from age(at_time, anchor)) * 12 + extract(month from age(at_time, anchor)))::int;
  return anchor + make_interval(months => n);
end;
$$;

-- ---------------------------------------------------------------------
-- המסלול האפקטיבי של פרופיל. מנוי שבוטל ממשיך עד סוף התקופה ששולמה.
-- ---------------------------------------------------------------------
create or replace function public.hdm_plan_of(p_profile text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select s.plan
      from public.hdm_subscriptions s
     where s.profile_id = p_profile
       and s.status in ('active', 'canceled')
       and (s.current_period_end is null or s.current_period_end > now())
  ), 'free');
$$;

-- מכסת שיחות חדשות בחודש: NULL = ללא הגבלה
create or replace function public.hdm_chat_limit(p_plan text)
returns int
language sql
immutable
set search_path = ''
as $$
  select case p_plan when 'free' then 0 when 'basic' then 5 else null end;
$$;

-- כמה שיחות חדשות נפתחו בחודש החיוב הנוכחי
create or replace function public.hdm_chats_used(p_profile text)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int
    from public.hdm_chat_openings o
    join public.hdm_subscriptions s on s.profile_id = o.profile_id
   where o.profile_id = p_profile
     and o.period_start = public.hdm_period_start(s.period_anchor);
$$;

-- ---------------------------------------------------------------------
-- מה שהאפליקציה קוראת. מחזיר רק את המסלול והמכסה של הפרופיל המבוקש.
-- ---------------------------------------------------------------------
create or replace function public.hdm_my_entitlements(p_profile text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_plan  text := public.hdm_plan_of(p_profile);
  v_limit int  := public.hdm_chat_limit(v_plan);
  v_used  int  := 0;
  v_next  timestamptz;
  v_end   timestamptz;
  s       public.hdm_subscriptions%rowtype;
begin
  select * into s from public.hdm_subscriptions where profile_id = p_profile;
  if found then
    v_used := public.hdm_chats_used(p_profile);
    v_next := public.hdm_period_start(s.period_anchor) + interval '1 month';
    v_end  := s.current_period_end;
  end if;
  return jsonb_build_object(
    'installed',   true,
    'plan',        v_plan,
    'chatsLimit',  v_limit,
    'chatsUsed',   v_used,
    'chatsLeft',   case when v_limit is null then null else greatest(v_limit - v_used, 0) end,
    'periodReset', v_next,
    'periodEnd',   v_end,
    'source',      case when found then s.source else null end
  );
end;
$$;

-- ---------------------------------------------------------------------
-- החלפת מסלול ידנית (לבדיקות / למנהל). החלפת מסלול פותחת חודש חיוב חדש.
-- דוגמה: select public.hdm_admin_set_plan('<מזהה פרופיל>', 'basic');
-- ---------------------------------------------------------------------
create or replace function public.hdm_admin_set_plan(p_profile text, p_plan text, p_source text default 'test', p_note text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_plan not in ('free', 'basic', 'plus', 'vip') then
    raise exception 'מסלול לא מוכר: %', p_plan;
  end if;
  if not exists (select 1 from public.docs d where d.collection = 'profiles' and d.id = p_profile) then
    raise exception 'לא נמצא פרופיל עם המזהה %', p_profile;
  end if;
  insert into public.hdm_subscriptions as s (profile_id, plan, status, period_anchor, current_period_end, source, note)
  values (p_profile, p_plan, 'active', now(), null, p_source, p_note)
  on conflict (profile_id) do update
     set plan               = excluded.plan,
         status             = 'active',
         period_anchor      = case when s.plan is distinct from excluded.plan then now() else s.period_anchor end,
         current_period_end = null,
         source             = excluded.source,
         note               = coalesce(excluded.note, s.note),
         updated_at         = now();
  return p_profile || ' → ' || p_plan;
end;
$$;

revoke all on function public.hdm_period_start(timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.hdm_plan_of(text)                          from public, anon, authenticated;
revoke all on function public.hdm_chat_limit(text)                       from public, anon, authenticated;
revoke all on function public.hdm_chats_used(text)                       from public, anon, authenticated;
revoke all on function public.hdm_admin_set_plan(text, text, text, text) from public, anon, authenticated;
revoke all on function public.hdm_my_entitlements(text)                  from public;
grant execute on function public.hdm_my_entitlements(text) to anon, authenticated;
