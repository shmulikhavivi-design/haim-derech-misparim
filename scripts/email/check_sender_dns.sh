#!/usr/bin/env bash
# בדיקת רשומות ה-DNS של דומיין השולח (Brevo) — קריאה בלבד, בלי סודות ובלי שינוי.
#   bash scripts/email/check_sender_dns.sh <domain>
# עובר רק אם קיימים: קוד האימות של Brevo, שתי רשומות DKIM של Brevo ורשומת DMARC.
set -u
D="${1:?usage: check_sender_dns.sh <domain>}"
fail=0
q(){ dig +short "$2" "$1" @1.1.1.1 | tr -d '"'; }
row(){ printf '%-34s %s\n' "$1" "$2"; [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "- **$1:** $2" >> "$GITHUB_STEP_SUMMARY"; }

TXT=$(q "$D" TXT)
if echo "$TXT" | grep -q 'brevo-code:'; then row "Brevo code (TXT $D)" "✅"; else row "Brevo code (TXT $D)" "❌ חסר"; fail=1; fi

for s in brevo1 brevo2; do
  V=$(q "$s._domainkey.$D" CNAME)
  if echo "$V" | grep -qi 'brevo'; then row "DKIM $s._domainkey" "✅ $V"; else row "DKIM $s._domainkey" "❌ חסר"; fail=1; fi
done

DM=$(q "_dmarc.$D" TXT)
if echo "$DM" | grep -q '^v=DMARC1'; then row "DMARC _dmarc" "✅ $DM"; else row "DMARC _dmarc" "❌ חסר"; fail=1; fi

SPF=$(echo "$TXT" | grep '^v=spf1' || true)
row "SPF (לא חובה ל-Brevo)" "${SPF:-אין — תקין}"
if [ "$(echo "$TXT" | grep -c '^v=spf1')" -gt 1 ]; then row "SPF" "❌ יותר מרשומת SPF אחת — חייבת להיות אחת בלבד"; fail=1; fi

[ "$fail" = 0 ] && row RESULT "✅ הדומיין מוכן לאימות ב-Brevo" || row RESULT "❌ חסרות רשומות"
exit "$fail"
