#!/usr/bin/env bash
# readycheck (26.10) — בדיקת מוכנות סופית, קריאה בלבד. בלי חיוב, בלי שינוי.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; FT="${FN_TOK:-}"; [ -n "$FT" ] && echo "::add-mask::$FT"
q(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
V=$(curl -sS -m 30 -H "Authorization: Bearer $FT" "$A/functions" | jq -r '[.[] | select(.slug|test("^morning|hdm-billing")) | "\(.slug) v\(.version) \(.status)"] | join(", ")')
curl -sS -m 30 -H "Authorization: Bearer $FT" "$A/secrets" > /tmp/s.json
h(){ [ "$(printf '%s' "$2" | sha256sum | cut -d' ' -f1)" = "$(jq -r --arg n "$1" '.[]|select(.name==$n)|.value' /tmp/s.json)" ] && echo ✅ || echo ❌; }
S="סליקה פעילה $(h MORNING_LIVE 1) | Production $(h HDM_ENV production) | Morning אמיתי $(h MORNING_API_BASE https://api.greeninvoice.co.il/api/v1) | DRY_RUN כבוי $(h DRY_RUN 0) | פתוח לכל הלקוחות $(jq -r 'if any(.[]; .name=="HDM_BILLING_ALLOWED_USERS") then "❌" else "✅" end' /tmp/s.json)"; rm -f /tmp/s.json
ann notice "rc-1-server" "$V || $S"
P=$(q "select json_build_object(
  'fn_claim_ok', md5(pg_get_functiondef('public.hdm_billing_claim_checkout(uuid,text)'::regprocedure)) like 'd87487f7ff%',
  'fn_sweep_ok', md5(replace(pg_get_functiondef('public.hdm_billing_pending_card_checkouts(int)'::regprocedure), chr(13), '')) like 'c6074a9ec3%',
  'fn_lookup_ok', md5(pg_get_functiondef('public.hdm_billing_checkout_lookup(uuid)'::regprocedure)) like '2419cde161%',
  'grants_ok', not has_function_privilege('authenticated','public.hdm_billing_pending_card_checkouts(int)','execute') and not has_function_privilege('anon','public.hdm_billing_checkout_lookup(uuid)','execute') and not has_function_privilege('authenticated','public.hdm_billing_claim_checkout(uuid,text)','execute') and has_function_privilege('authenticated','public.hdm_billing_start_checkout(text,text,boolean)','execute'),
  'plans_on_sale', (select string_agg(plan||'='||on_sale, ' ' order by plan) from public.hdm_plan_sale),
  'cron', (select string_agg(jobname||(case when active then '✅' else '❌' end), ' ') from cron.job),
  'double_charges', (select count(*) from (select checkout_id from public.hdm_payments where checkout_id is not null and outcome='approved' group by 1 having count(*)>1) d),
  'stuck_claims', (select count(*) from public.hdm_checkouts where grow_process_id is not null and status='pending'),
  'open_alerts', (select count(*) from public.hdm_billing_alerts where coalesce(resolved_at, null) is null)) j" | jq -c '.[0].j // .')
ann notice "rc-2-db" "$P"
W=$(q "select json_agg(json_build_object('t', to_char(created at time zone 'Asia/Jerusalem','HH24:MI'), 's', status_code, 'b', left(content::text, 160)) order by created desc) j from (select * from net._http_response order by created desc limit 3) x" | jq -c '.[0].j // .')
ann notice "rc-3-cron" "$W"
command -v deno >/dev/null || { curl -fsSL https://deno.land/install.sh | sh -s -- -y >/dev/null 2>&1; export PATH="$HOME/.deno/bin:$PATH"; }
echo "::add-mask::${MORNING_CLIENT_SECRET:-x}"
deno run --allow-net=api.morning.co,api.greeninvoice.co.il --allow-env --allow-read "$ROOT/scripts/production/ready_check.ts" 2>&1 | grep '::notice' || ann notice "rc-morning" "בדיקת Morning לא רצה"
L=$(curl -sS -m 30 "https://haimderechmisparim.com/?v=$(date +%s)"); ann notice "rc-4-site" "האתר: תיקון התשלום $(echo "$L" | grep -q hdmPendSet && echo ✅ || echo ❌) | עמוד תשלום עם אישור תנאים $(echo "$L" | grep -q hdm-co-accept && echo ✅ || echo ❌)"
ann notice "prod-result" "✅ readycheck: קריאה בלבד"
