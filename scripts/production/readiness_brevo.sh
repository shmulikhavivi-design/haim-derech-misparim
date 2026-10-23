#!/usr/bin/env bash
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
  CLS=$(python3 -I -c "
import os,unicodedata
v=os.environ.get('GH_BREVO_API','')
lat=sum(c.isascii() and c.isalpha() for c in v); dig=sum(c.isdigit() for c in v); heb=sum('\u0590'<=c<='\u05ff' for c in v)
oth=len(v)-lat-dig-heb; up=sum(c.isupper() for c in v)
pref='כן' if 'xkeysib-'.startswith(v.lower()) or v.lower().startswith('xkeysi') else 'לא'
smtp='כן' if 'xsmtpsib-'.startswith(v.lower()) else 'לא'
word='כן' if v.lower() in ('brevo','sendin','apikey','api_ke','secret','mykey','hdmkey','claude','haimde') else 'לא'
print(f'אותיות לטיניות {lat} (גדולות {up}), ספרות {dig}, עברית {heb}, אחר {oth} | תחילת מפתח Brevo שנחתך (xkeysi…): {pref} | תחילת מפתח SMTP שנחתך: {smtp} | מילה כללית (שם/כינוי): {word}')
" 2>/dev/null)
  ann notice "r-brevo-chars" "הרכב הערך (בלי הערך): $CLS"
  ann notice "r-brevo-shape" "מבנה הערך (בלי הערך): $SHAPE | תשובת Brevo: $MSG1 | עם ערך מנוקה: account HTTP $CT ${MSGT}"
  ann notice "r-brevo-key" "GitHub BREVO_API_KEY: מוגדר, $K | account HTTP $C1 | senders HTTP $C2 (שולח האפליקציה: ${SND:-?}) | transactional stats HTTP $C3 | templates HTTP $C4"
else
  ann warning "r-brevo-key" "BREVO_API_KEY לא זמין לתהליך"
fi
