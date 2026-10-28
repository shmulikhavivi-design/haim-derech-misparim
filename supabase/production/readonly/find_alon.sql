-- קריאה בלבד: איתור החשבון של alon72ifrach@gmail.com + מצב המנוי, החיוב והכרטיס שלו. מוצפן. לא משנה כלום.
with u as (
  select * from auth.users where lower(email) = lower('alon72ifrach@gmail.com')
), m as (
  select a.profile_id, a.auth_user_id from public.hdm_accounts a join u on u.id = a.auth_user_id
)
select json_build_object(
 'auth_exact', (select json_agg(json_build_object('auth_user_id', u.id, 'email', u.email, 'name_meta', u.raw_user_meta_data->>'name',
     'created', u.created_at, 'confirmed', u.email_confirmed_at is not null, 'last_sign_in', u.last_sign_in_at,
     'banned_until', u.banned_until, 'deleted_at', u.deleted_at,
     'profiles_linked', (select count(*) from public.hdm_accounts a where a.auth_user_id = u.id))) from u),
 'auth_similar', (select json_agg(json_build_object('email', x.email, 'created', x.created_at))
   from auth.users x where x.email ~* 'alon.?72|ifrach' and lower(x.email) <> lower('alon72ifrach@gmail.com')),
 'profiles', (select json_agg(json_build_object(
     'profile_id', m.profile_id, 'exists', p.id is not null,
     'name', p.data->>'currentName', 'gender', p.data->>'gender', 'location', p.data->>'location', 'created', p.data->>'createdAt',
     'is_test_account', exists (select 1 from public.hdm_test_accounts t where t.auth_user_id = m.auth_user_id),
     'subscription', (select to_jsonb(s) from public.hdm_subscriptions s where s.profile_id = m.profile_id),
     'events', (select json_agg(to_jsonb(e) - 'profile_id' order by e.id) from public.hdm_subscription_events e where e.profile_id = m.profile_id),
     'card_tokens', (select count(*) from public.hdm_billing_tokens t where t.profile_id = m.profile_id),
     'billing_customer', (select count(*) from public.hdm_billing_customers c where c.profile_id = m.profile_id),
     'checkouts', (select json_agg(json_build_object('plan', k.plan, 'status', k.status, 'amount', k.amount_agorot, 'at', k.created_at) order by k.created_at) from public.hdm_checkouts k where k.profile_id = m.profile_id),
     'payments', (select json_agg(json_build_object('outcome', y.outcome, 'kind', y.kind, 'amount', y.amount_agorot, 'at', y.received_at) order by y.received_at) from public.hdm_payments y where y.profile_id = m.profile_id),
     'renewal_charges', (select count(*) from public.hdm_renewal_charges r where r.profile_id = m.profile_id),
     'grow_outbox', (select count(*) from public.hdm_grow_outbox g where g.profile_id = m.profile_id),
     'hidden', exists (select 1 from public.hdm_hidden_profiles h where h.profile_id = m.profile_id)
   )) from m left join public.docs p on p.collection = 'profiles' and p.id = m.profile_id),
 'plus_plan', (select to_jsonb(pl) from public.hdm_plans pl where pl.plan = 'plus'),
 'subs_columns', (select json_agg(column_name order by ordinal_position) from information_schema.columns where table_schema='public' and table_name='hdm_subscriptions'),
 'subs_source_check', (select pg_get_constraintdef(c.oid) from pg_constraint c where c.conrelid = 'public.hdm_subscriptions'::regclass and c.conname like '%source%' limit 1),
 'set_plan_def_md5', (select substr(md5(pg_get_functiondef(p.oid)),1,10) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='hdm_admin_set_plan' limit 1),
 'set_plan_def', (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='hdm_admin_set_plan' limit 1),
 'plan_of_def', (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='hdm_plan_of' limit 1),
 'manual_free_subs', (select count(*) from public.hdm_subscriptions where source in ('manual','test') and plan <> 'free')
) as j
