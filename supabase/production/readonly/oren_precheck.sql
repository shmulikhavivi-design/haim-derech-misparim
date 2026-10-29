-- קריאה בלבד: הרצה יבשה של כל תנאי העצירה של 24_production_oren_free_plus.sql + צילום מצב לפני (גיבובים). לא משנה כלום.
with c as (select
  (select count(*) from auth.users where lower(email) = 'oren13111976@gmail.com') as accounts_with_email,
  exists (select 1 from auth.users where id = '85a99441-132f-497c-b9a3-d7ebf3343cda' and lower(email) = 'oren13111976@gmail.com' and deleted_at is null) as uid_matches,
  (select profile_id from public.hdm_accounts where auth_user_id = '85a99441-132f-497c-b9a3-d7ebf3343cda') as linked_profile,
  exists (select 1 from public.docs where collection = 'profiles' and id = 'p_b2ae1de0a3df4e7e8a8f' and coalesce(data->>'currentName','') = 'אורן גורגני') as name_matches,
  (select to_jsonb(s) from public.hdm_subscriptions s where profile_id = 'p_b2ae1de0a3df4e7e8a8f') as oren_sub,
  (select count(*) from public.hdm_billing_tokens where profile_id = 'p_b2ae1de0a3df4e7e8a8f') as tokens,
  (select count(*) from public.hdm_payments where profile_id = 'p_b2ae1de0a3df4e7e8a8f') as payments,
  (select count(*) from public.hdm_renewal_charges where profile_id = 'p_b2ae1de0a3df4e7e8a8f') as renewals,
  (select count(*) from public.hdm_checkouts where profile_id = 'p_b2ae1de0a3df4e7e8a8f') as checkouts_all,
  (select count(*) from public.hdm_checkouts where profile_id = 'p_b2ae1de0a3df4e7e8a8f' and status = 'pending') as checkouts_pending,
  (select count(*) from public.hdm_grow_outbox where profile_id = 'p_b2ae1de0a3df4e7e8a8f') as grow_outbox,
  (select count(*) from public.hdm_billing_customers where profile_id = 'p_b2ae1de0a3df4e7e8a8f') as billing_customer,
  to_regclass('public.hdm_staging_marker') is null as is_production
)
select json_build_object(
 'at', now(), 'checks', to_jsonb(c),
 'other_accounts_same_profile', (select count(*) from public.hdm_accounts where profile_id = 'p_b2ae1de0a3df4e7e8a8f'),
 'others_subs_md5', (select md5(coalesce(string_agg(to_jsonb(s)::text, ',' order by profile_id), '')) from public.hdm_subscriptions s where profile_id <> 'p_b2ae1de0a3df4e7e8a8f'),
 'others_subs_count', (select count(*) from public.hdm_subscriptions where profile_id <> 'p_b2ae1de0a3df4e7e8a8f'),
 'others_events_count', (select count(*) from public.hdm_subscription_events where profile_id <> 'p_b2ae1de0a3df4e7e8a8f'),
 'payments', (select count(*) from public.hdm_payments), 'payments_md5', (select md5(coalesce(string_agg(to_jsonb(y)::text, ',' order by to_jsonb(y)::text), '')) from public.hdm_payments y),
 'checkouts', (select count(*) from public.hdm_checkouts), 'checkouts_md5', (select md5(coalesce(string_agg(to_jsonb(k)::text, ',' order by k.id), '')) from public.hdm_checkouts k),
 'card_tokens', (select count(*) from public.hdm_billing_tokens), 'renewal_charges', (select count(*) from public.hdm_renewal_charges), 'grow_outbox', (select count(*) from public.hdm_grow_outbox),
 'plans_md5', (select md5(string_agg(to_jsonb(p)::text, ',' order by plan)) from public.hdm_plans p),
 'auto_renew_subs', (select count(*) from public.hdm_subscriptions where source='payment' and auto_renew and status in ('active','past_due')),
 'subs_cols', (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_schema='public' and table_name='hdm_subscriptions'),
 'events_cols', (select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_schema='public' and table_name='hdm_subscription_events'),
 'source_check', (select string_agg(pg_get_constraintdef(oid), ' | ') from pg_constraint where conrelid='public.hdm_subscriptions'::regclass and contype='c'),
 'events_check', (select string_agg(pg_get_constraintdef(oid), ' | ') from pg_constraint where conrelid='public.hdm_subscription_events'::regclass and contype='c'),
 'sub_triggers', (select string_agg(tgname, ',') from pg_trigger where tgrelid in ('public.hdm_subscriptions'::regclass,'public.hdm_subscription_events'::regclass) and not tgisinternal),
 'plan_of_md5', (select substr(md5(pg_get_functiondef(p.oid)),1,10) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='hdm_plan_of' limit 1)
) as j from c
