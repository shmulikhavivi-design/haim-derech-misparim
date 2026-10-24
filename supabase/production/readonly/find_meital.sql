-- קריאה בלבד: איתור "מיטל רון" (פרופילים ומשתמשי התחברות שהשם שלהם תואם) + מצב המנוי והחיוב שלה. מוצפן. לא משנה כלום.
with m as (
  select p.id as profile_id, p.data
  from public.docs p
  where p.collection = 'profiles'
    and (coalesce(p.data->>'currentName','') ~* '(מיטל|מייטל|meital|meytal|metal)'
      or coalesce(p.data->>'currentName','') ~* '(^|\s)(רון|ron)(\s|$)'
      or p.id in (select a.profile_id from public.hdm_accounts a join auth.users u on u.id = a.auth_user_id
                  where coalesce(u.raw_user_meta_data->>'name','') ~* '(מיטל|מייטל|meital|meytal)' or u.email ~* '(meital|meytal|metal)'))
)
select json_build_object(
 'total_profiles', (select count(*) from public.docs where collection = 'profiles'),
 'matches', (select json_agg(json_build_object(
     'profile_id', m.profile_id,
     'name', m.data->>'currentName', 'age', m.data->>'age', 'gender', m.data->>'gender', 'location', m.data->>'location', 'created', m.data->>'createdAt',
     'auth_user_id', a.auth_user_id, 'email', u.email, 'name_meta', u.raw_user_meta_data->>'name',
     'auth_created', u.created_at, 'last_sign_in', u.last_sign_in_at, 'confirmed', u.email_confirmed_at is not null,
     'subscription', (select row_to_json(s) from public.hdm_subscriptions s where s.profile_id = m.profile_id),
     'card_saved', exists (select 1 from public.hdm_billing_tokens t where t.profile_id = m.profile_id),
     'billing_customer', exists (select 1 from public.hdm_billing_customers c where c.profile_id = m.profile_id),
     'checkouts', (select count(*) from public.hdm_checkouts k where k.profile_id = m.profile_id),
     'payments', (select count(*) from public.hdm_payments y where y.profile_id = m.profile_id),
     'hidden', exists (select 1 from public.hdm_hidden_profiles h where h.profile_id = m.profile_id)
   )) from m left join public.hdm_accounts a on a.profile_id = m.profile_id left join auth.users u on u.id = a.auth_user_id),
 'auth_only', (select json_agg(json_build_object('auth_user_id', u.id, 'email', u.email, 'name_meta', u.raw_user_meta_data->>'name', 'created', u.created_at,
     'profile_id', (select a.profile_id from public.hdm_accounts a where a.auth_user_id = u.id)))
   from auth.users u
   where (coalesce(u.raw_user_meta_data->>'name','') ~* '(מיטל|מייטל|meital|meytal)' or u.email ~* '(meital|meytal)')
     and not exists (select 1 from public.hdm_accounts a join m on m.profile_id = a.profile_id where a.auth_user_id = u.id)),
 'subscriptions_columns', (select json_agg(column_name order by ordinal_position) from information_schema.columns where table_schema='public' and table_name='hdm_subscriptions')
) as j
