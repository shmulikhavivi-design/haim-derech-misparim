#!/usr/bin/env bash
# targetcompat — READ-ONLY (27.10): תאימות קוד ה-SQL של התראות 🎯 למבנה הקיים ב-Production. קוד ומבנה בלבד, בלי נתונים.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')" | jq -c '.[0].r // .'; }
Q="select json_build_object(
 'pg_version',current_setting('server_version'),
 'docs_cols',(select json_agg(column_name||':'||data_type order by ordinal_position) from information_schema.columns where table_schema='public' and table_name='docs'),
 'docs_pk',(select pg_get_constraintdef(oid) from pg_constraint where conrelid='public.docs'::regclass and contype='p'),
 'accounts_cols',(select json_agg(column_name||':'||data_type order by ordinal_position) from information_schema.columns where table_schema='public' and table_name='hdm_accounts'),
 'accounts_profile_unique',exists(select 1 from pg_index i join pg_attribute a on a.attrelid=i.indrelid and a.attnum=i.indkey[0] where i.indrelid='public.hdm_accounts'::regclass and i.indisunique and i.indnatts=1 and a.attname='profile_id'),
 'auth_users_cols',(select json_agg(column_name order by column_name) from information_schema.columns where table_schema='auth' and table_name='users' and column_name in ('id','email','email_confirmed_at','banned_until','deleted_at')),
 'release_marker_cols',(select json_agg(column_name||':'||coalesce(column_default,'')||':'||is_nullable order by ordinal_position) from information_schema.columns where table_schema='public' and table_name='hdm_release_marker'),
 'marker_exists',exists(select 1 from public.hdm_release_marker where version='target_email_v1'),
 'blocked_between',to_regprocedure('public.hdm_blocked_between(text,text)') is not null,
 'roles',(select json_agg(rolname order by rolname) from pg_roles where rolname in ('anon','authenticated','service_role')),
 'fn_hashtextextended',to_regprocedure('hashtextextended(text,bigint)') is not null,
 'fn_advisory',to_regprocedure('pg_advisory_xact_lock(bigint)') is not null,
 'name_conflicts',(select json_agg(x) from (select relname x from pg_class where relnamespace='public'::regnamespace and relname like 'hdm_target_email%'
     union all select proname from pg_proc where pronamespace='public'::regnamespace and (proname like 'hdm_target_email%' or proname in ('hdm_my_email_prefs','hdm_set_target_emails'))
     union all select tgname from pg_trigger where tgname like 'hdm_target_email%') q),
 'interests_shape',(select json_build_object('n',count(*),'ok',count(*) filter (where data ? 'from' and data ? 'to' and id=(data->>'from')||'__'||(data->>'to'))) from public.docs where collection='interests'),
 'interest_senders_have_account',(select count(*) filter (where exists(select 1 from public.hdm_accounts a where a.profile_id=d.data->>'from'))||'/'||count(*) from public.docs d where collection='interests'),
 'tables_for_snapshot',(select json_agg(t) from unnest(array['hdm_plans','hdm_subscriptions','hdm_payments']) t where to_regclass('public.'||t) is not null),
 'docs_triggers',(select json_agg(tgname order by tgname) from pg_trigger where tgrelid='public.docs'::regclass and not tgisinternal),
 'default_privs_public_tables',(select json_agg(distinct grantee||':'||privilege_type) from information_schema.role_table_grants where table_schema='public' and table_name='hdm_email_outbox')) r"
ann notice "c1-compat" "$(roq "$Q" | cut -c1-3500)"
ann notice "prod-result" "targetcompat — קריאה בלבד. לא שונה דבר."
