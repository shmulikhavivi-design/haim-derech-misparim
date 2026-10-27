#!/usr/bin/env bash
# ownervischeck — קריאה בלבד (נקודת הקצה read-only): האם הפרופיל של הבעלים גלוי למשתמשים אחרים בחיפוש התאמות.
RO="https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only"
q(){ curl -sS -m 40 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
Q1=$(cat <<'SQL'
with me as (select a.profile_id pid from public.hdm_accounts a join auth.users u on u.id=a.auth_user_id where md5(lower(u.email))='162e004328485070b0af8b256ad2e798')
select json_build_object(
 'owner_accounts', (select count(*) from me),
 'owner_profile_exists', (select count(*) from public.docs d, me where d.collection='profiles' and d.id=me.pid),
 'owner_has_photo', (select count(*) from public.docs d, me where d.collection='profiles' and d.id=me.pid and (coalesce(d.data->>'photoUrl','')<>'' or coalesce(d.data->>'photoAssetId','')<>'')),
 'hidden_rows_total', (select count(*) from public.hdm_hidden_profiles),
 'owner_hidden', (select count(*) from public.hdm_hidden_profiles h, me where h.profile_id=me.pid),
 'owner_hidden_reason', (select string_agg(h.reason||' @ '||h.hidden_at::text, ',') from public.hdm_hidden_profiles h, me where h.profile_id=me.pid),
 'policy_uses_hidden', (select pg_get_expr(polqual, polrelid) like '%hdm_profile_hidden%' from pg_policy where polname='profiles_read'),
 'profiles_read_policy', (select pg_get_expr(polqual, polrelid) from pg_policy where polname='profiles_read'),
 'other_select_policies_on_docs', (select json_agg(polname) from pg_policy where polrelid='public.docs'::regclass and polcmd in ('r','*') and polname<>'profiles_read'),
 'rls_on_docs', (select relrowsecurity from pg_class where oid='public.docs'::regclass),
 'anon_select_docs', (select has_table_privilege('anon','public.docs','select')),
 'target_trigger', (select count(*) from pg_trigger where tgname='hdm_block_hidden_target' and not tgisinternal and tgenabled<>'D'),
 'release_marker', (select json_agg(note) from public.hdm_release_marker where version='production_owner_admin_only'),
 'other_real_users', (select count(*) from public.hdm_accounts a, me where a.profile_id<>me.pid),
 'definer_fns_reading_profiles', (select json_agg(p.proname order by p.proname) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.prokind='f' and p.prosecdef and pg_get_functiondef(p.oid) ilike '%''profiles''%'
       and has_function_privilege('authenticated', p.oid, 'execute')),
 'definer_fns_profiles_without_hidden_check', (select json_agg(p.proname order by p.proname) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.prokind='f' and p.prosecdef and pg_get_functiondef(p.oid) ilike '%''profiles''%'
       and pg_get_functiondef(p.oid) not ilike '%hdm_profile_hidden%'
       and has_function_privilege('authenticated', p.oid, 'execute'))
) r
SQL
)
q "$Q1" > /tmp/ov1.json
jq -r '.[0].r // . | if type=="object" then to_entries[] | "\(.key)=\(.value|tostring)" else tostring end' /tmp/ov1.json > /tmp/ov1.txt 2>&1 || cp /tmp/ov1.json /tmp/ov1.txt
n=0; while IFS= read -r line; do n=$((n+1)); ann notice "ov-$n" "$(printf '%s' "$line" | cut -c1-900)"; done < /tmp/ov1.txt
[ "$n" -gt 0 ] || ann notice "ov-empty" "$(head -c 900 /tmp/ov1.json)"
ann notice "prod-result" "ownervischeck — קריאה בלבד, שום דבר לא שונה"
