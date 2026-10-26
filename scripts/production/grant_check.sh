#!/usr/bin/env bash
# grantcheck (26.10) — READ ONLY: הרשאות service_role על טבלאות החיוב + פונקציות קיימות. אין כתיבה.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"
q(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
R=$(q "select t, has_table_privilege('service_role', 'public.'||t, 'select') sel, has_table_privilege('service_role', 'public.'||t, 'update') upd from unnest(array['hdm_checkouts','hdm_billing_customers','hdm_billing_tokens','hdm_payments','hdm_subscriptions','docs','hdm_accounts']) t" | jq -c '.')
F=$(q "select p.proname, has_function_privilege('service_role', p.oid, 'execute') x from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'hdm_billing_%' order by 1" | jq -c '[.[]? | "\(.proname)=\(.x)"]')
J=$(q "select jobname, schedule, active from cron.job order by 1" | jq -c '.')
ann notice "grant-check" "tables: $R | functions: $F | cron: $J"
ann notice "prod-result" "✅ grantcheck: קריאה בלבד"
