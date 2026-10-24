#!/usr/bin/env bash
# domainprep — הכנת הדומיין haimderechmisparim.com. לא משנה שום דבר ב-Supabase, במסד, במשתמשים, במנויים או בסליקה.
# קריאה בלבד: הגדרות Auth (Site URL / Redirect URLs), זמינות הכתובות (חדשה + ישנות), רשומות DNS.
# הפעולה היחידה שמוסיפה משהו: הוספת הדומיין ב-Brevo (Senders & Domains) כדי לקבל את רשומות האימות. זה לא משנה את השולח הנוכחי ולא שולח מייל.
set +e +o pipefail
case "$COMMIT_MSG" in *'{brevo-only}'*) DP_BREVO_ONLY=1;; esac
NEW='haimderechmisparim.com'
A="https://api.supabase.com/v1/projects/$PROD_REF"
sudo apt-get install -y -q dnsutils >/dev/null 2>&1

if [ -z "${DP_BREVO_ONLY:-}" ]; then
# 1. הגדרות Auth ב-Production (קריאה בלבד)
AC=$(curl -sS -m 30 -o /tmp/ac.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$A/config/auth" || echo 000)
ann notice "dp-1-auth" "Production Auth (קריאה): HTTP $AC $( [ "$AC" = 200 ] && jq -c '{site_url, uri_allow_list, confirm_email_on:(.mailer_autoconfirm==false), sender_domain:((.smtp_admin_email//"")|split("@")[1]), smtp_sender_name}' /tmp/ac.json )"
SE=$(curl -sS -m 30 -o /tmp/se.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$A/secrets" || echo 000)
ann notice "dp-1-secrets" "Edge Function secrets (שמות בלבד): HTTP $SE $( [ "$SE" = 200 ] && jq -c '[.[].name] | map(select(test("APP_URL|MAIL_|SITE|URL")))' /tmp/se.json )"
rm -f /tmp/ac.json /tmp/se.json

# 2. זמינות הכתובות — לאיזה פרויקט Supabase כל עמוד מחובר
for u in "https://$NEW/" "https://www.$NEW/" "https://$NEW/staging.html" "https://haim-derech-misparim.pages.dev/" "https://shmulikhavivi-design.github.io/haim-derech-misparim/"; do
  B=$(curl -sS -L -m 30 -o /tmp/p.html -w '%{http_code} %{url_effective}' "$u" 2>&1 | tail -1)
  REFS=$(grep -oE "$PROD_REF|$STAGING_REF" /tmp/p.html 2>/dev/null | sort -u | sed "s/$PROD_REF/production/; s/$STAGING_REF/staging/" | tr '\n' ' ')
  SZ=$(wc -c </tmp/p.html 2>/dev/null); MD=$(md5sum /tmp/p.html 2>/dev/null | cut -c1-8)
  ann notice "dp-2-site" "$u → $B | supabase: ${REFS:-אין} | $SZ bytes md5:$MD"
done
rm -f /tmp/p.html

# 3. DNS (קריאה בלבד)
q(){ dig +short "$2" "$1" @1.1.1.1 | tr '\n' ' '; }
ann notice "dp-3-dns" "NS: $(q $NEW NS) | A: $(q $NEW A) | TXT: $(q $NEW TXT) | MX: $(q $NEW MX) | _dmarc: $(q _dmarc.$NEW TXT) | brevo1: $(q brevo1._domainkey.$NEW CNAME) | brevo2: $(q brevo2._domainkey.$NEW CNAME)"

fi
# 4. Brevo — הוספת הדומיין (אם עוד לא קיים) וקבלת הרשומות הנדרשות
K=$(printf '%s' "${GH_BREVO_API:-}" | tr -d '[:space:]"'"'")
[ -n "$K" ] || { ann warning "dp-4-brevo" "BREVO_API_KEY לא זמין"; exit 0; }
bv(){ curl -sS -m 40 -H "api-key: $K" -H 'accept: application/json' -H 'content-type: application/json' "$@"; }
HAS=$(bv "https://api.brevo.com/v3/senders/domains" | jq -r --arg d "$NEW" '[.domains[]? | select(.domain_name==$d)] | length')
ann notice "dp-4-brevo-before" "דומיינים ב-Brevo לפני: $(bv https://api.brevo.com/v3/senders/domains | jq -c '[.domains[]? | {domain_name, authenticated, verified}]')"
if [ "$HAS" = 0 ]; then
  ADD=$(bv -X POST "https://api.brevo.com/v3/senders/domains" -d "{\"name\":\"$NEW\"}")
  ann notice "dp-4-brevo-add" "הוספת $NEW ל-Brevo: $(echo "$ADD" | jq -c '{id, domain_name, message, code}' 2>/dev/null || echo "$ADD" | cut -c1-300)"
fi
ann notice "dp-4-brevo-domain" "$NEW ב-Brevo: $(bv "https://api.brevo.com/v3/senders/domains/$NEW" | jq -c '.' | cut -c1-3000)"
ann notice "dp-4-brevo-senders" "שולחים ב-Brevo (דומיין בלבד): $(bv https://api.brevo.com/v3/senders | jq -c '[.senders[]? | {name, domain:(.email|split("@")[1]), active}]')"
ann notice "prod-result" "domainprep — Supabase/מסד/משתמשים/מנויים לא שונו. ב-Brevo נוסף הדומיין בלבד (השולח הנוכחי לא שונה, לא נשלח מייל)."
