#!/usr/bin/env bash
# fntokcheck (26.10) — READ ONLY עם PRODUCTION_FUNCTIONS_TOKEN: קיים? רואה רק את Production? מה מותר לו? אילו פונקציות פרוסות ואיזו גרסה?
# והגדרות הפונקציות (השוואת טביעות SHA-256 בלבד — אף ערך לא נקרא ולא מודפס). שום פריסה, שום שינוי.
set +e +o pipefail
FT="${FN_TOK:-}"; [ -n "$FT" ] && echo "::add-mask::$FT"
[ -n "$FT" ] || { ann error "fn-token" "PRODUCTION_FUNCTIONS_TOKEN לא הגיע לתהליך (לא קיים בסביבה production או בשם אחר)"; stop "אין טוקן פונקציות"; }
A="https://api.supabase.com/v1/projects/$PROD_REF"
c(){ curl -sS -m 30 -o /tmp/fc.json -w '%{http_code}' -H "Authorization: Bearer $FT" "$1" || echo 000; }
miss(){ jq -r '(.error.missing_permissions // []) | join(",")' /tmp/fc.json 2>/dev/null; }
L="קיים בתהליך: כן (אורך ${#FT})"
C=$(c "https://api.supabase.com/v1/projects"); L="$L | רשימת פרויקטים: HTTP $C $(miss)"
C=$(c "https://api.supabase.com/v1/projects/$STAGING_REF/functions" 2>/dev/null); [ -z "$STAGING_REF" ] && C=skip
L="$L | פונקציות Staging: HTTP $C (צריך להיות חסום)"
C=$(c "$A/functions"); L="$L | פונקציות Production: HTTP $C $(miss)"
FN=$( [ "$C" = 200 ] && jq -r '[.[] | "\(.slug) v\(.version) \(.status) עודכן \(((.updated_at // 0)/1000 | floor | strftime("%d.%m %H:%M")) // .updated_at) jwt=\(.verify_jwt)"] | join(" ; ")' /tmp/fc.json)
C2=$(c "$A/secrets"); L="$L | סודות הפונקציות (שמות+טביעות): HTTP $C2 $(miss)"
C3=$(curl -sS -m 30 -o /tmp/fd.json -w '%{http_code}' -X POST -H "Authorization: Bearer $FT" -H 'Content-Type: application/json' "$A/database/query/read-only" -d '{"query":"select 1"}' || echo 000)
L="$L | מסד (צריך להיות חסום): HTTP $C3"
ann notice "fn-token" "$L"
[ -n "$FN" ] && ann notice "fn-deployed" "$FN"
if [ "$C2" = 200 ]; then
  cmp1(){ local want have; want=$(printf '%s' "$2" | sha256sum | cut -d' ' -f1); have=$(jq -r --arg n "$1" '.[] | select(.name==$n) | .value' /tmp/fc.json)
    if [ -z "$have" ]; then echo "$1=חסר"; elif [ "$want" = "$have" ]; then echo "$1=$3✅"; else echo "$1=$3שונה"; fi; }
  jq '.' /tmp/fc.json > /tmp/sec.json; cp /tmp/sec.json /tmp/fc.json
  S="$(cmp1 HDM_ENV production) | $(cmp1 MORNING_LIVE 1) | $(cmp1 MORNING_API_BASE https://api.greeninvoice.co.il/api/v1) | $(cmp1 MORNING_PLUGIN_ID 53ed9395-02de-4902-a1dd-28dd3f74a5fa) | $(cmp1 DRY_RUN 0)"
  S="$S | $(cmp1 HDM_APP_URL https://haim-derech-misparim.pages.dev 'pages.dev ') | $(cmp1 HDM_APP_URL https://haimderechmisparim.com 'דומיין ')"
  S="$S | $(cmp1 MORNING_CLIENT_ID "${MORNING_CLIENT_ID:-}" 'כמו ב-GitHub ') | $(cmp1 MORNING_CLIENT_SECRET "${MORNING_CLIENT_SECRET:-}" 'כמו ב-GitHub ')"
  for n in HDM_CRON_SECRET MORNING_WEBHOOK_TOKEN MAIL_FROM HDM_RETURN_BASES HDM_BILLING_ALLOWED_USERS; do S="$S | $n=$(jq -r --arg n "$n" 'if any(.[]; .name==$n) then "קיים" else "לא קיים" end' /tmp/fc.json)"; done
  ann notice "fn-secrets" "$S"
fi
rm -f /tmp/fc.json /tmp/sec.json /tmp/fd.json
ann notice "prod-result" "✅ fntokcheck: קריאה בלבד"
