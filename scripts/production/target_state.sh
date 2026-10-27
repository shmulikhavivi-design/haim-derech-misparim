#!/usr/bin/env bash
# targetstate — READ-ONLY: מה קיים עכשיו ב-Production (התראות 🎯 + שינוי בפונקציות מאז הגיבוי). מבנה ומספרים בלבד.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')" | jq -c '.[0].r // .'; }
ann notice "s1-target" "1. התראות 🎯 ב-Production: $(roq "select json_build_object('tables',(select json_agg(tablename order by tablename) from pg_tables where schemaname='public' and tablename like 'hdm_target_email_%'),
 'functions',(select json_agg(proname order by proname) from pg_proc where pronamespace='public'::regnamespace and (proname like 'hdm_target_email%' or proname in ('hdm_my_email_prefs','hdm_set_target_emails'))),
 'trigger',exists(select 1 from pg_trigger where tgname='hdm_target_email_on_interest'),
 'marker',(select json_agg(version||' '||installed_at) from public.hdm_release_marker where version like 'target%'),
 'last_markers',(select json_agg(version||' '||installed_at order by installed_at desc) from (select * from public.hdm_release_marker order by installed_at desc limit 4) m)) r")"
ann notice "s2-funcs" "2. פונקציות public: $(roq "select json_build_object('count',count(*),'names_md5',md5(string_agg(proname||'('||pg_get_function_identity_arguments(oid)||')',',' order by proname, pg_get_function_identity_arguments(oid))),
 'names',string_agg(proname||'='||substr(md5(pg_get_functiondef(oid)),1,6),' ' order by proname)) r from pg_proc where pronamespace='public'::regnamespace and prokind='f'" | cut -c1-3900)"
ann notice "s3-users" "3. משתמשים: $(roq "select json_build_object('users',(select count(*) from auth.users),'last_created',(select max(created_at) from auth.users),'accounts',(select count(*) from public.hdm_accounts)) r")"
ann notice "prod-result" "targetstate — קריאה בלבד."
