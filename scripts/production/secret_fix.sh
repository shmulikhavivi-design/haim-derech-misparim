#!/usr/bin/env bash
# secretfix — מתקן את MORNING_CLIENT_ID/SECRET בסודות הפונקציות דרך ה-API (JSON, בלי קובץ env — ערכים עם # או $ נשמרים כמו שהם),
# ואז מאמת לפי SHA-256. לא מדפיס ערכים. (הבאג: env-file חתך את הסוד בתו #)
A="https://api.supabase.com/v1/projects/$PROD_REF"
[ -n "${MORNING_CLIENT_ID:-}" ] && [ -n "${MORNING_CLIENT_SECRET:-}" ] || stop "חסרים מפתחות Morning בסביבה production"
jq -n --arg id "$MORNING_CLIENT_ID" --arg sec "$MORNING_CLIENT_SECRET" '[{name:"MORNING_CLIENT_ID",value:$id},{name:"MORNING_CLIENT_SECRET",value:$sec}]' > /tmp/sf.json
C=$(curl -sS -m 30 -o /tmp/sfr.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/secrets" --data-binary @/tmp/sf.json || echo 000)
shred -u /tmp/sf.json
[ "$C" = 200 ] || [ "$C" = 201 ] || stop "עדכון הסודות נכשל: HTTP $C $(jq -r '.message // empty' /tmp/sfr.json | cut -c1-200)"
source "$HERE/secret_cmp.sh"
