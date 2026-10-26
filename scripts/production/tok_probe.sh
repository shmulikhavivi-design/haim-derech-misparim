#!/usr/bin/env bash
# tokprobe (26.10) — READ ONLY: אילו הרשאות יש לטוקן ומה חסר. רק קודי HTTP ושמות הרשאות חסרות מתוך תשובת Supabase. בלי ערכים, בלי שינויים.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"
p(){ local m="$1" u="$2" d="$3" out code miss
  if [ -n "$d" ]; then out=$(curl -sS -m 30 -w '\n%{http_code}' -X "$m" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$u" -d "$d")
  else out=$(curl -sS -m 30 -w '\n%{http_code}' -X "$m" -H "Authorization: Bearer $TOK" "$u"); fi
  code=$(printf '%s' "$out" | tail -n1); miss=$(printf '%s' "$out" | sed '$d' | jq -r '(.error.missing_permissions // []) | join(",")' 2>/dev/null)
  echo "$4: HTTP $code${miss:+ (חסר: $miss)}"; }
R=$( { p GET "$A" "" "פרטי הפרויקט"
  p GET "$A/functions" "" "רשימת פונקציות (Edge Functions read)"
  p GET "$A/functions/morning-checkout" "" "פונקציה morning-checkout"
  p GET "$A/secrets" "" "שמות סודות פונקציות (Secrets read)"
  p POST "$A/database/query/read-only" '{"query":"select 1"}' "שאילתת מסד לקריאה (Database read)"
  p POST "$A/database/query" '{"query":"select 1"}' "שאילתת מסד במצב כתיבה, select 1 בלבד (Database write)"
  p GET "$A/analytics/endpoints/logs.all?sql=select%201" "" "יומנים (Analytics read)"
  p GET "$A/config/auth" "" "הגדרות Auth"; } | tr '\n' '|')
ann notice "tok-probe" "$R"
ann notice "prod-result" "✅ tokprobe: קריאה בלבד"
