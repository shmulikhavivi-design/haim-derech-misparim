-- קריאה בלבד: כל הפרופילים ומשתמשי ההתחברות (לזיהוי "דינה"). מוצפן.
select json_build_object(
 'profiles', (select json_agg(json_build_object('profile_id', p.id, 'name', p.data->>'currentName', 'age', p.data->>'age', 'gender', p.data->>'gender', 'location', p.data->>'location', 'created', p.data->>'createdAt',
     'auth_email', (select u.email from public.hdm_accounts a join auth.users u on u.id = a.auth_user_id where a.profile_id = p.id),
     'auth_user_id', (select a.auth_user_id from public.hdm_accounts a where a.profile_id = p.id),
     'plan', (select plan from public.hdm_subscriptions s where s.profile_id = p.id),
     'pair_docs', (select count(*) from public.docs d where d.collection in ('interests','matches','chats','blocks') and (d.id like p.id || '\_\_%' or d.id like '%\_\_' || p.id)))) from public.docs p where p.collection = 'profiles'),
 'auth_users', (select json_agg(json_build_object('id', u.id, 'email', u.email, 'name_meta', u.raw_user_meta_data->>'name', 'created', u.created_at, 'last_sign_in', u.last_sign_in_at, 'confirmed', u.email_confirmed_at is not null,
     'profile_id', (select a.profile_id from public.hdm_accounts a where a.auth_user_id = u.id))) from auth.users u)
) as j
