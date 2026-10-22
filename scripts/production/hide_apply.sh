#!/usr/bin/env bash
# hideapply — הסתרת הפרופיל של הבעלים מהיכרויות (21), באישור הבעלים 22.10 22:16. חזרה (בוטלה) → התקנה → בדיקות (בוטלו) → לפני/אחרי.
# לא מוחק כלום ולא משנה את המנוי או את התשלומים.
RW="https://api.supabase.com/v1/projects/$PROD_REF/database/query"; RO="$RW/read-only"
FPQ="select (select count(*) from auth.users) u, (select count(*) from public.docs) d, (select md5(string_agg(id||data::text, ',' order by id)) from public.docs where collection='profiles') h, (select md5(string_agg(profile_id||plan||status||coalesce(current_period_end::text,'')||coalesce(to_jsonb(s)->>'auto_renew',''),',' order by profile_id)) from public.hdm_subscriptions s) sh, (select count(*) from public.hdm_payments) p, (select count(*) from public.hdm_billing_tokens) t"
fp(){ curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$FPQ" '{query:$q}')" | jq -c '.[0]'; }
q(){ curl -sS -m 240 -o /tmp/ha.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --arg q "$1" '{query:$q}')" || echo 000; }
build(){ python3 -I - "$1" "$ROOT/supabase/staging_secure/$2.sql" <<'PY'
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
res(){ jq -r '.message // tostring' /tmp/ha.json | grep -o 'HDM_TESTS.*' | head -1 | cut -c1-700; }
ok_all(){ echo "$1" | grep -qE 'passed=([0-9]+) total=\1 '; }
pre=$(fp)
for T in 41_staging_hidden_profiles_tests 39_staging_admin_panel_tests; do
  q "$(build "$ROOT/supabase/production/21_production_owner_admin_only.sql" $T)" >/dev/null; M=$(res); ok_all "$M" || stop "החזרה ($T) נכשלה — לא הותקן כלום: $M"
done
ann notice "hide-1-rehearse" "✅ חזרה (בוטלה): 41 ו-39 עברו"
C=$(q "$(cat "$ROOT/supabase/production/21_production_owner_admin_only.sql")"); case "$C" in 200|201) ;; *) stop "ההתקנה נכשלה (HTTP $C): $(jq -r '.message // tostring' /tmp/ha.json | cut -c1-500)";; esac
ann notice "hide-2-apply" "✅ קובץ 21 הותקן — הפרופיל של הבעלים מוסתר מהיכרויות"
R=""; for T in 41_staging_hidden_profiles_tests 39_staging_admin_panel_tests; do q "$(build - $T)" >/dev/null; M=$(res); ok_all "$M" && R="$R ✅ $T: ${M%% failed*}" || R="$R ❌ $T: $M"; done
ann notice "hide-3-after" "אחרי ההתקנה (בדיקות בוטלו):$R"
post=$(fp)
python3 -c "import json,sys;a=json.loads(sys.argv[1]);b=json.loads(sys.argv[2]);sys.exit(0 if a==b else 1)" "$pre" "$post" && ann notice "hide-4-unchanged" "✅ משתמשים, פרופילים, מנויים (כולל חידוש אוטומטי), תשלומים וכרטיסים — זהים לפני ואחרי" || ann error "hide-4-unchanged" "❗ $pre → $post"
VQ=$(cat <<'SQL'
with me as (select a.profile_id pid from public.hdm_accounts a join auth.users u on u.id=a.auth_user_id where md5(lower(u.email))='162e004328485070b0af8b256ad2e798')
select json_build_object('hidden', (select count(*) from public.hdm_hidden_profiles h, me where h.profile_id=me.pid), 'is_admin', (select count(*) from public.hdm_admins a join auth.users u on u.id=a.auth_user_id where md5(lower(u.email))='162e004328485070b0af8b256ad2e798'),
 'profile_kept', (select count(*) from public.docs d, me where d.collection='profiles' and d.id=me.pid), 'policy_has_hidden', (select position('hdm_profile_hidden' in pg_get_expr(polqual, polrelid)) > 0 from pg_policy where polname='profiles_read'),
 'target_trigger', (select count(*) from pg_trigger where tgname='hdm_block_hidden_target'), 'marker', (select version from public.hdm_release_marker where version='production_owner_admin_only')) r
SQL
)
curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$VQ" '{query:$q}')" > /tmp/hv.json
ann notice "hide-5-state" "מצב: $(jq -c '.[0].r' /tmp/hv.json)"
ann notice "prod-result" "hideapply הסתיים"
