-- קריאה בלבד: מה נשאר במסד חוץ מהפרופיל של שמוליק (מזהים וספירות בלבד). מוצפן.
select json_build_object(
  'by_collection', (select json_object_agg(c, n) from (select case when collection like 'data/users/%' then 'data/users/*' else collection end c, count(*) n from public.docs group by 1) z),
  'pair_docs', (select json_agg(json_build_object('col', collection, 'id', id)) from public.docs where collection in ('chats','matches','interests','blocks','chatReads','__lease')),
  'other_tables', (select json_build_object('accounts', (select count(*) from public.hdm_accounts), 'private', (select count(*) from public.hdm_profile_private), 'consents', (select count(*) from public.hdm_consents),
     'openings', (select json_agg(row_to_json(o)) from public.hdm_chat_openings o), 'legacy', (select count(*) from public.hdm_legacy_accounts), 'identities', (select count(*) from auth.identities)))
) as j
