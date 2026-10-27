#!/usr/bin/env bash
# mailhealth — READ-ONLY (27.10): בדיקת תקינות תשתית המייל הקיימת לפני התראת 🎯.
# רק GET ושאילתות דרך נקודת הקצה לקריאה בלבד. לא נשלח מייל, לא שונתה הגדרה, לא נגעו במשתמשים. בלי כתובות/מפתחות בפלט.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
scrub(){ sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g; s/eyJ[A-Za-z0-9._-]+/<jwt>/g'; }
# 1. תור מיילי הביטול (התשתית שהתראת 🎯 תשתמש בה): נשלחו / ממתינים / נכשלו
Q1="select json_build_object('outbox_total',count(*),'sent',count(*) filter (where sent_at is not null),'pending',count(*) filter (where sent_at is null),
 'pending_failed',count(*) filter (where sent_at is null and attempts>0),'last_sent',max(sent_at),'last_error',(select left(last_error,60) from public.hdm_email_outbox where last_error is not null order by id desc limit 1)) r from public.hdm_email_outbox"
ann notice "mh-1-outbox" "1. תור מיילי הביטול (Production): $(roq "$Q1" | jq -c '.[0].r // .' | scrub | cut -c1-600)"
# 2. המשימה המתוזמנת של שליחת המיילים + 10 ההרצות האחרונות
Q2="select json_build_object('job',(select json_agg(json_build_object('name',jobname,'schedule',schedule,'active',active)) from cron.job where jobname in ('hdm-billing-worker','hdm-billing-alerts-scan')),
 'last_runs',(select json_agg(x) from (select d.status, left(coalesce(d.return_message,''),60) msg, d.start_time from cron.job_run_details d join cron.job j on j.jobid=d.jobid where j.jobname='hdm-billing-worker' order by d.start_time desc limit 5) x),
 'http_last',(select json_agg(y) from (select status_code, left(coalesce(content::text,''),120) body, created from net._http_response order by created desc limit 5) y)) r"
ann notice "mh-2-cron" "2. משימת שליחת המיילים: $(roq "$Q2" | jq -c '.[0].r // .' | scrub | cut -c1-1800)"
# 3. מותקן ב-Production: סמנים רלוונטיים, ושהתראת 🎯 עוד לא מותקנת
Q3="select json_build_object('markers',(select json_agg(version order by version) from public.hdm_release_marker where version ~ '(email|billing_alerts|target)'),
 'target_email_installed',to_regclass('public.hdm_target_email_outbox') is not null,'docs_triggers',(select json_agg(tgname order by tgname) from pg_trigger where tgrelid='public.docs'::regclass and not tgisinternal)) r"
ann notice "mh-3-installed" "3. Production: $(roq "$Q3" | jq -c '.[0].r // .' | cut -c1-900)"
# 4. סודות הפונקציות (שמות בלבד) + הפונקציות הפרוסות
if [ -n "${FN_TOK:-}" ]; then
  echo "::add-mask::$FN_TOK"
  SN=$(curl -sS -m 30 -H "Authorization: Bearer $FN_TOK" "$A/secrets" | jq -c '[.[]?.name] | map(select(test("BREVO|MAIL_|HDM_CRON|TARGET|RESEND|DRY_RUN")))')
  FL=$(curl -sS -m 30 -H "Authorization: Bearer $FN_TOK" "$A/functions" | jq -c '[.[]? | {slug, status, version}]')
  ann notice "mh-4-functions" "4. סודות פונקציות (שמות בלבד): $SN | פונקציות: $FL"
else ann warning "mh-4-functions" "4. אין טוקן פונקציות — דילוג"; fi
# 5. Brevo — חשבון ומכסה (GET בלבד), ו-7 ימים אחרונים
K=$(printf '%s' "${GH_BREVO_API:-}" | tr -d '[:space:]"'"'")
if [ -n "$K" ]; then
  echo "::add-mask::$K"
  AC=$(curl -sS -m 30 -H "api-key: $K" -H 'accept: application/json' https://api.brevo.com/v3/account | jq -c '{plan:[.plan[]? | {type, credits, creditsType}], relay_enabled:.relay.enabled}')
  AG=$(curl -sS -m 30 -G -H "api-key: $K" -H 'accept: application/json' https://api.brevo.com/v3/smtp/statistics/aggregatedReport --data-urlencode days=7 | jq -c '{requests,delivered,hardBounces,softBounces,blocked,invalid,spamReports}')
  SD=$(curl -sS -m 30 -H "api-key: $K" -H 'accept: application/json' https://api.brevo.com/v3/senders | jq -c '[.senders[]? | {domain:(.email|split("@")[1]), active}]')
  CA=$(curl -sS -m 30 -G -H "api-key: $K" -H 'accept: application/json' https://api.brevo.com/v3/smtp/statistics/events --data-urlencode days=30 --data-urlencode tags=hdm-cancel_confirmed --data-urlencode limit=20 | jq -c '[.events[]? | .event] | group_by(.) | map({(.[0]): length}) | add')
  ann notice "mh-5-brevo" "5. Brevo: חשבון $AC | 7 ימים: $AG | שולחים: $SD | מיילי ביטול (API) 30 יום: ${CA:-null}"
else ann warning "mh-5-brevo" "5. מפתח Brevo API לא זמין לתהליך"; fi
ann notice "prod-result" "mailhealth — קריאה בלבד. לא נשלח מייל, לא שונתה הגדרה, לא נגעו בשום משתמש."
