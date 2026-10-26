#!/usr/bin/env bash
# sweepverify (26.10) — READ ONLY אחרי התקנת הפונקציה ב-SQL Editor. בלי חיוב, בלי שינוי.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"
q(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
F=$(q "select md5(pg_get_functiondef(p.oid)) h, p.prosecdef d, array_to_string(p.proconfig, ',') cfg, has_function_privilege('anon', p.oid, 'execute') anon, has_function_privilege('authenticated', p.oid, 'execute') app, has_function_privilege('service_role', p.oid, 'execute') svc, (select md5(pg_get_functiondef('public.hdm_billing_claim_checkout(uuid,text)'::regprocedure))) claim from pg_proc p where p.oid = 'public.hdm_billing_pending_card_checkouts(int)'::regprocedure" | jq -c '.[0] // .')
ann notice "sv-1-function" "$F (צפוי: h מתחיל ב-c6074a9ec3 כמו ב-Staging, claim d87487f7ff, anon=false app=false svc=true)"
D=$(q "select json_build_object('checkouts',(select count(*) from public.hdm_checkouts),'payments',(select count(*) from public.hdm_payments),'subscriptions',(select count(*) from public.hdm_subscriptions),'tokens',(select count(*) from public.hdm_billing_tokens),'customers',(select count(*) from public.hdm_billing_customers),'users',(select count(*) from auth.users),'claimed_ever',(select count(*) from public.hdm_checkouts where grow_process_id is not null),'pending_live',(select count(*) from public.hdm_checkouts where status='pending' and expires_at>now())) j" | jq -c '.[0].j // .')
ann notice "sv-2-data" "$D (בגיבוי 18:37: payments=1, subscriptions=2, tokens=1, customers=1, users=51)"
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ); R=""
for i in $(seq 1 24); do
  R=$(q "select json_agg(json_build_object('t', to_char(created at time zone 'Asia/Jerusalem','HH24:MI:SS'), 'status', status_code, 'body', left(content::text, 300)) order by created desc) j from (select * from net._http_response where created > '$T0'::timestamptz order by created desc limit 2) x" | jq -c '.[0].j // empty' 2>/dev/null)
  [ -n "$R" ] && [ "$R" != null ] && break; sleep 20
done
ann notice "sv-3-worker" "${R:-לא נמצאה ריצה חדשה תוך 8 דקות}"
ann notice "prod-result" "✅ sweepverify: קריאה בלבד"
