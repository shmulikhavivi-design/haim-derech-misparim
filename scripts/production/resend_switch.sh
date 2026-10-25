#!/usr/bin/env bash
# resendswitch — CHANGES PRODUCTION (approved by owner 25.10 18:11): Supabase Auth SMTP Brevo -> Resend.
# Preflight first; aborts with no change if anything fails. No user data touched, no charges.
set -uo pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"
RK=$(printf '%s' "${GH_RESEND_KEY:-}" | tr -d '[:space:]"'"'"); [ -n "$RK" ] && echo "::add-mask::$RK"
SENDER='noreply@test.haimderechmisparim.com'
[ -n "$RK" ] || stop "PRODUCTION_RESEND_API_KEY חסר בסביבת production — לא שונה כלום"
[ -n "$TOK" ] || stop "PRODUCTION_SUPABASE_TOKEN חסר — לא שונה כלום"
# 1. token works
C=$(curl -sS -m 30 -o /tmp/ac.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$A/config/auth")
[ "$C" = 200 ] || stop "טוקן Supabase לא תקף לקריאת Auth (HTTP $C) — לא שונה כלום"
ann notice "before" "$(jq -c '{smtp_host,smtp_port,smtp_user,smtp_admin_email,smtp_sender_name,mailer_autoconfirm}' /tmp/ac.json)"
# 2. Resend key + domain verified (simulated recipient, no real person)
S=$(curl -sS -m 30 -o /tmp/rs.json -w '%{http_code}' -X POST https://api.resend.com/emails -H "Authorization: Bearer $RK" -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg f "חיים דרך מספרים <$SENDER>" '{from:$f,to:["delivered@resend.dev"],subject:"preflight",text:"preflight"}')")
[ "$S" = 200 ] || stop "Resend preflight נכשל (HTTP $S: $(jq -r '.message//empty' /tmp/rs.json)) — לא שונה כלום"
ann notice "preflight" "✅ טוקן תקף | מפתח Resend תקף | הדומיין מאומת (שליחת סימולציה הצליחה)"
# 3. SMTP login check without sending
python3 -I - "$RK" <<'PY' || stop "התחברות SMTP ל-Resend נכשלה — לא שונה כלום"
import smtplib,ssl,sys
s=smtplib.SMTP_SSL("smtp.resend.com",465,context=ssl.create_default_context(),timeout=20); s.login("resend",sys.argv[1]); s.quit()
PY
# 4. apply
P=$(curl -sS -m 30 -o /tmp/pa.json -w '%{http_code}' -X PATCH -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/config/auth" \
  -d "$(jq -nc --arg p "$RK" --arg a "$SENDER" '{external_email_enabled:true,smtp_host:"smtp.resend.com",smtp_port:"465",smtp_user:"resend",smtp_pass:$p,smtp_admin_email:$a,smtp_sender_name:"חיים דרך מספרים"}')")
[ "$P" = 200 ] || stop "עדכון SMTP נכשל (HTTP $P) — ההגדרה הקודמת נשארה"
curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/config/auth" -o /tmp/ac2.json
ann notice "after" "$(jq -c '{smtp_host,smtp_port,smtp_user,smtp_admin_email,smtp_sender_name,mailer_autoconfirm}' /tmp/ac2.json)"
rm -f /tmp/ac.json /tmp/ac2.json /tmp/rs.json /tmp/pa.json
ann notice "prod-result" "✅ Production SMTP עבר ל-Resend. לא נשלח מייל לאף משתמש."
