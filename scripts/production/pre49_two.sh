#!/usr/bin/env bash
# pre49two — READ-ONLY: חצים/התאמות (שאילתה מפושטת) + קוד הפונקציות של 🎯 בחיים (קוד בלבד, בלי נתונים).
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"
roqraw(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
roq(){ roqraw "$1" | jq -c '.[0].r // .'; }
ann notice "q4-targets" "4. חצים/התאמות/צ'אטים: $(roq "select json_build_object('interests',(select count(*) from public.docs where collection='interests'),
 'interests_7d',(select count(*) from public.docs where collection='interests' and (data->>'ts') ~ '^[0-9]+$' and (data->>'ts')::bigint > (extract(epoch from now()-interval '7 days')*1000)::bigint),
 'matches',(select count(*) from public.docs where collection='matches'),'chats',(select count(*) from public.docs where collection='chats'),
 'interest_shape_ok',(select count(*) from public.docs where collection='interests' and id = (data->>'from')||'__'||(data->>'to')),
 'docs_triggers',(select json_agg(tgname||':'||case when tgtype & 2 = 2 then 'before' else 'after' end order by tgname) from pg_trigger where tgrelid='public.docs'::regclass and not tgisinternal)) r")"
for f in hdm_send_target hdm_remove_target hdm_docs_guard hdm_block_hidden_target hdm_blocked_between hdm_open_chat_internal; do
  D=$(roqraw "select pg_get_functiondef(p.oid) as d from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='$f'" | jq -r '.[0].d // .')
  printf '%s\n' "$D" > "/tmp/def_$f.sql"
  ann notice "def-$f" "$(printf '%s' "$D" | head -c 7000)"
done
ann notice "prod-result" "pre49two — קריאה בלבד. לא שונה דבר."
