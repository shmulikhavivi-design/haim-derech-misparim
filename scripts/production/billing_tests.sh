#!/usr/bin/env bash
# billingtests — בדיקות המנויים (18 תשלום/חידוש, 20 שדרוג/חידוש, 22 ביטול, 25 Morning) על Production האמיתי,
# כל קובץ בעסקה אחת שמסתיימת תמיד ב-rollback. משתמשי בדיקה מומצאים בתוך העסקה בלבד. לא נשמר כלום, אין חיוב.
FPQ=$(cat <<'SQL'
select (select count(*) from public.docs) d, (select count(*) from auth.users) u, (select count(*) from public.hdm_subscriptions) s, (select count(*) from public.hdm_consents) c, (select count(*) from public.hdm_renewal_charges) r, (select count(*) from public.hdm_checkouts) k, (select md5(string_agg(collection||'|'||id||'|'||data::text, ',' order by collection, id)) from public.docs) h
SQL
)
fp(){ curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" -d "$(jq -nc --arg q "$FPQ" '{query:$q}')" | jq -c '.[0]'; }
pre=$(fp); TOTP=0; TOTN=0
for f in 18_staging_billing_tests 20_staging_billing_upgrade_tests 22_staging_billing_cancel_tests 25_staging_billing_morning_tests 31_staging_vip_soon_tests 33_staging_card_flow_tests; do
  Q=$(python3 -I - "$ROOT/supabase/staging_secure/$f.sql" <<'PY'
import sys
s=open(sys.argv[1],encoding='utf-8').read().rstrip()
if '31_staging_vip' not in sys.argv[1]:   # תשתית ה-VIP נבדקת כשהוא פתוח זמנית — בתוך העסקה שמבוטלת
    s=s.replace('begin;', "begin;\ndo $o$ begin if to_regclass('public.hdm_plan_sale') is not null then update public.hdm_plan_sale set on_sale = true where plan = 'vip'; end if; end $o$;", 1)
i=s.rfind("select 'עברו '"); assert i>0
print(s[:i]+r"""
do $hdm$ begin
  raise exception 'HDM_TESTS passed=% total=% failed=%', (select count(*) filter (where ok) from t_res), (select count(*) from t_res),
    coalesce((select string_agg(x, ' | ') from (select row_to_json(t)::text x from t_res t where not ok limit 8) z), '-');
end $hdm$;
rollback;
""")
PY
) || stop "בניית $f נכשלה"
  C=$(curl -sS -m 240 -o /tmp/bt.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
  MSG=$(jq -r '.message // tostring' /tmp/bt.json 2>/dev/null | grep -o 'HDM_TESTS.*' | head -1 | cut -c1-1500)
  if [ -n "$MSG" ]; then p=$(echo "$MSG" | sed -E 's/.*passed=([0-9]+).*/\1/'); n=$(echo "$MSG" | sed -E 's/.*total=([0-9]+).*/\1/'); TOTP=$((TOTP+p)); TOTN=$((TOTN+n))
    [ "$p" = "$n" ] && ann notice "tests-$f" "✅ $p/$n" || ann error "tests-$f" "❌ $MSG"
  else ann error "tests-$f" "❌ לא הושלם: HTTP $C $(jq -r '.message // tostring' /tmp/bt.json | cut -c1-600)"; fi
done
post=$(fp)
[ "$pre" = "$post" ] && ann notice "tests-unchanged" "✅ Production זהה לפני ואחרי (משתמשים, מנויים, חיובים, טביעת אצבע)" || ann error "tests-unchanged" "❗ הבדל לפני/אחרי"
ann notice "prod-result" "billingtests: $TOTP/$TOTN — שום שינוי לא נשמר"
