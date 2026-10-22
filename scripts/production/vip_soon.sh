#!/usr/bin/env bash
# vipsoon — 14 (VIP בקרוב, בקשת הבעלים 22.10): חזרה ב-rollback, ואז ביצוע ואימות. מדפיס רק דגלים/ספירות.
RW="https://api.supabase.com/v1/projects/$PROD_REF/database/query"; RO="$RW/read-only"; F="$ROOT/supabase/production/14_production_vip_soon.sql"
run(){ C=$(curl -sS -m 120 -o /tmp/vs.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --arg q "$1" '{query:$q}')" || echo 000); }
run "$(python3 -I -c "import sys;s=open(sys.argv[1]).read().rstrip();i=s.rfind('commit;');print(s[:i]+\"do \$r\$ begin raise exception 'HDM_VIP_OK %', (select string_agg(plan||'='||on_sale, ',' order by plan) from public.hdm_plan_sale); end \$r\$;\nrollback;\")" "$F")"
MSG=$(jq -r '.message // tostring' /tmp/vs.json | cut -c1-500)
case "$MSG" in *HDM_VIP_OK*) ann notice "vip-rehearse" "✅ $(echo "$MSG" | grep -o 'HDM_VIP_OK[^"]*')";; *) stop "החזרה נעצרה — לא שונה כלום: HTTP $C $MSG";; esac
run "$(cat "$F")"
[ "$C" = 201 ] || [ "$C" = 200 ] || stop "14 נעצר — לא שונה כלום: HTTP $C $(jq -r '.message // empty' /tmp/vs.json | cut -c1-300)"
Q="select (select string_agg(plan||'='||on_sale, ',' order by plan) from public.hdm_plan_sale) sale, (select string_agg(plan||':'||price_agorot, ',' order by sort_order) from public.hdm_plans) prices, (select count(*) from pg_trigger where tgname='hdm_checkouts_require_on_sale') trig, (select count(*) from public.hdm_subscriptions) subs, (select count(*) from auth.users) users"
curl -sS -m 60 -o /tmp/vv.json -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$Q" '{query:$q}')"
ann notice "vip-after" "$(jq -c '.[0] // .' /tmp/vv.json)"
ann notice "prod-result" "✅ vipsoon: VIP בקרוב פעיל בשרת"
