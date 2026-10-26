#!/usr/bin/env bash
# custnow (26.10) — READ ONLY: מצב התשלום של הלקוח מתקלת 26.10 (בלי פרטים אישיים). אין כתיבה, אין פנייה ל-Morning.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; P='reg_mvmxfyilz2yu20'
q(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
R=$(q "select (select json_agg(json_build_object('plan',plan,'status',status,'created',to_char(created_at at time zone 'Asia/Jerusalem','DD.MM HH24:MI'),'claimed',grow_process_id is not null) order by created_at) from public.hdm_checkouts where profile_id='$P') checkouts,
  (select count(*) from public.hdm_payments y join public.hdm_checkouts c on c.id=y.checkout_id where c.profile_id='$P') payments, (select count(*) from public.hdm_billing_tokens where profile_id='$P') saved_card_linked,
  coalesce((select plan||'/'||status from public.hdm_subscriptions where profile_id='$P'),'אין מנוי (חינם)') subscription, public.hdm_plan_of('$P') plan_now" | head -c 600)
ann notice "cust-now" "${R:-empty}"
ann notice "prod-result" "✅ custnow: קריאה בלבד"
