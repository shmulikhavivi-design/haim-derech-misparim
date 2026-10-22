#!/usr/bin/env bash
# stagecapply — רק אחרי אישור מפורש של הבעלים: מיילי ביטול דרך Brevo + התראות + משימת המיילים.
# 1) בודק את מפתח Brevo (קריאה בלבד) ושולח מאומת  2) סודות לפונקציות: BREVO_API_KEY, MAIL_FROM, MAIL_REPLY_TO
# 3) פורס hdm-billing-worker  4) מתקין 18 + 19  5) מפעיל את הפונקציה פעם אחת (התור ריק — לא נשלח מייל) ומאמת.
# לא נוגע בתשלומים, במנויים או בחיובים. לא מחייב.
A="https://api.supabase.com/v1/projects/$PROD_REF"; RW="$A/database/query"; RO="$A/database/query/read-only"
FROM='life.through.numbers333@gmail.com'
q(){ curl -sS -m 120 -o /tmp/ca.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$1" -d "$(jq -nc --arg q "$2" '{query:$q}')" || echo 000; }
[ -n "${GH_BREVO_API:-}" ] || stop "BREVO_API_KEY לא מוגדר ב-GitHub (סביבה production). לא שונה כלום."
echo "::add-mask::$GH_BREVO_API"
BA=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -H "api-key: $GH_BREVO_API" https://api.brevo.com/v3/account || echo 000)
[ "$BA" = 200 ] || stop "מפתח Brevo לא תקף (HTTP $BA). לא שונה כלום."
SV=$(curl -sS -m 30 -H "api-key: $GH_BREVO_API" https://api.brevo.com/v3/senders | jq -r --arg f "$FROM" '[.senders[]? | select(.active and ((.email|ascii_downcase)==$f))] | length')
[ "${SV:-0}" -ge 1 ] || stop "השולח של האפליקציה לא מאומת/פעיל ב-Brevo. לא שונה כלום."
ann notice "c-brevo" "✅ מפתח Brevo תקף, השולח מאומת"
q "$RO" "select (select count(*) from public.hdm_release_marker where version in ('production_billing_alerts','production_email_worker_cron')) n" >/dev/null
[ "$(jq -r '.[0].n' /tmp/ca.json)" = 0 ] || stop "18/19 כבר מותקנים. לא שונה כלום."
umask 077; F=$(mktemp); printf 'BREVO_API_KEY=%s\nMAIL_FROM=%s\nMAIL_REPLY_TO=%s\n' "$GH_BREVO_API" "$FROM" "$FROM" > "$F"
OUT=$(SUPABASE_ACCESS_TOKEN="$TOK" supabase secrets set --project-ref "$PROD_REF" --env-file "$F" 2>&1) || { rm -f "$F"; stop "הגדרת הסודות נכשלה: $(echo "$OUT" | grep -vE 'sbp_|xkeysib|eyJ' | tail -2)"; }
rm -f "$F"; ann notice "c-secrets" "✅ BREVO_API_KEY, MAIL_FROM, MAIL_REPLY_TO הוגדרו בפונקציות"
OUT=$(cd "$ROOT" && SUPABASE_ACCESS_TOKEN="$TOK" supabase functions deploy hdm-billing-worker --project-ref "$PROD_REF" --use-api --no-verify-jwt 2>&1) || stop "פריסה נכשלה: $(echo "$OUT" | grep -vE 'sbp_|eyJ' | tail -3)"
ann notice "c-deploy" "✅ hdm-billing-worker נפרסה"
for f in 18_production_billing_alerts 19_production_email_worker_cron; do
  C=$(q "$RW" "$(cat "$ROOT/supabase/production/$f.sql")"); [ "$C" = 201 ] || [ "$C" = 200 ] || stop "$f נכשל (HTTP $C): $(jq -r '.message // tostring' /tmp/ca.json | cut -c1-400)"
  ann notice "c-$f" "✅ $f הותקן"
done
q "$RW" "select net.http_post(url := 'https://$PROD_REF.supabase.co/functions/v1/hdm-billing-worker', headers := jsonb_build_object('content-type','application/json','x-hdm-cron',(select decrypted_secret from vault.decrypted_secrets where name='hdm_cron_secret')), body := '{}'::jsonb, timeout_milliseconds := 60000) id" >/dev/null
RID=$(jq -r '.[0].id' /tmp/ca.json); sleep 20
q "$RO" "select status_code, left(content, 200) c from net._http_response where id = $RID" >/dev/null
ann notice "c-worker-call" "הפעלה ראשונה של פונקציית המיילים (התור ריק): $(jq -c '.[0]' /tmp/ca.json)"
q "$RO" "select (select string_agg(jobname||' ['||schedule||'] '||active, ', ' order by jobname) from cron.job) jobs, (select count(*) from public.hdm_billing_alert_recipients) recipients, (select count(*) from public.hdm_payments) payments, (select count(*) from public.hdm_renewal_charges) charges" >/dev/null
ann notice "c-after" "אחרי: $(jq -c '.[0]' /tmp/ca.json)"
ann notice "prod-result" "stagecapply הסתיים"
