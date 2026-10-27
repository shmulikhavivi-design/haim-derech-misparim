#!/usr/bin/env bash
# targetids — READ-ONLY (27.10): מבנה החצים (docs/interests) בחיים, ומי רשאי לכתוב אותם. מבנה ומספרים בלבד, בלי מזהים.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')" | jq -c '.[0].r // .'; }
ann notice "i1-shape" "1. חצים בחיים: $(roq "select json_build_object(
 'total',count(*),
 'id_eq_from__to',count(*) filter (where id = (data->>'from')||'__'||(data->>'to')),
 'has_from_to_ts',count(*) filter (where data ? 'from' and data ? 'to' and data ? 'ts'),
 'extra_keys',(select json_agg(distinct k) from public.docs d2, jsonb_object_keys(d2.data) k where d2.collection='interests' and k not in ('from','to','ts')),
 'from_has_account',count(*) filter (where exists(select 1 from public.hdm_accounts a where a.profile_id=d.data->>'from')),
 'to_has_account',count(*) filter (where exists(select 1 from public.hdm_accounts a where a.profile_id=d.data->>'to')),
 'self_target',count(*) filter (where data->>'from' = data->>'to'),
 'id_parts_2',count(*) filter (where array_length(string_to_array(id,'__'),1)=2)) r from public.docs d where collection='interests'")"
ann notice "i2-profileids" "2. מזהי פרופיל: $(roq "select json_build_object('accounts',count(*),'with_double_underscore',count(*) filter (where position('__' in profile_id)>0),
 'check_constraint',(select json_agg(pg_get_constraintdef(oid)) from pg_constraint where conrelid='public.hdm_accounts'::regclass and contype='c'),
 'profiles_docs_with_double_underscore',(select count(*) from public.docs where collection='profiles' and position('__' in id)>0)) r from public.hdm_accounts")"
ann notice "i3-policies" "3. הרשאות כתיבה על docs: $(roq "select json_build_object('policies',(select json_agg(json_build_object('name',policyname,'cmd',cmd,'roles',roles::text,'using',left(coalesce(qual,''),220),'check',left(coalesce(with_check,''),260)) order by policyname) from pg_policies where schemaname='public' and tablename='docs'),
 'grants',(select json_agg(distinct grantee||':'||privilege_type) from information_schema.role_table_grants where table_schema='public' and table_name='docs' and grantee in ('anon','authenticated'))) r" | cut -c1-3800)"
ann notice "i4-functions" "4. מי כותב חצים: $(roq "select json_agg(p.proname order by p.proname) r from pg_proc p where p.pronamespace='public'::regnamespace and pg_get_functiondef(p.oid) ilike '%''interests''%' and pg_get_functiondef(p.oid) ~* 'insert into public\.docs'")"
ann notice "prod-result" "targetids — קריאה בלבד. לא שונה דבר."
