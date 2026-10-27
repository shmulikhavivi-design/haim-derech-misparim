select json_build_object('v4_lock_held_fn', to_regprocedure('public.hdm_target_email_lock_held(uuid)') is not null,
 'tables', (select json_agg(tablename order by tablename) from pg_tables where schemaname='public' and tablename like 'hdm_target_email_%'),
 'trigger', exists(select 1 from pg_trigger where tgname='hdm_target_email_on_interest'),
 'begin_checks_lock', coalesce(pg_get_functiondef(to_regprocedure('public.hdm_target_email_begin(bigint)')) like '%hdm_target_email_lock_held%', false),
 'outbox_rows', (select count(*) from public.hdm_target_email_outbox),
 'begin_md5', substr(md5(pg_get_functiondef(to_regprocedure('public.hdm_target_email_begin(bigint)'))),1,10))::text
