#!/usr/bin/env bash
# adminhealthrehearse — חזרה על התקנת 22 (לוח הניהול: מצב חיבורים) ב-Production בעסקה שמסתיימת תמיד ב-rollback.
# קורא ל-hdm_admin_health בתור הבעלים (בתוך העסקה בלבד), ובודק שמשתמש רגיל נחסם. שום דבר לא נשמר.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"
FPQ="select json_build_object('users',(select count(*) from auth.users),'docs',(select count(*) from public.docs),'subs',(select count(*) from public.hdm_subscriptions),'payments',(select count(*) from public.hdm_payments),'alerts',(select count(*) from public.hdm_billing_alerts),'markers',(select count(*) from public.hdm_release_marker),'fn',to_regprocedure('public.hdm_admin_health()') is not null) r"
fp(){ curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d "$(jq -nc --arg q "$FPQ" '{query:$q}')" | jq -c 'if type=="array" then .[0].r else . end'; }
pre=$(fp); ann notice "h-before" "לפני: $pre"
Q=$(python3 -I - "$HERE/22_rehearse_copy.sql" <<'PY'
import sys,re
s=open(sys.argv[1],encoding='utf-8').read()
s=re.sub(r'(?m)^begin;\s*$','',s,count=1); s=s[:s.rfind('commit;')]
print("begin;\n"+s+"""
do $t$ declare me uuid; other uuid; h jsonb; denied text := 'no'; res boolean; begin
  select u.id into me from auth.users u where md5(lower(u.email))='162e004328485070b0af8b256ad2e798';
  perform set_config('request.jwt.claims', json_build_object('sub', me::text, 'role', 'authenticated')::text, true);
  h := public.hdm_admin_health();
  res := public.hdm_admin_resolve_alert(-1);
  select u.id into other from auth.users u where not exists (select 1 from public.hdm_admins a where a.auth_user_id = u.id) limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', other::text, 'role', 'authenticated')::text, true);
  begin perform public.hdm_admin_health(); exception when others then denied := sqlerrm; end;
  raise exception 'HDM_TESTS emails=% jobs=% billing=% terms=% alertsOpen=% payments=% resolve_missing=% non_admin=%',
    h->'emails', (select string_agg((j->>'name')||':'||(j->>'ok'), ',') from jsonb_array_elements(h->'jobs') j), h->'billing', h->'terms', h->'alertsOpen',
    jsonb_array_length(h->'recentPayments'), res, denied;
end $t$;
rollback;""")
PY
)
R=$(curl -sS -m 120 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query" -d "$(jq -nc --arg q "$Q" '{query:$q}')")
ann notice "h-result" "$(echo "$R" | jq -r '.message // .' | grep -oE 'HDM_TESTS.*|ERROR.{0,400}' | head -1 | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/<email>/g' | cut -c1-1400)"
post=$(fp); ann notice "h-after" "אחרי: $post | זהה=$([ "$pre" = "$post" ] && echo כן || echo לא)"
ann notice "prod-result" "adminhealthrehearse — rollback, שום דבר לא נשמר"
