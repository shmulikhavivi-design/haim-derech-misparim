-- =====================================================================
-- חיים דרך מספרים — Production: תקופת השקה (מסלול א׳). להרצה רק באישור הבעלים.
--
-- כל משתמש שאין לו שום רשומת מנוי מקבל את מסלול ההשקה (Plus) — בלי חיוב, בלי רשומה חדשה ובלי שינוי בנתוניו —
-- עד תאריך הסיום שנקבע כאן. אחרי התאריך הוא חוזר אוטומטית ל"חינם". מנויים קיימים (4 החשבונות, Plus ללא תפוגה) לא משתנים.
-- משתמש שקיבל מסלול ידני (כולל "חינם"/פקיעה דרך hdm_admin_*) נשאר במסלול הידני — ההשקה לא דורסת אותו.
--
-- שינוי תאריך / ביטול בהמשך (שורה אחת):
--   update public.hdm_settings set value = jsonb_set(value, '{until}', '"2027-01-31T23:59:59+02:00"') where key = 'launch_promo';
--   update public.hdm_settings set value = jsonb_set(value, '{until}', 'null') where key = 'launch_promo';   -- סיום מיידי
-- ביטול מלא: 06_launch_promo_plus_rollback.sql
-- =====================================================================
begin;

do $$ begin
  if to_regclass('public.hdm_release_marker') is null then raise exception 'עצירה: המעבר עוד לא בוצע. שום דבר לא שונה.'; end if;
  if not exists (select 1 from public.hdm_plans where plan = 'plus') then raise exception 'עצירה: אין מסלול plus. שום דבר לא שונה.'; end if;
end $$;

create table if not exists public.hdm_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.hdm_settings enable row level security;
revoke all on public.hdm_settings from public, anon, authenticated;

insert into public.hdm_settings (key, value) values
  ('launch_promo', jsonb_build_object('plan', 'plus', 'until', '2026-12-31T23:59:59+02:00', 'note', 'השקה: Plus ללא חיוב'))
on conflict (key) do nothing;

-- אותה פונקציה, עם ברירת מחדל של תקופת ההשקה למי שאין לו שום רשומת מנוי. ההרשאות הקיימות נשמרות (create or replace).
create or replace function public.hdm_plan_of(p text)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select s.plan from public.hdm_subscriptions s
      where s.profile_id = p
        and s.status in ('active', 'canceled')
        and (s.current_period_end is null or s.current_period_end > now())),
    (select st.value->>'plan' from public.hdm_settings st
      where st.key = 'launch_promo'
        and st.value->>'until' is not null
        and now() < (st.value->>'until')::timestamptz
        and exists (select 1 from public.hdm_plans pl where pl.plan = st.value->>'plan')
        and not exists (select 1 from public.hdm_subscriptions s2 where s2.profile_id = p)),
    'free')
$$;

-- אימות לפני שמירה
do $$ begin
  if public.hdm_plan_of('__hdm_no_such_profile__') <> 'plus' then raise exception 'עצירה: תקופת ההשקה לא פעילה. שום דבר לא נשמר.'; end if;
  if exists (select 1 from public.hdm_subscriptions s where s.status = 'active' and s.current_period_end is null and public.hdm_plan_of(s.profile_id) <> s.plan) then
    raise exception 'עצירה: מסלול של מנוי קיים השתנה. שום דבר לא נשמר.';
  end if;
  if has_function_privilege('anon', 'public.hdm_plan_of(text)', 'execute') then raise exception 'עצירה: הרשאה לא צפויה. שום דבר לא נשמר.'; end if;
end $$;

commit;
