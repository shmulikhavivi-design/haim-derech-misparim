#!/usr/bin/env bash
# chaindiag — READ ONLY (token runs read-only transactions). Masked ids. No writes, no mail, no charges.
# Simulates the app's server calls as each relevant user via request.jwt.claims (read-only, same as the app).
A="https://api.supabase.com/v1/projects/$PROD_REF"
q(){ curl -sS -m 120 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
M="substr(md5(%s),1,6)"
BUF=/tmp/cd.txt; : > $BUF; w(){ printf '%s\n' "$*" >> $BUF; }
w "== profiles: masked id | plan | private row | life_path | birth names | gender>looking | age | hidden | has account"
q "select substr(md5(d.id),1,6) id, public.hdm_plan_of(d.id) plan, (pp.profile_id is not null) priv, pp.life_path lp,
     (pp.birth_first_name is not null and pp.birth_last_name is not null) names, d.data->>'gender' g, d.data->>'lookingFor' lf,
     date_part('year', age(pp.birthdate))::int age, exists(select 1 from public.hdm_hidden_profiles h where h.profile_id=d.id) hidden,
     exists(select 1 from public.hdm_accounts a where a.profile_id=d.id) acct
   from public.docs d left join public.hdm_profile_private pp on pp.profile_id=d.id where d.collection='profiles' order by 2,1" | jq -r '.[]? | [.id,.plan,.priv,.lp,.names,(.g+">"+(.lf//"")),.age,.hidden,.acct]|map(tostring)|join(" | ")' >> $BUF
w "== interests (masked from -> to, from plan)"
q "select substr(md5(data->>'from'),1,6) f, substr(md5(data->>'to'),1,6) t, public.hdm_plan_of(data->>'from') pl, to_timestamp((data->>'ts')::bigint/1000) at time zone 'Asia/Jerusalem' ts from public.docs where collection='interests'" | jq -c '.[]?' >> $BUF
w "== plans"; q "select plan, can_rate, rating_details, can_target, can_chat from public.hdm_plans order by sort_order" | jq -c '.[]?' >> $BUF
# simulate as each user with an account
USERS=$(q "select a.auth_user_id::text u, a.profile_id p from public.hdm_accounts a join public.docs d on d.collection='profiles' and d.id=a.profile_id" | jq -r '.[]? | .u+" "+.p')
OTHERS=$(q "select coalesce(json_agg(id),'[]') j from public.docs where collection='profiles'" | jq -c '.[0].j')
w "== simulated app calls per user (masked): plan | entitlements canRate | match_ratings result | my_targets"
while read -r U P; do
  [ -n "$U" ] || continue
  CL=$(jq -nc --arg u "$U" '{sub:$u, role:"authenticated"}')
  pre="with s as materialized (select set_config('request.jwt.claims', '$CL', true) x, set_config('request.jwt.claim.sub', '$U', true) y)"
  E=$(q "$pre select (select public.hdm_my_entitlements()->>'plan') || '/canRate=' || (select public.hdm_my_entitlements()->>'canRate') r from s" | jq -r '.[0].r // .message // .' | cut -c1-120)
  R=$(q "$pre select (select public.hdm_match_ratings(array(select jsonb_array_elements_text('$OTHERS'::jsonb))))::text r from s" | jq -r '.[0].r // .message // .' )
  RS=$(printf '%s' "$R" | jq -r 'if type=="object" then ((keys|length|tostring) + " rated; labels=" + ([.[].label]|unique|join(","))) else . end' 2>/dev/null || printf '%s' "$R" | cut -c1-160)
  T=$(q "$pre select (select public.hdm_my_targets())::text r from s" | jq -r '.[0].r // .message // .' | jq -c 'if type=="array" then map({to:(.id|tostring|.[0:2]+"…"),mutual}) else . end' 2>/dev/null | cut -c1-200)
  w "$(printf '%s' "$P" | md5sum | cut -c1-6) | $E | $RS | targets=$T"
done <<< "$USERS"
w "== function fingerprints (md5 of definition)"
q "select p.proname, substr(md5(pg_get_functiondef(p.oid)),1,8) h from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('hdm_match_ratings','hdm_compat','hdm_send_target','hdm_my_targets','hdm_my_entitlements','hdm_plan_of','hdm_plan_row','hdm_has_interest','hdm_profile_exists','hdm_is_age_blocked','hdm_blocked_between') order by 1" | jq -r '.[]? | .proname+"="+.h' | tr '\n' ' ' >> $BUF
python3 -I - "$BUF" <<'PY'
import sys
t=open(sys.argv[1],encoding='utf-8').read(); n=3300; parts=[t[i:i+n] for i in range(0,len(t),n)] or ['']
for i,c in enumerate(parts[:12],1):
    c=c.replace('%','%25').replace('\r','%0D').replace('\n','%0A'); print(f'::notice title=cd-{i}-of-{len(parts)}::{c}')
PY
