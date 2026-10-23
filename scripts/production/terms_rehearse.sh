#!/usr/bin/env bash
# termsrehearse — חזרה על התקנת התקנון 2026-10-21 (קובץ 09) ב-Production בעסקה שמסתיימת תמיד ב-rollback.
# בודק: ההתקנה עוברת, הגרסה הנדרשת מתעדכנת, אף רשומה לא משתנה, ומשתמש קיים (הבעלים, בתוך העסקה בלבד) מקבל "אישור מחדש" ומצליח לאשר.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"
F09="$ROOT/supabase/production/09_production_terms_paid_plans.sql"; [ -f "$F09" ] || F09="$HERE/09_rehearse_copy.sql"
FPQ="select json_build_object('required',(select max(version) from public.hdm_terms_versions where requires_reconsent),'versions',(select count(*) from public.hdm_terms_versions),'consents',(select count(*) from public.hdm_consents),'users',(select count(*) from auth.users),'docs',(select count(*) from public.docs),'markers',(select count(*) from public.hdm_release_marker)) r"
fp(){ curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d "$(jq -nc --arg q "$FPQ" '{query:$q}')" | jq -c 'if type=="array" then .[0].r else . end'; }
pre=$(fp); ann notice "t-before" "לפני: $pre"
Q=$(python3 -I - "$F09" <<'PY'
import sys,re
s=open(sys.argv[1],encoding='utf-8').read()
s=re.sub(r'(?m)^begin;\s*$','',s,count=1); s=s[:s.rfind('commit;')]
out="begin;\n"+s+"""
do $t$ declare me uuid; st1 jsonb; acc jsonb; st2 jsonb; begin
  select u.id into me from auth.users u where md5(lower(u.email))='162e004328485070b0af8b256ad2e798';
  perform set_config('request.jwt.claims', json_build_object('sub', me::text, 'role', 'authenticated')::text, true);
  st1 := public.hdm_terms_status();
  acc := public.hdm_accept_terms('2026-10-21', 'gate');
  st2 := public.hdm_terms_status();
  raise exception 'HDM_TESTS required=% | existing_user_before: accepted=% reconsent=% | accept=% | after: accepted=% | users_needing_reconsent=%',
    public.hdm_required_terms_version(), st1->>'accepted', st1->>'reconsent', acc->>'accepted', st2->>'accepted',
    (select count(*) from public.hdm_accounts a where not exists (select 1 from public.hdm_consents c where c.user_id=a.auth_user_id and c.version='2026-10-21'));
end $t$;
rollback;
"""
print(out)
PY
)
R=$(curl -sS -m 90 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query" -d "$(jq -nc --arg q "$Q" '{query:$q}')")
ann notice "t-result" "$(echo "$R" | jq -r '.message // .' | grep -oE 'HDM_TESTS[^"]*|ERROR[^"]{0,300}|עצירה[^"]{0,200}' | head -2 | cut -c1-700)"
post=$(fp); ann notice "t-after" "אחרי (צריך להיות זהה ל'לפני'): $post | identical=$([ "$pre" = "$post" ] && echo yes || echo NO)"
ann notice "prod-result" "termsrehearse — rollback, שום דבר לא נשמר"
