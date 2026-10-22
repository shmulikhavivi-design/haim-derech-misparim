#!/usr/bin/env bash
# cronrehearse — 10 על Production בעסקה שמבוטלת תמיד. cronapply — 10 באמת (רק באישור מפורש). cronrun — הפעלה ידנית אחת של הפונקציה עם הסוד.
F="$ROOT/supabase/production/10_production_renewals_cron.sql"
RO="https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only"; RW="https://api.supabase.com/v1/projects/$PROD_REF/database/query"
q(){ curl -sS -m 120 -o /tmp/cr.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$1" -d "$(jq -nc --arg q "$2" '{query:$q}')" || echo 000; }
ext=$(q "$RO" "select string_agg(name||':'||coalesce(installed_version,'-'), ',') e from pg_available_extensions where name in ('pg_cron','pg_net','supabase_vault')"; jq -r '.[0].e // .message' /tmp/cr.json)
ann notice "cron-ext" "הרחבות (זמין:מותקן): $ext"
if [ "$MODE" = cronrehearse ]; then
  Q=$(python3 -I -c "import sys;s=open(sys.argv[1]).read().rstrip();i=s.rfind('commit;');print(s[:i]+\"do \$h\$ begin raise exception 'HDM_CRON_OK jobs=%', (select string_agg(jobname||' '||schedule, ',') from cron.job); end \$h\$;\nrollback;\")" "$F")
  C=$(q "$RW" "$Q"); MSG=$(jq -r '.message // tostring' /tmp/cr.json | cut -c1-600)
  case "$MSG" in *HDM_CRON_OK*) ann notice "cron-rehearse" "✅ $(echo "$MSG" | grep -o 'HDM_CRON_OK[^"]*')";; *) ann error "cron-rehearse" "❌ HTTP $C $MSG";; esac
  C=$(q "$RO" "select count(*) n from cron.job where jobname='hdm-morning-renewals'"); ann notice "cron-after" "משימות אחרי החזרה (צפוי 0 או ללא cron): HTTP $C $(jq -c '.[0] // .message' /tmp/cr.json)"
elif [ "$MODE" = cronapply ]; then
  C=$(q "$RW" "$(cat "$F")"); C=$(q "$RO" "select count(*) n from cron.job where jobname='hdm-morning-renewals' and active"); 
  [ "$(jq -r '.[0].n' /tmp/cr.json)" = 1 ] && ann notice "cron-apply" "✅ משימת החידוש פעילה (כל שעה, דקה 17)" || stop "משימת החידוש לא נוצרה"
fi
ann notice "prod-result" "$MODE הסתיים"
