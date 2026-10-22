-- קריאה בלבד: הפרופילים במסלול פלוס + מה יימחק לכל אחד (ספירות). התוצאה מוצפנת לפני שהיא יוצאת מהשרת.
select json_agg(x order by x.name) as j from (
  select s.profile_id, s.plan, s.source, s.status, s.current_period_end,
         p.data->>'name' as name, a.auth_user_id, u.email, u.created_at as auth_created, u.last_sign_in_at,
         (select count(*) from public.docs d where d.collection in ('interests','matches','chats','blocks') and (d.id like s.profile_id || '\_\_%' or d.id like '%\_\_' || s.profile_id)) as pair_docs,
         (select count(*) from public.docs d where d.collection like 'data/users/%' and d.data->>'profileId' = s.profile_id) as legacy_account_docs,
         (select count(*) from public.hdm_payments pm where pm.profile_id = s.profile_id) as payments,
         (select count(*) from public.hdm_billing_tokens t where t.profile_id = s.profile_id) as tokens
    from public.hdm_subscriptions s
    left join public.docs p on p.collection = 'profiles' and p.id = s.profile_id
    left join public.hdm_accounts a on a.profile_id = s.profile_id
    left join auth.users u on u.id = a.auth_user_id
   where s.plan = 'plus'
) x
