#!/usr/bin/env bash
# defdumptwo — READ ONLY: קוד (לא נתונים) של פונקציות המסלולים, להשוואה מול Staging.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"
for f in hdm_my_entitlements hdm_plan_row hdm_send_target hdm_open_chat_internal hdm_who_targeted_me; do
  B=$(curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d "$(jq -nc --arg f "$f" '{query:("select encode(convert_to(string_agg(pg_get_functiondef(p.oid), chr(10)), $$UTF8$$), $$base64$$) b from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname=$$public$$ and p.proname=$$"+$f+"$$")}')" | jq -r '.[0].b // empty' | tr -d '\n')
  echo "::notice title=dd-$f::$B"
done
ann notice "prod-result" "✅ defdumptwo: קריאה בלבד"
