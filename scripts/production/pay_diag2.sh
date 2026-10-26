#!/usr/bin/env bash
# paydiagtwo (26.10) — אבחון "לא הצלחנו לפתוח את הדף המאובטח לשמירת הכרטיס". קריאה בלבד: אין יצירת לקוח, אין קישור, אין חיוב.
# יומני morning-checkout (72 שעות), ניסיונות תשלום, השוואת טביעות סודות, ובדיקת Morning בקריאה בלבד. הכול מוצפן (הריפו ציבורי).
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"
OUTD="${RUNNER_TEMP:-/tmp}/hdm-export"; rm -rf "$OUTD"; mkdir -p "$OUTD/out" "$OUTD/w"; W="$OUTD/w"
lq(){ curl -sS -m 60 -G -H "Authorization: Bearer $TOK" "$A/analytics/endpoints/logs.all" --data-urlencode "sql=$1" --data-urlencode "iso_timestamp_start=$2" --data-urlencode "iso_timestamp_end=$3"; }
for d in 0 1 2; do
  E=$(date -u -d "-$(( d*24 )) hours" +%Y-%m-%dT%H:%M:%SZ)
  S=$(date -u -d "-$(( (d+1)*24 )) hours" +%Y-%m-%dT%H:%M:%SZ)
  lq "select timestamp, event_message, metadata from function_logs order by timestamp desc limit 300" "$S" "$E" > "$W/fn_$d.json"
  lq "select timestamp, event_message, metadata from function_edge_logs order by timestamp desc limit 300" "$S" "$E" > "$W/edge_$d.json"
done
q(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
q "select coalesce(json_agg(row_to_json(k) order by created_at desc),'[]') j from (select * from public.hdm_checkouts where created_at > now() - interval '5 days') k" > "$W/ck.json"
q "select coalesce(json_agg(row_to_json(k)),'[]') j from (select profile_id, morning_client_id is not null has_client, created_at from public.hdm_billing_customers) k" > "$W/cust.json"
q "select coalesce(json_agg(row_to_json(k)),'[]') j from (select profile_id, plan, status, source, auto_renew, current_period_end from public.hdm_subscriptions where source='payment' or plan<>'free') k" > "$W/subs.json"
q "select coalesce(json_agg(row_to_json(k) order by received_at desc),'[]') j from (select kind, outcome, result, amount_agorot, needs_review, received_at from public.hdm_payments where received_at > now() - interval '5 days') k" > "$W/pay.json"
curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/secrets" > /tmp/sc.json
cmp1(){ local want have; want=$(printf '%s' "$2" | sha256sum | cut -d' ' -f1); have=$(jq -r --arg n "$1" '.[] | select(.name==$n) | .value' /tmp/sc.json)
  if [ -z "$have" ]; then echo "$1=חסר"; elif [ "$want" = "$have" ]; then echo "$1=$3תואם"; else echo "$1=$3לא-תואם"; fi; }
{ cmp1 MORNING_LIVE 1; cmp1 HDM_ENV production; cmp1 MORNING_API_BASE 'https://api.greeninvoice.co.il/api/v1'; cmp1 MORNING_PLUGIN_ID 53ed9395-02de-4902-a1dd-28dd3f74a5fa
  cmp1 HDM_APP_URL https://haimderechmisparim.com 'new-domain:'; cmp1 HDM_APP_URL https://haim-derech-misparim.pages.dev 'pages.dev:'
  cmp1 MORNING_CLIENT_ID "${MORNING_CLIENT_ID:-}"; cmp1 MORNING_CLIENT_SECRET "${MORNING_CLIENT_SECRET:-}"; cmp1 DRY_RUN 0
  echo "HDM_BILLING_ALLOWED_USERS=$(jq -r '.[] | select(.name=="HDM_BILLING_ALLOWED_USERS") | "קיים"' /tmp/sc.json)"
  echo "names=$(jq -r '[.[].name]|join(",")' /tmp/sc.json)"; } > "$W/secrets.txt"
rm -f /tmp/sc.json
curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/functions" | jq -c '[.[] | {slug, version, status, verify_jwt, updated_at}]' > "$W/functions.json"
command -v deno >/dev/null || { curl -fsSL https://deno.land/install.sh | sh -s -- -y >/dev/null 2>&1; export PATH="$HOME/.deno/bin:$PATH"; }
echo "::add-mask::${MORNING_CLIENT_SECRET:-x}"
CUSTS=$(jq -c '[.[0].j[]?] ' "$W/cust.json" 2>/dev/null || echo '[]')
deno run --allow-net=api.morning.co,api.greeninvoice.co.il --allow-env --allow-read --allow-write="$W" "$ROOT/scripts/production/pay_diag2.ts" "$W/morning.json" || echo '{"script":"failed"}' > "$W/morning_fail.json"
ann notice "paydiag2-sizes" "$(cd "$W" && wc -c * | tr '\n' ' ')"
tar -C "$OUTD" -czf "$OUTD/r.json" w; rm -rf "$OUTD/w"
openssl rand -out "$OUTD/k.bin" 32
openssl enc -aes-256-cbc -pbkdf2 -salt -in "$OUTD/r.json" -out "$OUTD/out/backup.tgz.enc" -pass file:"$OUTD/k.bin"
openssl pkeyutl -encrypt -pubin -inkey "$HERE/session_2610_public.pem" -pkeyopt rsa_padding_mode:oaep -in "$OUTD/k.bin" -out "$OUTD/out/key.enc"
shred -u "$OUTD/k.bin" "$OUTD/r.json"
ann notice "prod-result" "✅ paydiagtwo: נאסף ומוצפן (קריאה בלבד)"
