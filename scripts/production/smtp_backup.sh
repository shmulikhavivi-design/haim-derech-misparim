#!/usr/bin/env bash
# smtpbackup — קריאה בלבד: גיבוי הגדרות ה-SMTP של Supabase Auth לפני המעבר הזמני ל-Gmail (23.10).
# הסיסמה לא נשמרת ולא מודפסת — רק האם קיימת. הגיבוי (בלי סיסמה) נשמר כ-artifact מוצפן? לא — רק בהערה, כי אין בו סוד.
set +e +o pipefail
API="https://api.supabase.com/v1/projects/$PROD_REF/config/auth"
for T in "$OLDTOK" "$TOK"; do
  [ -n "$T" ] || continue
  C=$(curl -sS -m 30 -o /tmp/cfg.json -w '%{http_code}' -H "Authorization: Bearer $T" "$API" || echo 000)
  [ "$C" = 200 ] && break
done
[ "$C" = 200 ] || stop "קריאת הגדרות Auth נכשלה (HTTP $C) — אין הרשאה; לא נגעתי בכלום"
ann notice "smtp-backup" "$(jq -c '{smtp_host, smtp_port, smtp_user: (if .smtp_user then (.smtp_user|tostring|.[0:6])+"…" else null end), smtp_pass_set: ((.smtp_pass // "") != ""), smtp_admin_email, smtp_sender_name, smtp_max_frequency, rate_limit_email_sent, mailer_autoconfirm, site_url, subj_confirm: .mailer_subjects_confirmation, subj_recovery: .mailer_subjects_recovery}' /tmp/cfg.json | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/<email:&>/g' | sed -E 's/<email:life\.through\.numbers333@gmail\.com>/app-gmail/g; s/<email:[^>]*>/<email>/g')"
# טביעה של ההגדרות (בלי סיסמה) — כדי לזהות אחר כך שהשתנו
ann notice "smtp-fp" "fingerprint=$(jq -c '{smtp_host, smtp_port, smtp_user, smtp_admin_email, smtp_sender_name}' /tmp/cfg.json | sha256sum | cut -c1-12)"
rm -f /tmp/cfg.json
ann notice "prod-result" "smtpbackup — קריאה בלבד"
