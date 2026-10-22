#!/usr/bin/env bash
# readiness — קריאה בלבד לפני הפעלה: כפילויות חיוב, ביטולים, תור מיילים, שמות סודות (בלי ערכים), פונקציות, משימות מתוזמנות,
# והתאמה מול Morning (GET בלבד). מדפיס ספירות וסכומים בלבד — בלי שמות, אימיילים או מזהים.
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
ONLY_CARD=0; case "${COMMIT_MSG:-}" in *cardonly*) ONLY_CARD=1;; esac; BREVO_ONLY=0; case "${COMMIT_MSG:-}" in *brevoonly*) BREVO_ONLY=1; ONLY_CARD=1;; esac
if [ -n "${GH_BREVO_API:-}" ]; then   # בדיקת מפתח Brevo בקריאה בלבד — בלי לשלוח מייל
  bc(){ curl -sS -m 30 -o /tmp/bc.json -w '%{http_code}' -H "api-key: $GH_BREVO_API" -H 'accept: application/json' "https://api.brevo.com/v3/$1" || echo 000; }
  K=$(case "$GH_BREVO_API" in xkeysib-*) echo "מפתח API (xkeysib)";; xsmtpsib-*) echo "❌ מפתח SMTP ולא API";; *) echo "מבנה אחר";; esac)
  C1=$(bc account); C2=$(bc senders)
  SND=$(jq -r --arg f life.through.numbers333@gmail.com '[.senders[]? | select((.email|ascii_downcase)==$f) | (if .active then "פעיל" else "לא פעיל" end)] | if length==0 then "לא נמצא" else join(",") end' /tmp/bc.json 2>/dev/null)
  C3=$(bc "smtp/statistics/aggregatedReport?days=1")
  C4=$(bc "smtp/templates?limit=1")
  V="$GH_BREVO_API"; T=$(printf '%s' "$V" | tr -d '[:space:]"'"'"); T=${T#BREVO_API_KEY=}; T=${T#api-key:}
  SHAPE="אורך $(printf '%s' "$V" | wc -c), רווחים/שורות: $(printf '%s' "$V" | grep -c '[[:space:]]' || true), גרשיים: $(printf '%s' "$V" | grep -c '["'"'"']' || true), מכיל xkeysib-: $(printf '%s' "$V" | grep -c 'xkeysib-' || true), מכיל xsmtpsib-: $(printf '%s' "$V" | grep -c 'xsmtpsib-' || true), מתחיל באות/ספרה: $(printf '%s' "$V" | head -c1 | grep -c '[A-Za-z0-9]' || true), אחרי ניקוי מתחיל ב-xkeysib-: $(case "$T" in xkeysib-*) echo כן;; *) echo לא;; esac)"
  MSG1=$(jq -r '.message // .code // empty' /tmp/bc.json 2>/dev/null | sed -E 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<IP>/g; s/[0-9a-fA-F:]{8,}/<IP6>/g' | cut -c1-200)
  CT=$(curl -sS -m 30 -o /tmp/bt.json -w '%{http_code}' -H "api-key: $T" -H 'accept: application/json' https://api.brevo.com/v3/account || echo 000)
  MSGT=$(jq -r '.message // .code // empty' /tmp/bt.json 2>/dev/null | sed -E 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<IP>/g' | cut -c1-200)
  ann notice "r-brevo-shape" "מבנה הערך (בלי הערך): $SHAPE | תשובת Brevo: $MSG1 | עם ערך מנוקה: account HTTP $CT ${MSGT}"
  ann notice "r-brevo-key" "GitHub BREVO_API_KEY: מוגדר, $K | account HTTP $C1 | senders HTTP $C2 (שולח האפליקציה: ${SND:-?}) | transactional stats HTTP $C3 | templates HTTP $C4"
else
  ann warning "r-brevo-key" "BREVO_API_KEY לא זמין לתהליך"
fi
if [ $ONLY_CARD = 0 ]; then
NAMES=$(curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/secrets" | jq -r '[.[].name] | map(select(test("^(SUPABASE_|SB_)")|not)) | sort | join(", ")')
ann notice "r-secret-names" "סודות הפונקציות (שמות בלבד): $NAMES"
for n in BREVO_API_KEY MAIL_FROM; do echo "$NAMES" | grep -qw "$n" && ann notice "r-$n" "$n: מוגדר" || ann warning "r-$n" "$n: חסר"; done
ann notice "r-github-brevo" "GitHub: BREVO_API_KEY $([ -n "${GH_BREVO_API:-}" ] && echo מוגדר || echo חסר) | BREVO_SMTP_KEY $([ -n "${GH_BREVO_SMTP:-}" ] && echo מוגדר || echo חסר)"
ann notice "r-functions" "פונקציות: $(curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/functions" | jq -r '[.[] | "\(.slug) v\(.version) \(.status) jwt=\(.verify_jwt)"] | join(" | ")')"
ann notice "r-cron" "משימות מתוזמנות: $(roq "select coalesce(json_agg(jobname||' ['||schedule||'] '||case when active then 'פעילה' else 'כבויה' end order by jobname),'[]') j from cron.job" | jq -r '.[0].j | join(" | ")' 2>/dev/null)"
Q="select json_build_object(
 'payments', (select count(*) from public.hdm_payments),
 'approved', (select count(*) from public.hdm_payments where outcome='approved'),
 'approved_sum_ils', (select coalesce(sum(amount_agorot),0)/100.0 from public.hdm_payments where outcome='approved'),
 'by_kind', (select coalesce(json_object_agg(k,n),'{}') from (select kind||'/'||outcome k, count(*) n from public.hdm_payments group by 1) x),
 'dup_same_doc', (select count(*) from (select raw->>'documentId' from public.hdm_payments where raw->>'documentId' is not null group by 1 having count(*)>1) x),
 'dup_same_tx', (select count(*) - count(distinct grow_transaction_id) from public.hdm_payments),
 'dup_same_checkout', (select count(*) from (select checkout_id from public.hdm_payments where checkout_id is not null and outcome='approved' group by 1 having count(*)>1) x),
 'two_approved_within_20d', (select count(*) from public.hdm_payments a join public.hdm_payments b on a.profile_id=b.profile_id and a.id<b.id and a.outcome='approved' and b.outcome='approved' and b.received_at - a.received_at < interval '20 days' and a.kind<>'upgrade' and b.kind<>'upgrade'),
 'payments_needs_review', (select count(*) from public.hdm_payments where needs_review),
 'checkouts', (select coalesce(json_object_agg(s,n),'{}') from (select status s, count(*) n from public.hdm_checkouts group by 1) x),
 'checkouts_pending_open', (select count(*) from public.hdm_checkouts where status='pending'),
 'renewal_charges', (select coalesce(json_object_agg(s,n),'{}') from (select status s, count(*) n from public.hdm_renewal_charges group by 1) x),
 'dup_renewal_same_period', (select count(*) from (select profile_id, period_end from public.hdm_renewal_charges where status in ('approved','pending','review') group by 1,2 having count(*)>1) x),
 'subs', (select coalesce(json_object_agg(k,n),'{}') from (select plan||'/'||status||'/'||source||'/renew='||auto_renew k, count(*) n from public.hdm_subscriptions group by 1) x),
 'canceled_but_auto_renew', (select count(*) from public.hdm_subscriptions where status='canceled' and auto_renew),
 'paid_renewing_without_card', (select count(*) from public.hdm_subscriptions s where source='payment' and auto_renew and status='active' and not exists (select 1 from public.hdm_billing_tokens t where t.profile_id=s.profile_id)),
 'next_renewal', (select to_char(min(current_period_end) at time zone 'Asia/Jerusalem','DD.MM.YYYY HH24:MI') from public.hdm_subscriptions where auto_renew and status='active'),
 'cards_saved', (select count(*) from public.hdm_billing_tokens),
 'morning_customers', (select count(*) from public.hdm_billing_customers),
 'cancel_requests', (select coalesce(json_object_agg(s,n),'{}') from (select state s, count(*) n from public.hdm_cancel_requests group by 1) x),
 'cancel_needs_review', (select count(*) from public.hdm_cancel_requests where needs_review),
 'refunds_open', (select count(*) from public.hdm_cancel_requests where refund_state='open'),
 'grow_outbox_open', (select count(*) from public.hdm_grow_outbox where done_at is null),
 'email_outbox', (select json_build_object('total',count(*),'sent',count(sent_at),'waiting',count(*) filter (where sent_at is null),'with_errors',count(*) filter (where sent_at is null and attempts>0)) from public.hdm_email_outbox),
 'alerts_installed', to_regclass('public.hdm_billing_alerts') is not null,
 'cancel_fn_grow_branch', (select count(*) from public.hdm_subscriptions where grow_direct_debit_id is not null)
) r"
R=$(roq "$Q"); ann notice "r-db" "$(echo "$R" | jq -c '.[0].r // .')"
fi
DOCS=$(roq "select coalesce(json_agg(json_build_object('d',raw->>'documentId','a',amount_agorot)),'[]') j from public.hdm_payments where outcome='approved' and raw->>'documentId' is not null" | jq -c '.[0].j')
if [ $BREVO_ONLY = 0 ] && [ -n "${MORNING_CLIENT_ID:-}" ]; then
  echo "::add-mask::$MORNING_CLIENT_SECRET"
  ID=$(printf '%s' "$MORNING_CLIENT_ID" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
  AT=$(curl -sS -m 30 -X POST https://api.morning.co/idp/v1/oauth/token -H 'content-type: application/x-www-form-urlencoded' --data-urlencode grant_type=client_credentials --data-urlencode "client_id=$ID" --data-urlencode "client_secret=$MORNING_CLIENT_SECRET" | jq -r '.accessToken // .access_token // empty')
  [ -n "$AT" ] && echo "::add-mask::$AT"
  [ -n "$AT" ] && ann notice "r-morning-auth" "✅ התחברות ל-Morning (קריאה בלבד)" || ann error "r-morning-auth" "❌ התחברות ל-Morning נכשלה"
  if [ $ONLY_CARD = 0 ]; then
  ok=0; bad=0
  for row in $(echo "$DOCS" | jq -c '.[]'); do d=$(echo "$row" | jq -r .d); a=$(echo "$row" | jq -r .a)
    amt=$(curl -sS -m 30 -H "Authorization: Bearer $AT" -H 'accept: application/json' "https://api.greeninvoice.co.il/api/v1/documents/$d" | jq -r '.amount // empty')
    if [ -n "$amt" ] && [ "$(python3 -c "print(round(float('$amt')*100))")" = "$a" ]; then ok=$((ok+1)); else bad=$((bad+1)); fi; done
  ann notice "r-morning-match" "תשלומים מאושרים מול מסמכי Morning: תואמים $ok | לא תואמים/חסרים $bad"
  S=$(curl -sS -m 30 -X POST -H "Authorization: Bearer $AT" -H 'content-type: application/json' https://api.greeninvoice.co.il/api/v1/documents/search \
       -d "$(jq -nc --arg f "$(date -u -d '-60 days' +%Y-%m-%d)" --arg t "$(date -u +%Y-%m-%d)" '{fromDate:$f,toDate:$t,page:1,pageSize:100}')")
  ann notice "r-morning-docs" "מסמכים ב-Morning ב-60 הימים האחרונים: $(echo "$S" | jq -c '{total: (.total // (.items|length)), by_type: ([.items[]? | .type|tostring] | group_by(.) | map({(.[0]): length}) | add), sum_ils: ([.items[]? | .amount // 0] | add)}' 2>/dev/null || echo "$S" | jq -c '{errorCode, errorMessage}')"
  fi
  TS=$(curl -sS -m 30 -X POST -H "Authorization: Bearer $AT" -H 'content-type: application/json' https://api.greeninvoice.co.il/api/v1/payments/tokens/search -d '{"page":1,"pageSize":50}')
  ann notice "r-token-shape" "מבנה תשובת הכרטיסים (שמות שדות בלבד): $(echo "$TS" | jq -c '{keys: (keys), item_keys: ((.items // [])[0] // {} | keys)}' 2>/dev/null | cut -c1-600)"
  for cid in $(echo "$TS" | jq -r '[.items[]? | (.client.id // .clientId // .externalKey // empty)] | unique | .[]' 2>/dev/null); do
    C=$(curl -sS -m 30 -H "Authorization: Bearer $AT" -H 'accept: application/json' "https://api.greeninvoice.co.il/api/v1/clients/$cid")
    ann notice "r-token-client" "לקוח של כרטיס שמור: $(echo "$C" | jq -c '{found: (.id != null), send_documents_by_email: .send, has_email: ((.emails // []) | length > 0), active, errorCode}' 2>/dev/null)"
  done
  TS=$(curl -sS -m 30 -X POST -H "Authorization: Bearer $AT" -H 'content-type: application/json' https://api.greeninvoice.co.il/api/v1/payments/tokens/search -d '{"page":1,"pageSize":50}')
  ann notice "r-token-status" "סטטוס הכרטיס השמור: $(echo "$TS" | jq -c '[.items[]? | {status, type, pluginType, expires_in_future: ((.expires // "") as $e | if ($e|test("^[0-9]{2}/?[0-9]{2,4}$")) then (($e|gsub("/";"")) as $x | ($x[2:]|tonumber) as $y | ($x[0:2]|tonumber) as $m | (if $y < 100 then 2000+$y else $y end) as $Y | ($Y > (now|strftime("%Y")|tonumber)) or ($Y == (now|strftime("%Y")|tonumber) and $m >= (now|strftime("%m")|tonumber))) else "format?" end), expires_format_len: ((.expires // "")|tostring|length)}]' 2>/dev/null)"
  ann notice "r-morning-tokens" "כרטיסים שמורים ב-Morning/Grow: $(echo "$TS" | jq -c '{total: (.total // (.items|length)), active: ([.items[]? | select((.status // 0) == 0 or .active == true)] | length)}' 2>/dev/null || echo "?")"
else ann warning "r-morning" "בלי פרטי Morning — לא נבדק"; fi
ann notice "prod-result" "readiness הסתיים — קריאה בלבד, לא שונה כלום"
