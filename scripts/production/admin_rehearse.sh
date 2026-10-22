#!/usr/bin/env bash
# adminrehearse — לוח הניהול (20) + 31 בדיקות (39) על Production בעסקה שמסתיימת תמיד ב-rollback. לא נשמר כלום.
set +e +o pipefail
RW="https://api.supabase.com/v1/projects/$PROD_REF/database/query"; RO="$RW/read-only"
FPQ="select (select count(*) from auth.users) u, (select count(*) from public.hdm_subscriptions) s, (select count(*) from public.hdm_payments) p, (select count(*) from public.docs) d, to_regclass('public.hdm_admins') is not null adm, (select md5(string_agg(id||data::text, ',' order by id)) from public.docs where collection='profiles') h"
fp(){ curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$FPQ" '{query:$q}')" | jq -c '.[0]'; }
pre=$(fp)
Q=$(python3 -I - "$ROOT/supabase/production/20_production_admin_panel.sql" "$ROOT/supabase/staging_secure/39_staging_admin_panel_tests.sql" <<'PY'
import sys,re
a=open(sys.argv[1],encoding='utf-8').read(); a=re.sub(r'(?m)^begin;\s*$','',a,count=1); a=a[:a.rfind('commit;')]
t=open(sys.argv[2],encoding='utf-8').read(); t=re.sub(r'(?m)^begin;\s*$','',t,count=1); t=t[:t.rfind("select area || ' — '")]
print("begin;\n"+a+t+"""do $h$ begin raise exception 'HDM_TESTS passed=% total=% failed=% admins=%', (select count(*) filter (where ok) from t_res), (select count(*) from t_res),
  coalesce((select string_agg(name||' (צפוי '||exp||', התקבל '||coalesce(got,'∅')||')', ' | ') from t_res where not ok), '-'), (select count(*) from public.hdm_admins); end $h$;
rollback;""")
PY
)
C=$(curl -sS -m 240 -o /tmp/ar.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
M=$(jq -r '.message // tostring' /tmp/ar.json | grep -o 'HDM_TESTS.*' | head -1 | cut -c1-1200)
[ -n "$M" ] && ann notice "adm-rehearse" "$M" || ann error "adm-rehearse" "HTTP $C $(jq -r '.message // tostring' /tmp/ar.json | cut -c1-600)"
post=$(fp); [ "$pre" = "$post" ] && ann notice "adm-unchanged" "✅ Production זהה לפני ואחרי — לוח הניהול לא הותקן, שום דבר לא נשמר ($post)" || ann error "adm-unchanged" "❗ $pre → $post"
ann notice "prod-result" "adminrehearse הסתיים — הכול בוטל"
