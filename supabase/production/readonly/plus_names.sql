-- קריאה בלבד: שם ומזהה המסמך של החשבון הישן לכל פרופיל פלוס. מוצפן.
select json_agg(json_build_object('profile_id', s.profile_id, 'name', p.data->>'currentName', 'age', p.data->>'age', 'location', p.data->>'location',
  'legacy_doc', (select json_agg(json_build_object('col', d.collection, 'id', d.id)) from public.docs d where d.collection like 'data/users/%' and d.data->>'profileId' = s.profile_id))) as j
  from public.hdm_subscriptions s left join public.docs p on p.collection = 'profiles' and p.id = s.profile_id where s.plan = 'plus'
