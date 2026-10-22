#!/usr/bin/env bash
# adminapply — התקנת לוח הניהול (20) ב-Production, באישור הבעלים 22.10 21:19. קודם חזרה בעסקה שמבוטלת (20+39),
# אחר כך התקנה אמיתית, ואז 39 שוב (מבוטל) ובדיקת "לפני/אחרי". לא נוגע במשתמשים, מנויים או תשלומים.
RW="https://api.supabase.com/v1/projects/$PROD_REF/database/query"; RO="$RW/read-only"
FPQ="select (select count(*) from auth.users) u, (select count(*) from public.hdm_subscriptions) s, (select md5(string_agg(profile_id||plan||status||coalesce(current_period_end::text,''),',' order by profile_id)) from public.hdm_subscriptions) sh, (select count(*) from public.hdm_payments) p, (select count(*) from public.docs) d, (select md5(string_agg(id||data::text, ',' order by id)) from public.docs where collection='profiles') h"
fp(){ curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$FPQ" '{query:$q}')" | jq -c '.[0]'; }
q(){ curl -sS -m 240 -o /tmp/aa.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --arg q "$1" '{query:$q}')" || echo 000; }
build(){ python3 -I - "$1" "$ROOT/supabase/staging_secure/39_staging_admin_panel_tests.sql" <<'PY'
import sys,re
f=sys.argv[1]; t=open(sys.argv[2],encoding='utf-8').read(); t=re.sub(r'(?m)^begin;\s*$','',t,count=1); t=t[:t.rfind("select area || ' — '")]
a=''
if f != '-':
    a=open(f,encoding='utf-8').read(); a=re.sub(r'(?m)^begin;\s*$','',a,count=1); a=a[:a.rfind('commit;')]
print("begin;\n"+a+t+"""do $h$ begin raise exception 'HDM_TESTS passed=% total=% failed=%', (select count(*) filter (where ok) from t_res), (select count(*) from t_res),
  coalesce((select string_agg(name||' (צפוי '||exp||', התקבל '||coalesce(got,'∅')||')', ' | ') from t_res where not ok), '-'); end $h$;
rollback;""")
PY
}
res(){ jq -r '.message // tostring' /tmp/aa.json | grep -o 'HDM_TESTS.*' | head -1 | cut -c1-900; }
pre=$(fp)
C=$(q "$(build "$ROOT/supabase/production/20_production_admin_panel.sql")"); M=$(res)
echo "$M" | grep -qE 'passed=([0-9]+) total=\1 ' || stop "החזרה נכשלה — לא הותקן כלום: ${M:-HTTP $C $(jq -r '.message // tostring' /tmp/aa.json | cut -c1-400)}"
ann notice "adm-1-rehearse" "✅ חזרה (בוטלה): $M"
C=$(q "$(cat "$ROOT/supabase/production/20_production_admin_panel.sql")"); case "$C" in 200|201) ;; *) stop "ההתקנה נכשלה (HTTP $C): $(jq -r '.message // tostring' /tmp/aa.json | cut -c1-500)";; esac
ann notice "adm-2-apply" "✅ קובץ 20 הותקן ב-Production"
C=$(q "$(build -)"); M=$(res); echo "$M" | grep -qE 'passed=([0-9]+) total=\1 ' && ann notice "adm-3-after" "✅ אחרי ההתקנה (בדיקות בוטלו): $M" || ann error "adm-3-after" "❌ $M"
post=$(fp)
python3 -c "import json,sys;a=json.loads(sys.argv[1]);b=json.loads(sys.argv[2]);sys.exit(0 if a==b else 1)" "$pre" "$post" && ann notice "adm-4-unchanged" "✅ משתמשים, פרופילים, מנויים ותשלומים זהים לפני ואחרי" || ann error "adm-4-unchanged" "❗ $pre → $post"
AQ=$(cat <<'SQL'
select (select count(*) from public.hdm_admins) admins,
 (select count(*) from public.hdm_admins a join auth.users u on u.id=a.auth_user_id where md5(lower(u.email))='162e004328485070b0af8b256ad2e798') owner_is_admin,
 (select coalesce(string_agg(privilege_type, ','), 'אין') from information_schema.role_table_grants where table_name in ('hdm_admins','hdm_test_accounts') and grantee in ('anon','authenticated')) api_grants_on_admin_tables,
 has_function_privilege('anon', 'public.hdm_admin_dashboard(boolean)', 'execute') anon_can_call_dashboard,
 has_function_privilege('authenticated', 'public.hdm_admin_base()', 'execute') users_can_call_base,
 (select version from public.hdm_release_marker where version='production_admin_panel_v2') marker
SQL
)
curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$AQ" '{query:$q}')" > /tmp/ab.json
ann notice "adm-5-access" "הרשאות: $(jq -c '.[0]' /tmp/ab.json)"
ann notice "prod-result" "adminapply הסתיים"
