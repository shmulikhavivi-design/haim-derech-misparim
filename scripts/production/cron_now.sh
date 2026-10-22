#!/usr/bin/env bash
# cronnow — מריץ עכשיו בדיוק את הפקודה של משימת החידוש (net.http_post עם הסוד מ-Vault) ובודק את התשובה. אין מנוי שהגיע מועדו → בלי חיוב.
A="https://api.supabase.com/v1/projects/$PROD_REF"; RW="$A/database/query"; RO="$RW/read-only"
q(){ curl -sS -m 120 -o /tmp/cn.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$1" -d "$(jq -nc --arg q "$2" '{query:$q}')" || echo 000; }
q "$RO" "select (select count(*) from public.hdm_payments) p, (select count(*) from public.hdm_renewal_charges) r" >/dev/null; B=$(jq -c '.[0]' /tmp/cn.json)
q "$RO" "select command from cron.job where jobname='hdm-morning-renewals'" >/dev/null; CMD=$(jq -r '.[0].command' /tmp/cn.json)
[ -n "$CMD" ] && [ "$CMD" != null ] || stop "משימת החידוש לא נמצאה"
C=$(q "$RW" "$CMD"); RID=$(jq -r '.[0].http_post // .[0] | tostring' /tmp/cn.json | grep -o '[0-9]\+' | head -1)
sleep 15
q "$RW" "select status_code, left(content, 300) content, error_msg, timed_out from net._http_response where id = ${RID:-0}" >/dev/null
ann notice "cron-now" "הפעלת פקודת המשימה עכשיו: HTTP $C · בקשה $RID · תשובת הפונקציה: $(jq -c '.[0] // .' /tmp/cn.json)"
q "$RO" "select jobname, schedule, active from cron.job where jobname='hdm-morning-renewals'" >/dev/null; ann notice "cron-job" "$(jq -c '.[0]' /tmp/cn.json)"
q "$RO" "select (select count(*) from public.hdm_payments) p, (select count(*) from public.hdm_renewal_charges) r" >/dev/null; A2=$(jq -c '.[0]' /tmp/cn.json)
[ "$B" = "$A2" ] && ann notice "cron-nocharge" "✅ לפני/אחרי זהה: $A2 — אין חיוב" || ann error "cron-nocharge" "❗ לפני $B אחרי $A2"
ann notice "prod-result" "cronnow הסתיים"
