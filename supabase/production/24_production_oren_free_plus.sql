with ok as (
  select 'p_b2ae1de0a3df4e7e8a8f'::text as pid
  from auth.users u
  join public.hdm_accounts a on a.auth_user_id = u.id
  join public.docs p on p.collection = 'profiles' and p.id = a.profile_id
  where u.id = '85a99441-132f-497c-b9a3-d7ebf3343cda'
    and lower(u.email) = 'oren13111976@gmail.com'
    and u.deleted_at is null
    and a.profile_id = 'p_b2ae1de0a3df4e7e8a8f'
    and p.data->>'currentName' = 'אורן גורגני'
    and to_regclass('public.hdm_staging_marker') is null
    and (select count(*) from auth.users where lower(email) = 'oren13111976@gmail.com') = 1
    and (select count(*) from public.hdm_accounts where auth_user_id = u.id) = 1
    and not exists (select 1 from public.hdm_subscriptions where profile_id = 'p_b2ae1de0a3df4e7e8a8f')
    and not exists (select 1 from public.hdm_billing_tokens where profile_id = 'p_b2ae1de0a3df4e7e8a8f')
    and not exists (select 1 from public.hdm_payments where profile_id = 'p_b2ae1de0a3df4e7e8a8f')
    and not exists (select 1 from public.hdm_renewal_charges where profile_id = 'p_b2ae1de0a3df4e7e8a8f')
    and not exists (select 1 from public.hdm_checkouts where profile_id = 'p_b2ae1de0a3df4e7e8a8f')
), ins as (
  insert into public.hdm_subscriptions
    (profile_id, plan, status, period_anchor, current_period_end, canceled_at, source, note, auto_renew, grow_direct_debit_id, failed_attempts, last_payment_at)
  select pid, 'plus', 'active', now(), null, null, 'manual', 'Plus בחינם ללא הגבלת זמן, באישור הבעלים 29.10.2026, בלי חיוב ובלי חידוש', false, null, 0, null
  from ok
  returning profile_id, note
)
insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan, note)
select profile_id, 'start', 'free', 'plus', note from ins;

select s.plan as "מסלול", s.status as "סטטוס", s.source as "מקור",
       s.current_period_end is null as "ללא תפוגה",
       not s.auto_renew and s.grow_direct_debit_id is null as "ללא חידוש",
       (select count(*) from public.hdm_payments where profile_id = s.profile_id) as "תשלומים"
from public.hdm_subscriptions s where s.profile_id = 'p_b2ae1de0a3df4e7e8a8f';
