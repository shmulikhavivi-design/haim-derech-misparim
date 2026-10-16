-- ביטול תקופת ההשקה: מחזיר את hdm_plan_of לגרסה המקורית ומוחק את hdm_settings. מנויים ונתונים לא משתנים.
begin;
create or replace function public.hdm_plan_of(p text)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce((
    select s.plan from public.hdm_subscriptions s
     where s.profile_id = p
       and s.status in ('active', 'canceled')
       and (s.current_period_end is null or s.current_period_end > now())
  ), 'free')
$$;
drop table if exists public.hdm_settings;
commit;
