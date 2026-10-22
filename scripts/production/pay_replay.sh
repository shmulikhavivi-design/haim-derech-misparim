#!/usr/bin/env bash
# payreplay — (1) paycheck יבש. (2) רק אם המסמך אמיתי ותואם לגמרי: טוקן webhook חדש לפונקציה (API, JSON) ושליחה חוזרת של ההודעה
# ל-morning-webhook — הפונקציה שולפת את המסמך מ-Morning בעצמה ומפעילה. בלי חיוב. (3) מצב המנוי אחרי.
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"
CKID=$(curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d '{"query":"select id from public.hdm_checkouts where status = '"'"'pending'"'"' and plan = '"'"'basic'"'"' order by created_at desc limit 1"}' | jq -r '.[0].id // empty')
[ -n "$CKID" ] || stop "אין ניסיון תשלום ממתין"
Q="select public.hdm_billing_checkout_lookup('$CKID'::uuid) j"
CK=$(curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query" -d "$(jq -nc --arg q "$Q" '{query:$q}')" | jq -c '.[0].j')
[ "$(echo "$CK" | jq -r .id)" = "$CKID" ] || stop "קריאת ניסיון התשלום נכשלה"
command -v deno >/dev/null || { curl -fsSL https://deno.land/install.sh | sh -s -- -y >/dev/null 2>&1; export PATH="$HOME/.deno/bin:$PATH"; }
echo "::add-mask::$MORNING_CLIENT_SECRET"
GITHUB_OUTPUT=/tmp/pc.out CK_JSON="$CK" deno run --allow-net=api.morning.co,api.greeninvoice.co.il --allow-env --allow-read --allow-write=/tmp "$ROOT/scripts/production/pay_check.ts" || stop "paycheck נכשל"
DOC=$(sed -n 's/^doc=//p' /tmp/pc.out); BOUND=$(sed -n 's/^bound=//p' /tmp/pc.out)
if [ "$MODE" = payreplay ] && [ "$BOUND" = true ] && [ -n "$DOC" ]; then
  NT=$(openssl rand -hex 32); echo "::add-mask::$NT"
  C=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/secrets" -d "$(jq -nc --arg v "$NT" '[{name:"MORNING_WEBHOOK_TOKEN",value:$v}]')" || echo 000)
  [ "$C" = 200 ] || [ "$C" = 201 ] || stop "עדכון טוקן ה-webhook נכשל: HTTP $C"
  sleep 20
  for i in 1 2 3; do
    R=$(curl -sS -m 60 -w ' HTTP %{http_code}' -X POST "https://$PROD_REF.supabase.co/functions/v1/morning-webhook?t=$NT&ck=$CKID" -H 'content-type: application/json' -d "$(jq -nc --arg id "$DOC" '{id:$id, type:320}')")
    case "$R" in *'HTTP 401'*) sleep 15;; *) break;; esac
  done
  ann notice "pay-replay" "תשובת morning-webhook: $(echo "$R" | cut -c1-200)"
elif [ "$MODE" = payreplay ]; then ann warning "pay-replay" "לא נשלח: המסמך לא תואם לגמרי (bound=$BOUND)"; fi
Q2="select (select row_to_json(s) from (select plan, status, source, auto_renew, period_anchor, current_period_end, last_payment_at from public.hdm_subscriptions where profile_id='reg_mupj1bkt75rzke') s) sub, (select json_agg(json_build_object('kind',kind,'outcome',outcome,'result',result,'amount',amount_agorot,'review',needs_review,'plan',plan,'period_end_after',period_end_after)) from public.hdm_payments) payments, (select status from public.hdm_checkouts where id='$CKID') checkout, exists(select 1 from public.hdm_billing_tokens where profile_id='reg_mupj1bkt75rzke') card_saved"
curl -sS -m 30 -o /tmp/ps.json -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$Q2" '{query:$q}')"
ann notice "pay-state" "$(jq -c '.[0] // .' /tmp/ps.json)"
ann notice "prod-result" "$MODE הסתיים"
