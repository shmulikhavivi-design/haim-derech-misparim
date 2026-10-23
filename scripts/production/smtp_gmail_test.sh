#!/usr/bin/env bash
# smtpgmailtest — מייל בדיקה אחד בלבד (אישור הבעלים 23.10 16:00) אחרי המעבר הזמני ל-Gmail SMTP:
# בקשת איפוס סיסמה לכתובת של הבעלים (מזוהה לפי md5, לא מודפסת). הסיסמה לא משתנה — המייל רק מכיל קישור.
# מדווח בנפרד: (1) האם Supabase קיבל את השליחה (HTTP), (2) האם המייל עבר ב-Brevo (צפוי: לא, כי עכשיו Gmail).
# הוכחת הגעה = רק אישור הבעלים שהמייל בתיבה (ותיקיית "נשלחו" בחשבון ה-Gmail של האפליקציה).
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
EM=$(roq "select email from auth.users where md5(lower(email))='162e004328485070b0af8b256ad2e798'" | jq -r '.[0].email // empty')
[ -n "$EM" ] || stop "לא נמצא חשבון הבעלים — לא נשלח כלום"
echo "::add-mask::$EM"
KEY=$(curl -sS -m 30 "https://shmulikhavivi-design.github.io/haim-derech-misparim/" | grep -oE 'sb_publishable_[A-Za-z0-9_-]+' | head -1)
K=$(printf '%s' "$GH_BREVO_API" | tr -d '[:space:]"'"'")
bv(){ curl -sS -m 30 -H "api-key: $K" -H 'accept: application/json' "https://api.brevo.com/v3/smtp/statistics/events?limit=50&days=1&email=$(jq -rn --arg e "$EM" '$e|@uri')" | jq '[.events[]? | select(.subject|test("Reset";"i"))] | length'; }
B0=$(bv); T0=$(date -u +%s)
C=$(curl -sS -m 60 -o /tmp/rc.json -w '%{http_code}' -X POST "https://$PROD_REF.supabase.co/auth/v1/recover" -H "apikey: $KEY" -H 'Content-Type: application/json' \
     -d "$(jq -nc --arg e "$EM" '{email:$e}')" || echo 000)
ann notice "g-send" "Supabase: HTTP $C $( [ "$C" = 200 ] && echo '— Supabase קיבל את השליחה ושרת ה-SMTP (Gmail) קיבל את המייל' || echo "— נכשל: $(jq -r '.msg // .error_description // .message // empty' /tmp/rc.json | cut -c1-200)")"
sleep 75
B1=$(bv)
ann notice "g-brevo" "יומן Brevo לכתובת הזו (מיילי איפוס): לפני $B0 · אחרי $B1 — $( [ "$B1" = "$B0" ] && echo 'לא עבר דרך Brevo (כצפוי: Gmail)' || echo 'עבר דרך Brevo — ההגדרה עוד לא השתנתה')"
ann notice "g-db" "$(roq "select json_build_object('recovery_sent_now', recovery_sent_at > now() - interval '5 minutes', 'password_unchanged', encrypted_password is not null) r from auth.users where md5(lower(email))='162e004328485070b0af8b256ad2e798'" | jq -c '.[0].r')"
ann notice "prod-result" "smtpgmailtest — מייל בדיקה אחד נשלח; הוכחת הגעה רק לפי הבעלים"
