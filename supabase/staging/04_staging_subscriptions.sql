-- =====================================================================
-- סביבת בדיקות (Staging) — שלב 4: מערכת המנויים מ-PR #9
-- ⚠️ רק בפרויקט Haim Derech Misparim Staging. בפרויקט האמיתי הקובץ נעצר בשורה הראשונה.
-- הקובץ נוצר אוטומטית מ-scripts/build_staging_sql.py — לא לערוך ידנית.
-- subscriptions.sql ואחריו subscriptions_enforce.sql, ברצף אחד.
-- =====================================================================

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט ה-Staging. שום דבר לא הורץ ולא שונה. בדקו בראש המסך שנבחר הפרויקט Haim Derech Misparim Staging.';
  end if;
end $$;

begin;

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

-- =====================================================================
-- חיים דרך מספרים — מערכת מנויים, שלב 3 מתוך 3: אכיפה בשרת
-- להרצה רק אחרי subscriptions.sql ו-subscriptions_test_accounts.sql.
--
-- מרגע ההרצה, כל כתיבה לטבלת docs נבדקת במסד עצמו — גם אם מישהו עוקף את האפליקציה
-- ופונה ישירות ל-API:
--   * 🎯 חדש (interests, או הוספה לרשימת likes בפרופיל) — נדחה אם המסלול של השולח הוא free.
--   * שיחה חדשה (matches / chats) — נדחית אם אחד הצדדים במסלול free, או שהוא במסלול basic
--     וכבר פתח 5 שיחות חדשות בחודש החיוב הנוכחי. כל צד במסלול basic מנצל שיחה אחת.
--   * הודעה חדשה בשיחה — נדחית אם לשולח אין מנוי פעיל (free).
--
-- שיחות והתאמות שקיימות לפני ההרצה נרשמות כ"קיימות" ולא נספרות במכסה.
--
-- מה זה לא עושה:
--   * לא מוחק ולא משנה שום נתון קיים. הודעות קיימות לא נוגעות.
--   * לא נוגע בחסימות, דיווחים, סימוני קריאה, פרופילים (מלבד בדיקת likes חדשים) או בהתחברות.
--
-- מגבלה ידועה (תיסגר בשלב אבטחת docs): הבדיקה מתבססת על מזהה הפרופיל שרשום בנתונים.
-- מי שמתחזה לפרופיל אחר דרך ה-API עדיין לא נחסם כאן — זה הפער הקיים בטבלת docs.
-- =====================================================================

-- ---------------------------------------------------------------------
-- שיחות והתאמות שכבר קיימות: נרשמות פעם אחת, בלי מכסה (period_start = NULL).
-- אפשר להריץ שוב בלי נזק.
-- ---------------------------------------------------------------------
insert into public.hdm_chat_openings (profile_id, pair_id, period_start)
select p.profile_id, d.id, null
  from public.docs d
  cross join lateral unnest(array[split_part(d.id, '__', 1), split_part(d.id, '__', 2)]) as p(profile_id)
 where d.collection in ('matches', 'chats')
   and d.id like '%\_\_%'
   and split_part(d.id, '__', 1) <> ''
   and split_part(d.id, '__', 2) <> ''
   and split_part(d.id, '__', 3) = ''
on conflict (profile_id, pair_id) do nothing;

-- ---------------------------------------------------------------------
-- פתיחת שיחה חדשה בין שני משתמשים: בדיקת מסלול ומכסה לכל צד, ורישום ביומן.
-- ---------------------------------------------------------------------
create or replace function public.hdm_open_pair(p_pair text, p_users text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  u      text;
  v_plan text;
  v_lim  int;
  v_ps   timestamptz;
begin
  foreach u in array p_users loop
    continue when u is null or u = '';
    -- נעילה קצרה לכל משתמש, כדי ששתי שיחות במקביל לא יעברו יחד את המכסה
    perform pg_advisory_xact_lock(hashtext('hdm_open_pair:' || u));
    -- שיחה שכבר נרשמה למשתמש הזה (כולל שיחות שהיו קיימות) — לא נספרת שוב
    continue when exists (select 1 from public.hdm_chat_openings o where o.profile_id = u and o.pair_id = p_pair);

    v_plan := public.hdm_plan_of(u);
    if v_plan = 'free' then
      raise exception 'HDM_PLAN_REQUIRED' using errcode = 'P0001',
        hint = 'פתיחת שיחות זמינה מהמסלול הבסיסי ומעלה.';
    end if;

    v_lim := public.hdm_chat_limit(v_plan);
    if v_lim is not null and public.hdm_chats_used(u) >= v_lim then
      raise exception 'HDM_CHAT_LIMIT' using errcode = 'P0001',
        hint = 'נוצלו כל השיחות החדשות לחודש החיוב הנוכחי.';
    end if;

    select public.hdm_period_start(s.period_anchor) into v_ps
      from public.hdm_subscriptions s where s.profile_id = u;
    insert into public.hdm_chat_openings (profile_id, pair_id, period_start)
    values (u, p_pair, coalesce(v_ps, now()))
    on conflict (profile_id, pair_id) do nothing;
  end loop;
end;
$$;
revoke all on function public.hdm_open_pair(text, text[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- הטריגר על טבלת docs
-- ---------------------------------------------------------------------
create or replace function public.hdm_docs_subscription_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_data jsonb;
  v_sender text;
  v_users  text[];
begin
  -- הנתונים הקודמים של אותו מסמך (גם ב-upsert: טריגר ה-INSERT רץ לפני שמתברר שהשורה קיימת)
  if tg_op = 'UPDATE' then
    old_data := old.data;
  else
    select t.data into old_data from public.docs t
     where t.collection = new.collection and t.id = new.id;
  end if;

  -- ---- 🎯 חדש ----
  if new.collection = 'interests' then
    if old_data is null then
      v_sender := coalesce(nullif(new.data->>'from', ''), split_part(new.id, '__', 1));
      if public.hdm_plan_of(v_sender) = 'free' then
        raise exception 'HDM_PLAN_REQUIRED' using errcode = 'P0001',
          hint = 'שליחת 🎯 זמינה מהמסלול הבסיסי ומעלה.';
      end if;
    end if;
    return new;
  end if;

  -- ---- 🎯 דרך רשימת likes בפרופיל: רק הוספה של שמות חדשים נבדקת ----
  if new.collection = 'profiles' then
    if jsonb_typeof(new.data->'likes') = 'array'
       and exists (
         select 1 from jsonb_array_elements(new.data->'likes') n(v)
          where not (case when jsonb_typeof(old_data->'likes') = 'array'
                          then (old_data->'likes') @> jsonb_build_array(n.v) else false end)
       )
       and public.hdm_plan_of(new.id) = 'free' then
      raise exception 'HDM_PLAN_REQUIRED' using errcode = 'P0001',
        hint = 'שליחת 🎯 זמינה מהמסלול הבסיסי ומעלה.';
    end if;
    return new;
  end if;

  -- ---- שיחה חדשה / התאמה חדשה ----
  if new.collection in ('matches', 'chats') and old_data is null then
    if new.id like '%\_\_%' and split_part(new.id, '__', 3) = '' then
      v_users := array[split_part(new.id, '__', 1), split_part(new.id, '__', 2)];
      perform public.hdm_open_pair(new.id, v_users);
    end if;
  end if;

  -- ---- הודעות חדשות: כל שולח חייב מנוי פעיל ----
  if new.collection = 'chats' and jsonb_typeof(new.data->'messages') = 'array' then
    for v_sender in
      select distinct coalesce(n.v->>'senderId', '')
        from jsonb_array_elements(new.data->'messages') n(v)
       where not (case when jsonb_typeof(old_data->'messages') = 'array'
                       then exists (select 1 from jsonb_array_elements(old_data->'messages') o(v) where o.v = n.v)
                       else false end)
    loop
      if v_sender = '' or public.hdm_plan_of(v_sender) = 'free' then
        raise exception 'HDM_PLAN_INACTIVE' using errcode = 'P0001',
          hint = 'שליחת הודעות זמינה למנויים פעילים. השיחה שמורה.';
      end if;
    end loop;
  end if;

  return new;
end;
$$;
revoke all on function public.hdm_docs_subscription_guard() from public, anon, authenticated;

drop trigger if exists hdm_docs_subscription_guard on public.docs;
create trigger hdm_docs_subscription_guard
  before insert or update on public.docs
  for each row
  when (new.collection in ('interests', 'profiles', 'matches', 'chats'))
  execute function public.hdm_docs_subscription_guard();

commit;

select case when to_regclass('public.hdm_subscriptions') is not null and exists (select 1 from pg_trigger where tgname = 'hdm_docs_subscription_guard') then '✅ מערכת המנויים הותקנה, כולל אכיפה' else '❌ לא הותקן — שום דבר לא שונה' end as "סטטוס";
