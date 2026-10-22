#!/usr/bin/env bash
# stagecrehearse — חזרה על Production בעסקה שמסתיימת תמיד ב-rollback: התקנת 18 (התראות) + 19 (משימת המיילים),
# ומעליהן בדיקות 35 (כל המסלולים + התראות) ו-37 (כפילויות, ביטול, החזר, תור מיילים). לא נשמר כלום, אין חיוב ואין מייל.
FPQ="select (select count(*) from auth.users) u, (select count(*) from public.hdm_subscriptions) s, (select count(*) from public.hdm_payments) p, (select count(*) from public.hdm_renewal_charges) r, (select count(*) from public.hdm_email_outbox) e, (select count(*) from cron.job) j, to_regclass('public.hdm_billing_alerts') is not null a, (select md5(string_agg(collection||'|'||id||'|'||data::text, ',' order by collection, id)) from public.docs) h"
fp(){ curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" -d "$(jq -nc --arg q "$FPQ" '{query:$q}')" | jq -c '.[0]'; }
pre=$(fp); ann notice "c-before" "לפני: $pre"
run(){ # $1 = שם, $2 = קובץ בדיקה או ריק
  Q=$(python3 -I - "$ROOT/supabase/production/18_production_billing_alerts.sql" "$ROOT/supabase/production/19_production_email_worker_cron.sql" "${2:-}" <<'PY'
import sys,re
def body(p):
    s=open(p,encoding='utf-8').read()
    s=re.sub(r'(?m)^begin;\s*$','',s,count=1); i=s.rfind('commit;'); return s[:i]
out="begin;\n"+body(sys.argv[1])+body(sys.argv[2])
out+="""do $c$ begin
  if (select count(*) from public.hdm_billing_alert_recipients) <> 1 then raise exception 'HDM_C_FAIL recipients'; end if;
  if (select count(*) from cron.job where jobname in ('hdm-billing-worker','hdm-billing-alerts-scan','hdm-morning-renewals') and active) <> 3 then raise exception 'HDM_C_FAIL cron jobs=%', (select string_agg(jobname,',') from cron.job); end if;
end $c$;
"""
if len(sys.argv)>3 and sys.argv[3]:
    t=open(sys.argv[3],encoding='utf-8').read()
    t=re.sub(r'(?m)^begin;\s*$','',t,count=1)
    i=t.rfind("select area || ' — '"); t=t[:i]
    out+=t+"""do $h$ begin raise exception 'HDM_TESTS passed=% total=% failed=%', (select count(*) filter (where ok) from t_res), (select count(*) from t_res),
  coalesce((select string_agg(x, ' | ') from (select area||' — '||name||' (צפוי '||exp||', התקבל '||coalesce(got,'∅')||')' x from t_res where not ok limit 8) z), '-'); end $h$;
"""
else:
    out+="do $h$ begin raise exception 'HDM_TESTS passed=1 total=1 failed=- jobs=%', (select string_agg(jobname||' ['||schedule||']', ', ' order by jobname) from cron.job); end $h$;\n"
out+="rollback;\n"; print(out)
PY
) || stop "בניית $1 נכשלה"
  C=$(curl -sS -m 240 -o /tmp/cr.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
  MSG=$(jq -r '.message // tostring' /tmp/cr.json 2>/dev/null | grep -oE 'HDM_(TESTS|C_FAIL).*' | head -1 | cut -c1-1500)
  case "$MSG" in HDM_TESTS*) p=$(echo "$MSG" | sed -E 's/.*passed=([0-9]+).*/\1/'); n=$(echo "$MSG" | sed -E 's/.*total=([0-9]+).*/\1/')
      [ "$p" = "$n" ] && ann notice "c-$1" "✅ $1: $p/$n $(echo "$MSG" | grep -o 'jobs=.*')" || ann error "c-$1" "❌ $MSG";;
    *) ann error "c-$1" "❌ HTTP $C $(jq -r '.message // tostring' /tmp/cr.json | cut -c1-700)";; esac
}
run "התקנת 18+19" ""
run "35 כל המסלולים + התראות" "$ROOT/supabase/staging_secure/35_staging_plans_alerts_tests.sql"
run "37 כפילויות, ביטול, החזר, מיילים" "$ROOT/supabase/staging_secure/37_staging_cancel_email_tests.sql"
post=$(fp)
[ "$pre" = "$post" ] && ann notice "c-unchanged" "✅ Production זהה לפני ואחרי (משתמשים, מנויים, תשלומים, חיובים, מיילים, משימות, טביעת אצבע) — שום דבר לא נשמר" || ann error "c-unchanged" "❗ הבדל: $post"
ann notice "prod-result" "stagecrehearse הסתיים — הכול בוטל"
