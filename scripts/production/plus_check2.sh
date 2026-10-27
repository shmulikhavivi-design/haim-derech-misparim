#!/usr/bin/env bash
# pluschecktwo (27.10) — READ ONLY: המנוי והרשאות השרת למשתמש ששילם. בלי שינוי.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"
q(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
PID=$(q "select c.profile_id from public.hdm_payments y join public.hdm_checkouts c on c.id=y.checkout_id where y.outcome='approved' order by y.received_at desc limit 1" | jq -r '.[0].profile_id // empty'); echo "::add-mask::${PID:-x}"
S=$(q "select row_to_json(s) j from (select plan, status, source, auto_renew, to_char(period_anchor at time zone 'Asia/Jerusalem','DD.MM HH24:MI') anchor, to_char(current_period_end at time zone 'Asia/Jerusalem','DD.MM.YYYY HH24:MI') period_end, to_char(last_payment_at at time zone 'Asia/Jerusalem','DD.MM HH24:MI') last_pay from public.hdm_subscriptions where profile_id='$PID') s")
ann notice "pc-3a-sub" "$(echo "$S" | jq -c '.[0].j // .' | cut -c1-600)"
X=$(q "select json_build_object('card_linked',(select count(*) from public.hdm_billing_tokens where profile_id='$PID'),'last4',(select card_last4 is not null from public.hdm_billing_tokens where profile_id='$PID'),'events',(select json_agg(to_jsonb(e) - 'profile_id' - 'id' - 'raw' order by e.created_at) from public.hdm_subscription_events e where e.profile_id='$PID'),'renewal_charges',(select count(*) from public.hdm_renewal_charges where profile_id='$PID')) j")
ann notice "pc-3b-extra" "len=${#X} $(echo "$X" | jq -c "if type==\"array\" then .[0].j else . end" 2>&1 | tr -d "\r" | cut -c1-900)"
UID_=$(q "select auth_user_id from public.hdm_accounts where profile_id='$PID'" | jq -r '.[0].auth_user_id // empty'); echo "::add-mask::${UID_:-x}"
E=$(q "select public.hdm_my_entitlements() j from (select set_config('request.jwt.claims', json_build_object('sub','$UID_','role','authenticated')::text, true) a, set_config('request.jwt.claim.sub','$UID_', true) b) s")
ann notice "pc-5-entitlements" "len=${#E} $(echo "$E" | jq -c "if type==\"array\" then .[0].j else . end" 2>&1 | tr -d "\r" | cut -c1-900)"
ann notice "prod-result" "✅ pluschecktwo: קריאה בלבד"
