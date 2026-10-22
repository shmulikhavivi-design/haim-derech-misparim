#!/usr/bin/env bash
# ownercheck — אחרי חיוב הבדיקה: מצב המנוי (קריאה בלבד), מסמך Morning (GET בלבד), וסימולציית חידוש/כישלון/ביטול בעסקה שמבוטלת.
OWNER_EMAIL='shmulikhavivi@gmail.com'
RO="https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only"; RW="https://api.supabase.com/v1/projects/$PROD_REF/database/query"
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
OID=$(roq "select id from auth.users where lower(email)=lower('$OWNER_EMAIL')" | jq -r '.[0].id // empty'); [ -n "$OID" ] || stop "חשבון הבעלים לא נמצא"
ST=$(roq "select coalesce((select json_agg(json_build_object('plan',plan,'amount',amount_agorot,'status',status,'created',created_at,'closed',closed_at) order by created_at desc) from (select * from public.hdm_checkouts where user_id='$OID' order by created_at desc limit 3) k),'[]') checkouts,
  coalesce((select json_agg(json_build_object('kind',kind,'outcome',outcome,'result',result,'plan',plan,'amount',amount_agorot,'review',needs_review,'tx',left(grow_transaction_id,40),'doc',raw->>'documentId','at',received_at) order by received_at desc) from public.hdm_payments p where p.profile_id in (select profile_id from public.hdm_checkouts where user_id='$OID')),'[]') payments,
  (select json_build_object('plan',plan,'status',status,'source',source,'auto_renew',auto_renew,'period_end',current_period_end) from public.hdm_subscriptions s where s.profile_id = (select profile_id from public.hdm_checkouts where user_id='$OID' order by created_at desc limit 1)) sub,
  exists (select 1 from public.hdm_billing_tokens t where t.profile_id = (select profile_id from public.hdm_checkouts where user_id='$OID' order by created_at desc limit 1)) card_saved,
  (select count(*) from public.hdm_payments where outcome='approved') approved_payments_all")
ann notice "owner-state" "$(echo "$ST" | jq -c '.[0] // .')"
DOC=$(echo "$ST" | jq -r '[.[0].payments[]? | select(.doc != null) | .doc][0] // empty')
if [ -n "$DOC" ] && [ -n "${MORNING_CLIENT_ID:-}" ]; then
  echo "::add-mask::$MORNING_CLIENT_SECRET"
  ID=$(printf '%s' "$MORNING_CLIENT_ID" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
  AT=$(curl -sS -m 30 -X POST https://api.morning.co/idp/v1/oauth/token -H 'content-type: application/x-www-form-urlencoded' --data-urlencode grant_type=client_credentials --data-urlencode "client_id=$ID" --data-urlencode "client_secret=$MORNING_CLIENT_SECRET" | jq -r '.accessToken // .access_token // empty')
  [ -n "$AT" ] && echo "::add-mask::$AT"
  D=$(curl -sS -m 30 -H "Authorization: Bearer $AT" -H 'accept: application/json' "https://api.greeninvoice.co.il/api/v1/documents/$DOC")
  ann notice "owner-morning-doc" "מסמך Morning: $(echo "$D" | jq -c '{type, number, status, amount, currency, vat, documentDate, lang, url: (.url.he // .url.origin // null | if . then "קיים" else null end), errorCode, errorMessage}' 2>/dev/null)"
else ann warning "owner-morning-doc" "אין עדיין מזהה מסמך Morning בתשלום"; fi
Q=$(sed "s/__OID__/$OID/" "$HERE/owner_sim.sql")
C=$(curl -sS -m 120 -o /tmp/os.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
MSG=$(jq -r '.message // tostring' /tmp/os.json | grep -o 'HDM_SIM.*' | head -1 | cut -c1-1500)
case "$MSG" in *HDM_SIM*) p=$(echo "$MSG" | sed -E 's/.*passed=([0-9]+).*/\1/'); n=$(echo "$MSG" | sed -E 's/.*total=([0-9]+).*/\1/'); [ "$p" = "$n" ] && ann notice "owner-sim" "✅ סימולציית חידוש/כישלון/ביטול: $p/$n (בוטלה, לא נשמר כלום, בלי Morning)" || ann error "owner-sim" "❌ $MSG";;
  *) ann error "owner-sim" "❌ HTTP $C $(jq -r '.message // tostring' /tmp/os.json | cut -c1-600)";; esac
ST2=$(roq "select (select json_build_object('plan',plan,'status',status,'auto_renew',auto_renew,'period_end',current_period_end) from public.hdm_subscriptions s where s.profile_id = (select profile_id from public.hdm_checkouts where user_id='$OID' order by created_at desc limit 1)) sub, (select count(*) from public.hdm_renewal_charges) charges")
ann notice "owner-after-sim" "אחרי הסימולציה (צריך להיות זהה): $(echo "$ST2" | jq -c '.[0]')"
ann notice "prod-result" "ownercheck הסתיים — קריאה בלבד + סימולציה שבוטלה"
