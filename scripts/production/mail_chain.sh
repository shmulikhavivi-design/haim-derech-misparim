#!/usr/bin/env bash
# mailchain — קריאה בלבד: כל חוליה בשרשרת המיילים. בלי שליחה, בלי שינוי.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
L="${#GH_BREVO_API}"; D=$(printf '%s' "${GH_BREVO_API:-}" | tr -cd '0-9' | wc -c)
ann notice "mc-1-github" "1. GitHub → התהליך: BREVO_API_KEY $([ -n "${GH_BREVO_API:-}" ] && echo "מגיע לתהליך" || echo "לא מגיע") | אורך $L, מתוכם ספרות $D | נראה כמו מפתח Brevo: $(case "${GH_BREVO_API:-}" in xkeysib-*) echo כן;; *) echo לא;; esac)"
NAMES=$(curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/secrets" | jq -r '[.[].name] | join(",")')
ann notice "mc-2-supabase-secrets" "2. השרת ששולח (סודות הפונקציות ב-Supabase): BREVO_API_KEY $(echo ",$NAMES," | grep -q ',BREVO_API_KEY,' && echo קיים || echo 'לא קיים (מועבר רק בשלב ג׳)') | MAIL_FROM $(echo ",$NAMES," | grep -q ',MAIL_FROM,' && echo קיים || echo 'לא קיים (מוגדר בשלב ג׳)')"
FN=$(curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/functions" | jq -r '[.[].slug] | join(",")')
ann notice "mc-3-function" "3. פונקציית השליחה hdm-billing-worker: $(echo ",$FN," | grep -q ',hdm-billing-worker,' && echo פרוסה || echo 'לא פרוסה (נפרסת בשלב ג׳)') | פונקציות קיימות: $FN"
J=$(roq "select json_build_object('jobs', (select coalesce(json_agg(jobname), '[]') from cron.job), 'email_queue', (select count(*) from public.hdm_email_outbox where sent_at is null), 'alerts_installed', to_regclass('public.hdm_billing_alerts') is not null) r" | jq -c '.[0].r')
ann notice "mc-4-db" "4. משימות ותור: $J (נדרשות hdm-billing-worker ו-hdm-billing-alerts-scan — מותקנות בשלב ג׳)"
AC=$(curl -sS -m 30 -o /tmp/ac.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$A/config/auth" || echo 000)
AU=$(roq "select json_build_object('confirmation_sent_24h', (select count(*) from auth.users where confirmation_sent_at > now() - interval '24 hours'), 'recovery_sent_24h', (select count(*) from auth.users where recovery_sent_at > now() - interval '24 hours'), 'last_confirmation_sent_il', (select to_char(max(confirmation_sent_at) at time zone 'Asia/Jerusalem','DD.MM HH24:MI') from auth.users)) r" | jq -c '.[0].r')
ann notice "mc-5-sender" "5. השולח: הגדרות Auth (SMTP של Brevo, שם שולח) — קריאה ישירה: HTTP $AC $( [ "$AC" = 200 ] && jq -c '{sender:.smtp_admin_email, sender_name:.smtp_sender_name, smtp_host}' /tmp/ac.json | sed -E 's/[A-Za-z0-9._%+-]+@/<x>@/' || echo '(אין הרשאה לטוקן הזמני)') | מיילי הרשמה/איפוס שיצאו דרך Brevo: $AU"
ann notice "prod-result" "mailchain — קריאה בלבד"
