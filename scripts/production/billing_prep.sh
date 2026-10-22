#!/usr/bin/env bash
# billingprep — חזרה על 08+09 על ה-Production האמיתי בתוך עסקה שתמיד מבוטלת (rollback), ובדיקת הרשאות פונקציות/סודות לקריאה בלבד.
# לא נשמר שום שינוי, לא נפרסות פונקציות, לא נקבעים סודות, לא מודפס שום ערך סודי.
Q=$(python3 -I - "$ROOT/supabase/production/08_production_billing.sql" "$ROOT/supabase/production/09_production_terms_paid_plans.sql" <<'PY'
import sys,re
a=open(sys.argv[1],encoding='utf-8').read(); b=open(sys.argv[2],encoding='utf-8').read()
a=a[:a.rstrip().rfind('commit;')]
b=re.sub(r'(?m)^begin;\s*$','',b,count=1); b=b[:b.rstrip().rfind('commit;')]
print(a+"\n"+b+r"""
do $hdm$ begin
  raise exception 'HDM_BILLING_REHEARSAL_OK markers=% plans=% subs=% consents=% docs=% users=% terms=% payments_tbl=%',
    (select string_agg(version, ',' order by version) from public.hdm_release_marker),
    (select string_agg(plan||':'||price_agorot, ',' order by sort_order) from public.hdm_plans),
    (select count(*) from public.hdm_subscriptions),
    (select count(*) from public.hdm_consents),
    (select count(*) from public.docs),
    (select count(*) from auth.users),
    public.hdm_required_terms_version(),
    (to_regclass('public.hdm_payments') is not null);
end $hdm$;
rollback;
""")
PY
) || stop "בניית החזרה נכשלה"
pre=$(curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" -d '{"query":"select (select count(*) from public.docs) d, (select count(*) from auth.users) u, (select count(*) from public.hdm_subscriptions) s, (select count(*) from public.hdm_consents) c, (select string_agg(version, ',' order by version) from public.hdm_release_marker) m, (select md5(string_agg(collection||'|'||id||'|'||data::text, ',' order by collection, id)) from public.docs) h"}' | jq -c '.[0]')
C=$(curl -sS -m 180 -o /tmp/rb.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
MSG=$(jq -r '.message // tostring' /tmp/rb.json 2>/dev/null | cut -c1-1500)
case "$MSG" in *HDM_BILLING_REHEARSAL_OK*) ann notice "prod-billing-rehearse" "✅ 08+09 עברו על Production ובוטלו (rollback): $(printf '%s' "$MSG" | grep -o 'HDM_BILLING_REHEARSAL_OK[^"]*' | head -1)";;
               *) ann error "prod-billing-rehearse" "❌ נעצר (לא נשמר כלום): HTTP $C $MSG";; esac
post=$(curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" -d '{"query":"select (select count(*) from public.docs) d, (select count(*) from auth.users) u, (select count(*) from public.hdm_subscriptions) s, (select count(*) from public.hdm_consents) c, (select string_agg(version, ',' order by version) from public.hdm_release_marker) m, (select md5(string_agg(collection||'|'||id||'|'||data::text, ',' order by collection, id)) from public.docs) h"}' | jq -c '.[0]')
[ "$pre" = "$post" ] && ann notice "prod-billing-unchanged" "✅ אומת: Production זהה לפני ואחרי (מונים + טביעת אצבע)" || ann error "prod-billing-unchanged" "❗ הבדל לפני/אחרי — לבדיקה"
C=$(curl -sS -m 30 -o /tmp/fn.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://api.supabase.com/v1/projects/$PROD_REF/functions" || echo 000)
ann notice "prod-functions-read" "Edge Functions (קריאה): HTTP $C פונקציות קיימות: $(jq -r '[.[]?.slug] | join(",")' /tmp/fn.json 2>/dev/null)"
C=$(curl -sS -m 30 -o /tmp/sc.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://api.supabase.com/v1/projects/$PROD_REF/secrets" || echo 000)
ann notice "prod-secrets-read" "Function secrets (שמות בלבד): HTTP $C $(jq -r '[.[]?.name] | join(",")' /tmp/sc.json 2>/dev/null)"
rm -f /tmp/sc.json /tmp/fn.json /tmp/rb.json
ann notice "prod-result" "billingprep הסתיים — שום שינוי לא נשמר"
