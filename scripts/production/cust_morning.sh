#!/usr/bin/env bash
# custmorning (26.10) — READ ONLY: מצב הלקוח שנכשל היום — במסד וב-Morning/Grow. בלי חיוב, בלי שינוי.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; P='reg_mvmxfyilz2yu20'
q(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
D=$(q "select json_build_object('checkouts',(select json_agg(json_build_object('plan',plan,'status',status,'at',to_char(created_at at time zone 'Asia/Jerusalem','HH24:MI'),'expired',expires_at<=now(),'claimed',grow_process_id is not null) order by created_at) from public.hdm_checkouts where profile_id='$P'),'payments',(select count(*) from public.hdm_payments y join public.hdm_checkouts c on c.id=y.checkout_id where c.profile_id='$P'),'card_linked',(select count(*) from public.hdm_billing_tokens where profile_id='$P'),'subscription',coalesce((select plan||'/'||status from public.hdm_subscriptions where profile_id='$P'),'אין (חינם)'),'account_ok',(select count(*) from public.hdm_accounts where profile_id='$P'),'other_checkouts_today',(select count(*) from public.hdm_checkouts where created_at::date=current_date and profile_id<>'$P')) j" | jq -c '.[0].j // .')
ann notice "cm-db" "$D"
CID=$(q "select morning_client_id from public.hdm_billing_customers where profile_id='$P'" | jq -r '.[0].morning_client_id // empty'); echo "::add-mask::${CID:-x}"
command -v deno >/dev/null || { curl -fsSL https://deno.land/install.sh | sh -s -- -y >/dev/null 2>&1; export PATH="$HOME/.deno/bin:$PATH"; }
echo "::add-mask::${MORNING_CLIENT_SECRET:-x}"
CEMAIL=$(q "select lower(u.email) e from auth.users u join public.hdm_accounts a on a.auth_user_id=u.id where a.profile_id='$P'" | jq -r '.[0].e // empty'); echo "::add-mask::${CEMAIL:-x}"
CEMAIL="$CEMAIL" CID="$CID" deno run --allow-net=api.morning.co,api.greeninvoice.co.il --allow-env --allow-read "$ROOT/scripts/production/cust_morning.ts" 2>&1 | grep '::notice' || ann notice "cm-morning" "בדיקת Morning לא רצה"
ann notice "prod-result" "✅ custmorning: קריאה בלבד"
