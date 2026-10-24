#!/usr/bin/env bash
# maildomaincheck — קריאה בלבד: מוכנות הדומיין haimderechmisparim.com למיילים ולכתובת הרשמית.
# לא משנה שום דבר ב-Supabase, במסד, במשתמשים, במנויים, בסליקה, ב-Brevo או ב-DNS. לא נשלח שום מייל.
# בדיקת Redirect URLs נעשית דרך קישור אימות עם טוקן אקראי שלא קיים — Supabase רק מחזיר שגיאה ומפנה; שום משתמש לא מושפע.
# הריפו ציבורי: כתובות מייל של משתמשים לא מודפסות (רק דומיין הנמען).
set +e +o pipefail
NEW='haimderechmisparim.com'
PROD_ANON='sb_publishable_wwoXFH3xChSfQxHKZEbTKA_t_u5aGMP'
STG_ANON='sb_publishable_UXJrkbmi6h3j3Yvaey5Nvw_HIDJOy40'
sudo apt-get install -y -q dnsutils >/dev/null 2>&1
BUF=/tmp/md_buf.txt; : > $BUF
ann(){ printf '[%s] %s\n' "$2" "$3" >> $BUF; }
flush(){ python3 -I - "$BUF" <<'PY'
import sys
t=open(sys.argv[1],encoding='utf-8').read(); n=3300; parts=[t[i:i+n] for i in range(0,len(t),n)] or ['']
for i,c in enumerate(parts[:9],1):
    c=c.replace('%','%25').replace('\r','%0D').replace('\n','%0A')
    print(f'::notice title=md-part-{i}-of-{len(parts)}::{c}')
PY
}
trap flush EXIT
scrub(){ sed -E 's/[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})/<user>@\1/g'; }

# ---------- 1. DNS ----------
q(){ dig +short "$2" "$1" @"${3:-1.1.1.1}" | tr -d '"' | tr '\n' ' '; }
ROOT_TXT=$(q $NEW TXT)
ann notice "md-1-dns-txt" "TXT בשורש: ${ROOT_TXT:-אין}"
ann notice "md-1-dns-spf" "SPF: $(echo "$ROOT_TXT" | grep -o 'v=spf1[^ ]*\( [^v][^ ]*\)*' | head -3 | tr '\n' '|' ) | מספר רשומות SPF: $(dig +short TXT $NEW @1.1.1.1 | grep -c 'v=spf1')"
for s in brevo1 brevo2 mail; do
  C=$(q "$s._domainkey.$NEW" CNAME); T=$(q "$s._domainkey.$NEW" TXT)
  ann notice "md-1-dkim-$s" "DKIM $s._domainkey: CNAME=${C:-אין} | TXT (אחרי CNAME)=$( [ -n "$T" ] && echo "$T" | cut -c1-60 || echo אין)"
done
ann notice "md-1-dmarc" "DMARC: $(q _dmarc.$NEW TXT) | Google DNS: $(q _dmarc.$NEW TXT 8.8.8.8)"
ann notice "md-1-mx" "MX: $(q $NEW MX) | www: A=$(q www.$NEW A) CNAME=$(q www.$NEW CNAME)"

# ---------- 2. כתובות האתר ----------
curl -sS -m 30 -o /tmp/main.html "https://raw.githubusercontent.com/shmulikhavivi-design/haim-derech-misparim/main/index.html"
MAINMD=$(md5sum /tmp/main.html | cut -c1-8)
for u in "https://$NEW/" "https://www.$NEW/" "http://$NEW/" "https://$NEW/manifest.webmanifest" "https://$NEW/staging.html" "https://haim-derech-misparim.pages.dev/" "https://shmulikhavivi-design.github.io/haim-derech-misparim/"; do
  B=$(curl -sS -L -m 30 -o /tmp/p.html -w '%{http_code} → %{url_effective}' "$u" 2>&1 | tail -1)
  REFS=$(grep -oE "$PROD_REF|$STAGING_REF" /tmp/p.html 2>/dev/null | sort -u | sed "s/$PROD_REF/production/; s/$STAGING_REF/staging/" | tr '\n' ' ')
  MD=$(md5sum /tmp/p.html 2>/dev/null | cut -c1-8)
  ann notice "md-2-site" "$u: $B | supabase: ${REFS:-—} | זהה ל-main: $([ "$MD" = "$MAINMD" ] && echo כן || echo "לא ($MD)")"
done
CERT=$(echo | openssl s_client -servername $NEW -connect $NEW:443 2>/dev/null | openssl x509 -noout -subject -enddate 2>/dev/null | tr '\n' ' ')
ann notice "md-2-tls" "תעודת HTTPS: ${CERT:-לא נקראה}"

# ---------- 3. Supabase — Site URL ו-Redirect URLs (בלי טוקן, בלי שינוי, בלי מייל) ----------
# קישור אימות עם טוקן שלא קיים: Supabase מפנה ל-redirect_to רק אם הוא ברשימה המותרת, אחרת ל-Site URL.
probe(){ local ref=$1 to=$2
  curl -sS -m 20 -o /dev/null -w '%{http_code} %{redirect_url}' "https://$ref.supabase.co/auth/v1/verify?token=hdmprobe$(openssl rand -hex 12)&type=signup&redirect_to=$(python3 -I -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$to")" | sed -E 's/#.*//; s/\?.*//'; }
for env in production staging; do
  if [ $env = production ]; then REF=$PROD_REF; AN=$PROD_ANON; else REF=$STAGING_REF; AN=$STG_ANON; fi
  OUT=""
  for to in "https://$NEW/" "https://$NEW/staging.html" "https://haim-derech-misparim.pages.dev/" "https://shmulikhavivi-design.github.io/haim-derech-misparim/" "https://probe-not-allowed.example.org/"; do
    R=$(probe $REF "$to"); OUT="$OUT
  • בקשה ל-$to ← הופנה ל: ${R#* } ($( [ "${R#* }" = "$to" ] && echo 'מותר ✅' || echo 'לא ברשימה ← Site URL'))"
  done
  ann notice "md-3-auth-$env" "$env — Redirect URLs (דרך קישור אימות פיקטיבי):$OUT"
  S=$(curl -sS -m 20 -H "apikey: $AN" "https://$REF.supabase.co/auth/v1/settings")
  ann notice "md-3-settings-$env" "$env — הגדרות ציבוריות: $(echo "$S" | jq -c '{confirm_email_on:(.mailer_autoconfirm==false), signup_open:(.disable_signup==false), email:.external.email}')"
done
AC=$(curl -sS -m 30 -o /tmp/ac.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://api.supabase.com/v1/projects/$PROD_REF/config/auth" || echo 000)
ann notice "md-3-token" "טוקן Production לניהול (הגדרות Auth/SMTP/תבניות): HTTP $AC $( [ "$AC" = 200 ] && jq -c '{site_url, uri_allow_list, smtp_admin_email, smtp_sender_name, smtp_host}' /tmp/ac.json || echo '— אין גישה, לא ניתן לקרוא את שולח ה-SMTP')"
rm -f /tmp/ac.json

# ---------- 4. פונקציות הסליקה (זמינות בלבד, בלי קריאה לתשלום) ----------
for f in morning-checkout morning-webhook morning-renewals hdm-billing-worker; do
  ann notice "md-4-fn" "$f: OPTIONS → $(curl -sS -m 20 -o /dev/null -w '%{http_code}' -X OPTIONS -H 'Origin: https://haimderechmisparim.com' -H 'Access-Control-Request-Method: POST' "https://$PROD_REF.supabase.co/functions/v1/$f") | CORS לדומיין החדש: $(curl -sS -m 20 -D - -o /dev/null -X OPTIONS -H 'Origin: https://haimderechmisparim.com' -H 'Access-Control-Request-Method: POST' "https://$PROD_REF.supabase.co/functions/v1/$f" | grep -i '^access-control-allow-origin' | tr -d '\r' | cut -c1-80)"
done

# ---------- 5. Brevo — קריאה בלבד ----------
K=$(printf '%s' "${GH_BREVO_API:-}" | tr -d '[:space:]"'"'")
[ -n "$K" ] || { ann warning "md-5-brevo" "BREVO_API_KEY לא זמין"; ann notice "prod-result" "maildomaincheck — קריאה בלבד, שום דבר לא שונה ולא נשלח מייל."; exit 0; }
bv(){ curl -sS -m 60 -G -H "api-key: $K" -H 'accept: application/json' "https://api.brevo.com/v3/$1" "${@:2}"; }
ann notice "md-5-brevo-domains" "Brevo domains: $(bv senders/domains | jq -c '.' | cut -c1-600)"
ann notice "md-5-brevo-domain" "Brevo $NEW: $(bv senders/domains/$NEW | jq -c '.' | cut -c1-1200)"
ann notice "md-5-brevo-senders" "Brevo senders: $(bv senders | jq -c 'if .senders then [.senders[] | {name, email, active}] else . end' | cut -c1-600)"
for d in 2 30; do
  bv smtp/statistics/events --data-urlencode "days=$d" --data-urlencode "limit=2500" --data-urlencode "sort=desc" > /tmp/ev.json
  ann notice "md-5-events-${d}d" "Brevo אירועים $d ימים — לפי דומיין נמען ואירוע: $(jq -c '[.events[]? | {d:((.email//"")|split("@")[1]|ascii_downcase), e:.event}] | group_by(.d) | map({domain:.[0].d, ev:(group_by(.e)|map({(.[0].e):length})|add)})' /tmp/ev.json | cut -c1-2500)"
  ann notice "md-5-from-${d}d" "Brevo — כתובת השולח בפועל ($d ימים): $(jq -c '[.events[]? | select(.event=="requests") | (.from // "?")] | group_by(.) | map({from:.[0], n:length})' /tmp/ev.json | cut -c1-600)"
  ann notice "md-5-walla-${d}d" "Walla ($d ימים): $(jq -c '[.events[]? | select(((.email//"")|ascii_downcase|test("@walla\\.(com|co\\.il)$"))) | {at:(.date|.[0:16]), ev:.event, from:(.from//"?"), subj:((.subject//"")|.[0:30]), reason:((.reason//"")|.[0:170])}]' /tmp/ev.json | scrub | cut -c1-2500)"
done
ann notice "md-5-blocked" "Brevo חסומים (לפי דומיין וסיבה): $(bv smtp/blockedContacts --data-urlencode limit=100 | jq -c '[.contacts[]? | {d:(.email|split("@")[1]), r:(.reason.code // .reason.message // .reason)}] | group_by(.d) | map({domain:.[0].d, n:length, reasons:([.[].r]|unique)})' | cut -c1-1200)"

# מיילים אחרונים (שעתיים): מאיזו כתובת יצאו, ולאן הקישור חוזר. הטוקן בקישור לא מודפס — רק הדומיין ו-redirect_to.
bv smtp/statistics/events --data-urlencode "days=1" --data-urlencode "limit=200" --data-urlencode "sort=desc" > /tmp/ev1.json
SINCE=$(TZ=Asia/Jerusalem date -d '-3 hours' +%Y-%m-%dT%H:%M)
ann notice "md-6-recent" "מיילים מ-$SINCE (שעון ישראל): $(jq -c --arg s "$SINCE" '[.events[]? | select((.date|.[0:16]) >= $s) | {at:(.date|.[0:16]), ev:.event, from:(.from//"?"), to:((.email//"")|split("@")[1]), subj:((.subject//"")|.[0:30]), reason:((.reason//"")|.[0:120])}]' /tmp/ev1.json | cut -c1-2500)"
for mid in $(jq -r --arg s "$SINCE" '[.events[]? | select(.event=="requests" and (.date|.[0:16]) >= $s) | .messageId] | .[0:4][]' /tmp/ev1.json); do
  U=$(bv smtp/emails --data-urlencode "messageId=$mid" | jq -r '.transactionalEmails[0].uuid // empty')
  [ -n "$U" ] || { ann notice "md-6-link" "$mid: לא נמצא תוכן"; continue; }
  BODY=$(bv "smtp/emails/$U" | jq -r '.body // .message // empty')
  L=$(printf '%s' "$BODY" | python3 -I "$HERE/mail_link_parse.py")
  [ -n "$BODY" ] || L="אין גישה לתוכן המייל ב-Brevo"
  ann notice "md-6-link" "קישור במייל ${mid:0:12}…: $L"
done
rm -f /tmp/ev1.json

# Walla — סיכום לפי נמען (מזהה מקוצר במקום כתובת), 30 יום
bv smtp/statistics/events --data-urlencode "days=30" --data-urlencode "limit=2500" --data-urlencode "sort=asc" > /tmp/evw.json
ann notice "md-7-walla" "Walla לפי נמען (30 יום): $(jq -c '[.events[]? | select(((.email//"")|ascii_downcase|test("@walla\\.(com|co\\.il)$")))] | group_by(.email|ascii_downcase) | map({r:((.[0].email|ascii_downcase|@base64)|.[0:6]), dom:(.[0].email|split("@")[1]), first:(.[0].date|.[0:16]), last:(.[-1].date|.[0:16]), subj:([.[].subject]|unique), ev:(group_by(.event)|map({(.[0].event):length})|add), reasons:([.[]|select(.reason!=null and .reason!="")|.reason[0:90]]|unique), from:([.[].from]|unique)})' /tmp/evw.json | cut -c1-3000)"
rm -f /tmp/evw.json
rm -f /tmp/ev.json /tmp/p.html /tmp/main.html
ann notice "prod-result" "maildomaincheck — קריאה בלבד. Supabase/מסד/משתמשים/מנויים/סליקה/Brevo/DNS לא שונו, לא נשלח מייל."
