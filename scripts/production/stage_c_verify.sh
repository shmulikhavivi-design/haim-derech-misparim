#!/usr/bin/env bash
# stagecverify — קריאה בלבד אחרי שלב ג׳: אבטחה, נתונים, משימות. בלי שליחה ובלי שינוי.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"
FN="https://$PROD_REF.supabase.co/functions/v1/hdm-billing-worker"
C1=$(curl -sS -m 30 -o /tmp/w.json -w '%{http_code}' -X POST "$FN" -H 'content-type: application/json' -d '{}' || echo 000)
C2=$(curl -sS -m 30 -o /tmp/w2.json -w '%{http_code}' -X POST "$FN" -H 'content-type: application/json' -H 'x-hdm-cron: wrong-secret-0000000000000000000000000000' -d '{}' || echo 000)
ann notice "cv-1-security" "פונקציית המיילים: בלי סוד → HTTP $C1 | עם סוד שגוי → HTTP $C2 (צפוי 401 בשניהם)"
Q=$(cat <<'SQL'
select json_build_object(
 'users', (select count(*) from auth.users), 'profiles', (select count(*) from public.docs where collection='profiles'),
 'subscriptions', (select count(*) from public.hdm_subscriptions), 'payments', (select count(*) from public.hdm_payments), 'renewal_charges', (select count(*) from public.hdm_renewal_charges),
 'owner_sub', (select plan||'/'||status||'/renew='||(to_jsonb(s)->>'auto_renew') from public.hdm_subscriptions s),
 'emails_pending', (select count(*) from public.hdm_email_outbox where sent_at is null), 'emails_sent', (select count(*) from public.hdm_email_outbox where sent_at is not null),
 'alerts_open', (select count(*) from public.hdm_billing_alerts where resolved_at is null), 'alert_recipients', (select count(*) from public.hdm_billing_alert_recipients),
 'claim_fn', to_regprocedure('public.hdm_email_outbox_claim(integer)') is not null,
 'users_can_claim', has_function_privilege('authenticated', 'public.hdm_email_outbox_claim(integer)', 'execute'),
 'users_can_read_alerts_table', has_table_privilege('authenticated', 'public.hdm_billing_alerts', 'select'),
 'jobs', (select string_agg(jobname||'='||active, ', ' order by jobname) from cron.job),
 'last_worker_runs', (select string_agg(status||'@'||to_char(start_time at time zone 'Asia/Jerusalem','HH24:MI'), ', ' order by start_time desc) from (select r.status, r.start_time from cron.job_run_details r join cron.job j on j.jobid=r.jobid where j.jobname='hdm-billing-worker' order by r.start_time desc limit 3) x)) r
SQL
)
curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$Q" '{query:$q}')" > /tmp/v.json
ann notice "cv-2-state" "$(jq -c '.[0].r // .' /tmp/v.json | cut -c1-1200)"
ann notice "prod-result" "stagecverify — קריאה בלבד"
