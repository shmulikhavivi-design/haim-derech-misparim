#!/usr/bin/env bash
# wallaretest — approved one real send: re-sends the signup confirmation to the most recent UNCONFIRMED Walla account
# (same as the user pressing "send again"). Confirms nobody, changes no data. Address never printed.
set -uo pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
H=$(curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/config/auth" | jq -r .smtp_host)
[ "$H" = smtp.resend.com ] || stop "SMTP ב-Production אינו Resend ($H) — לא נשלח"
E=$(roq "select email from auth.users where lower(email) ~ '@walla\\.(com|co\\.il)\$' and email_confirmed_at is null order by created_at desc limit 1" | jq -r '.[0].email // empty')
[ -n "$E" ] || stop "לא נמצא חשבון Walla לא מאומת — לא נשלח"
echo "::add-mask::$E"
AK=$(grep -o -m1 -E 'sb_publishable_[A-Za-z0-9_-]+' "$ROOT/index.html" | head -1)  # public key already in the live app
[ -n "$AK" ] || stop "לא התקבל מפתח anon — לא נשלח"
R=$(curl -sS -m 30 -o /tmp/rr.json -w '%{http_code}' -X POST "https://$PROD_REF.supabase.co/auth/v1/resend" -H "apikey: $AK" -H 'Content-Type: application/json' -d "$(jq -nc --arg e "$E" '{type:"signup",email:$e}')")
ann notice "prod-result" "שליחה חוזרת למשתמש Walla (@${E#*@}): HTTP $R $(jq -c 'del(.email)?' /tmp/rr.json 2>/dev/null | cut -c1-200) — לא אושר אף חשבון ידנית"
rm -f /tmp/rr.json
