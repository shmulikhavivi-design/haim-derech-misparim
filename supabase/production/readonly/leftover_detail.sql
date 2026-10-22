-- קריאה בלבד: מבנה ותאריכים של authSessions / chatReadsDebug / reports / data/users (מפתחות ותאריכים בלבד, בלי ערכים אישיים). מוצפן.
select json_build_object(
 'authSessions', (select json_agg(json_build_object('id_prefix', left(id, 6), 'keys', (select array_agg(k order by k) from jsonb_object_keys(data) k),
     'profileId', data->>'profileId', 'userId', data->>'userId', 'created', coalesce(data->>'createdAt', data->>'created', data->>'at'), 'expires', coalesce(data->>'expiresAt', data->>'exp'), 'updated', updated_at)) from public.docs where collection = 'authSessions'),
 'debug', (select json_build_object('n', count(*), 'keys', (select array_agg(distinct k) from public.docs d2, jsonb_object_keys(d2.data) k where d2.collection = 'chatReadsDebug'),
     'id_samples', (select array_agg(id) from (select id from public.docs where collection = 'chatReadsDebug' order by id limit 5) s), 'min_upd', min(updated_at), 'max_upd', max(updated_at),
     'mentions_owner', count(*) filter (where id like '%reg_mupj1bkt75rzke%' or data::text like '%reg_mupj1bkt75rzke%')) from public.docs where collection = 'chatReadsDebug'),
 'reports', (select json_agg(json_build_object('id', id, 'keys', (select array_agg(k) from jsonb_object_keys(data) k), 'updated', updated_at)) from public.docs where collection = 'reports'),
 'legacy_user_docs', (select json_agg(json_build_object('col', collection, 'id', id, 'profileId', data->>'profileId')) from public.docs where collection like 'data/users/%'),
 'owner_sessions_supabase', (select count(*) from auth.sessions),
 'subs_events', (select count(*) from public.hdm_subscription_events), 'payments', (select count(*) from public.hdm_payments), 'checkouts', (select count(*) from public.hdm_checkouts)
) as j
