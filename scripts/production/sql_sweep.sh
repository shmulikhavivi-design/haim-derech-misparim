#!/usr/bin/env bash
# sqlsweep — רק אחרי אישור מפורש של הבעלים. מתקין את 20_production_card_sweep.sql (פונקציה אחת לקריאה בלבד, service_role בלבד)
# עם PRODUCTION_DB_WRITE_TOKEN, מהקוד שמוזג ל-main (c3c62d4). לא משנה טבלאות, משתמשים, מנויים או תשלומים. ביטול: drop function (שורה אחת).
set -euo pipefail
WT="${DBW_TOK:-}"; [ -n "$WT" ] || stop "PRODUCTION_DB_WRITE_TOKEN לא הגיע לתהליך"; echo "::add-mask::$WT"
A="https://api.supabase.com/v1/projects/$PROD_REF"
W=$(mktemp -d); git -C "$W" init -q; git -C "$W" fetch -q https://github.com/shmulikhavivi-design/haim-derech-misparim.git main
git -C "$W" checkout -q "$(git -C "$W" rev-parse --verify -q 'c3c62d4b^{commit}')" || stop "הקוד לא נמצא"
F="$W/supabase/production/20_production_card_sweep.sql"; [ -f "$F" ] || stop "קובץ ה-SQL לא נמצא"
cmp -s "$F" "$W/supabase/staging_secure/47_staging_card_sweep.sql" || stop "הקובץ שונה מזה שנבדק ב-Staging"
C=$(curl -sS -m 120 -o /tmp/sq.json -w '%{http_code}' -X POST -H "Authorization: Bearer $WT" -H 'Content-Type: application/json' "$A/database/query" -d "$(jq -nc --rawfile q "$F" '{query:$q}')" || echo 000)
[ "$C" = 201 ] || stop "SQL: HTTP $C $(jq -r '.message // empty' /tmp/sq.json | cut -c1-200)"
V=$(curl -sS -m 60 -X POST -H "Authorization: Bearer $WT" -H 'Content-Type: application/json' "$A/database/query/read-only" -d '{"query":"select has_function_privilege('"'"'service_role'"'"','"'"'public.hdm_billing_pending_card_checkouts(int)'"'"','"'"'execute'"'"') svc, has_function_privilege('"'"'authenticated'"'"','"'"'public.hdm_billing_pending_card_checkouts(int)'"'"','"'"'execute'"'"') app, has_function_privilege('"'"'anon'"'"','"'"'public.hdm_billing_pending_card_checkouts(int)'"'"','"'"'execute'"'"') anon"}' | jq -c '.[0]')
ann notice "sql-sweep" "✅ הותקנה | הרשאות: $V (צפוי svc=true, app=false, anon=false)"
ann notice "prod-result" "✅ sqlsweep הושלם"
