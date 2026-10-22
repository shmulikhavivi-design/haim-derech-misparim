-- קריאה בלבד: הפרופילים במסלול פלוס — שם, חשבונות, ומה קשור אליהם (ספירות). התוצאה מוצפנת לפני שהיא יוצאת מהשרת.
select json_agg(x) as j from (
  select s.profile_id, s.plan, s.source,
         (select array_agg(k) from jsonb_object_keys(p.data) k) as profile_keys,
         coalesce(p.data->>'name', p.data->>'fullName', p.data->>'displayName', p.data->>'firstName', p.data->>'n') as name,
         p.data->>'gender' as gender,
         a.auth_user_id, u.email, u.last_sign_in_at,
         (select json_agg(json_build_object('col', d.collection, 'email', d.data->>'email', 'name', d.data->>'name')) from public.docs d where d.collection like 'data/users/%' and d.data->>'profileId' = s.profile_id) as legacy_accounts,
         (select json_agg(json_build_object('col', d.collection, 'n', 1)) from public.docs d where d.collection like 'data/users/%' and d.id <> 'x' and d.collection in (select collection from public.docs where data->>'profileId' = s.profile_id)) as legacy_other_docs,
         (select json_agg(json_build_object('email', l.email)) from public.hdm_legacy_accounts l where l.profile_id = s.profile_id) as hdm_legacy,
         (select count(*) from public.docs d where d.collection in ('interests','matches','chats','blocks') and (d.id like s.profile_id || '\_\_%' or d.id like '%\_\_' || s.profile_id)) as pair_docs
    from public.hdm_subscriptions s
    left join public.docs p on p.collection = 'profiles' and p.id = s.profile_id
    left join public.hdm_accounts a on a.profile_id = s.profile_id
    left join auth.users u on u.id = a.auth_user_id
   where s.plan = 'plus'
) x
