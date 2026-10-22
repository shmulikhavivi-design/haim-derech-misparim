#!/usr/bin/env bash
# hiderehearse — 21 (הפרופיל של הבעלים מוסתר) + בדיקות 41 ו-39 על Production בעסקה שמסתיימת תמיד ב-rollback, ובדיקה מה לקוח רואה. לא נשמר כלום.
set +e +o pipefail
RW="https://api.supabase.com/v1/projects/$PROD_REF/database/query"; RO="$RW/read-only"
FPQ="select (select count(*) from auth.users) u, (select count(*) from public.docs) d, (select count(*) from public.hdm_subscriptions) s, (select count(*) from public.hdm_payments) p, to_regclass('public.hdm_hidden_profiles') is not null hidden_installed"
fp(){ curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$FPQ" '{query:$q}')" | jq -c '.[0]'; }
pre=$(fp)
for T in 41_staging_hidden_profiles_tests 39_staging_admin_panel_tests; do
Q=$(python3 -I - "$ROOT/supabase/production/21_production_owner_admin_only.sql" "$ROOT/supabase/staging_secure/$T.sql" <<'PY'
import sys,re
a=open(sys.argv[1],encoding='utf-8').read(); a=re.sub(r'(?m)^begin;\s*$','',a,count=1); a=a[:a.rfind('commit;')]
t=open(sys.argv[2],encoding='utf-8').read(); t=re.sub(r'(?m)^begin;\s*$','',t,count=1); t=t[:t.rfind("select area || ' — '")]
extra = """do $o$ declare pid text := (select profile_id from public.hdm_hidden_profiles limit 1); other uuid := (select a.auth_user_id from public.hdm_accounts a join auth.users u on u.id=a.auth_user_id join public.docs d on d.collection='profiles' and d.id=a.profile_id where md5(lower(u.email))<>'162e004328485070b0af8b256ad2e798' and u.email not like 'life.through.numbers333+%' limit 1);
begin
  insert into t_res (area, name, exp, got, ok) values ('Production', 'לקוח אמיתי לא רואה את פרופיל הבעלים', '0',
    (select r from (select pg_temp.as_user(other, format('select count(*)::text from public.docs where collection = ''profiles'' and id = %L', pid)) r) z), null);
  update t_res set ok = (got = 'ok:0') where name = 'לקוח אמיתי לא רואה את פרופיל הבעלים';
  insert into t_res (area, name, exp, got, ok) values ('Production', 'המנוי של הבעלים לא השתנה', 'basic|active|true',
    (select plan||'|'||status||'|'||(to_jsonb(s)->>'auto_renew') from public.hdm_subscriptions s where profile_id = pid), null);
  update t_res set ok = (got = 'basic|active|true') where name = 'המנוי של הבעלים לא השתנה';
end $o$;
""" if '41_' in sys.argv[2] else ''
print("begin;\n"+a+t+extra+"""do $h$ begin raise exception 'HDM_TESTS passed=% total=% failed=%', (select count(*) filter (where ok) from t_res), (select count(*) from t_res),
  coalesce((select string_agg(name||' (צפוי '||exp||', התקבל '||coalesce(got,'∅')||')', ' | ') from t_res where not ok), '-'); end $h$;
rollback;""")
PY
)
C=$(curl -sS -m 240 -o /tmp/hr.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
M=$(jq -r '.message // tostring' /tmp/hr.json | grep -o 'HDM_TESTS.*' | head -1 | cut -c1-900)
[ -n "$M" ] && ann notice "hide-$T" "$M" || ann error "hide-$T" "HTTP $C $(jq -r '.message // tostring' /tmp/hr.json | cut -c1-500)"
done
post=$(fp); [ "$pre" = "$post" ] && ann notice "hide-unchanged" "✅ Production זהה לפני ואחרי — לא הוסתר בפועל ($post)" || ann error "hide-unchanged" "❗ $pre → $post"
source "$HERE/readiness_brevo.sh"
ann notice "prod-result" "hiderehearse הסתיים — הכול בוטל"
