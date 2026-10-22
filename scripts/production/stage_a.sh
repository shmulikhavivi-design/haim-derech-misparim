#!/usr/bin/env bash
# stagearehearse / stageaapply — שלב א׳ (אישור הבעלים 22.10 14:12): 17 + פונקציות אפשרות 2 (לבעלים בלבד) + חידוש חודשי (10, DRY_RUN כבוי).
# לא מחייב: אין מנוי שמועד החידוש שלו הגיע (הבעלים — 22.11). לא נוגע במפתחות Morning ולא ברשימת המורשים.
A="https://api.supabase.com/v1/projects/$PROD_REF"; RW="$A/database/query"; RO="$RW/read-only"
q(){ curl -sS -m 120 -o /tmp/sa.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$1" -d "$(jq -nc --arg q "$2" '{query:$q}')" || echo 000; }
F17="$ROOT/supabase/production/17_production_billing_customers.sql"; F10="$ROOT/supabase/production/10_production_renewals_cron.sql"
STATE="select (select count(*) from public.hdm_payments) payments, (select count(*) from public.hdm_renewal_charges) renewal_charges, (select count(*) from public.hdm_checkouts where status='pending') pending_checkouts, (select count(*) from auth.users) users, (select row_to_json(s) from (select plan, status, auto_renew, (current_period_end at time zone 'Asia/Jerusalem')::text renew_local from public.hdm_subscriptions where profile_id='reg_mupj1bkt75rzke') s) owner, (select card_last4 from public.hdm_billing_tokens where profile_id='reg_mupj1bkt75rzke') card"
q "$RO" "$STATE" >/dev/null; BEFORE=$(jq -c '.[0]' /tmp/sa.json); ann notice "stagea-before" "$BEFORE"
rh(){ local f="$1" tag="$2"; local Q; Q=$(python3 -I -c "import sys;s=open(sys.argv[1]).read().rstrip();i=s.rfind('commit;');print(s[:i]+\"do \$r\$ begin raise exception 'HDM_${tag}_OK'; end \$r\$;\nrollback;\")" "$f")
  local C; C=$(q "$RW" "$Q"); local M; M=$(jq -r '.message // tostring' /tmp/sa.json | cut -c1-300)
  case "$M" in *HDM_${tag}_OK*) ann notice "stagea-rehearse-$tag" "✅ חזרה עברה (בוטלה)";; *) stop "חזרה $tag נעצרה — לא שונה כלום: HTTP $C $M";; esac; }
rh "$F17" 17
if q "$RO" "select (to_regclass('cron.job') is not null and exists (select 1 from cron.job where jobname='hdm-morning-renewals'))::text j" >/dev/null && [ "$(jq -r '.[0].j' /tmp/sa.json)" = true ]; then ann notice "stagea-cron" "משימת החידוש כבר קיימת"; else rh "$F10" 10; fi
if [ "$MODE" = stagearehearse ]; then ann notice "prod-result" "stagearehearse — שום דבר לא שונה"; exit 0; fi

# ---- מכאן: שינוי Production (שלב א׳) ----
# 1. טבלת לקוחות Morning
if q "$RO" "select (to_regclass('public.hdm_billing_customers') is not null)::text j" >/dev/null && [ "$(jq -r '.[0].j' /tmp/sa.json)" != true ]; then
  C=$(q "$RW" "$(cat "$F17")"); [ "$C" = 201 ] || [ "$C" = 200 ] || stop "17 נכשל — לא שונה כלום: HTTP $C $(jq -r '.message // empty' /tmp/sa.json | cut -c1-200)"
fi
ann notice "stagea-17" "✅ טבלת לקוחות Morning מותקנת"
# קישור הבעלים ללקוח ה-Morning שלו (מהמסמך של התשלום) נעשה אוטומטית בפעם הראשונה שהשרת צריך (sync / חיוב)
# 2. פריסת הפונקציות (קוד אפשרות 2). הסודות לא משתנים.
export SUPABASE_ACCESS_TOKEN="$TOK"
OUT=$(cd "$ROOT" && supabase functions deploy morning-checkout morning-webhook morning-renewals --project-ref "$PROD_REF" --use-api --no-verify-jwt 2>&1) || stop "פריסה נכשלה: $(printf '%s' "$OUT" | tail -n 6 | tr '\n' ' ' | cut -c1-400)"
ann notice "stagea-deploy" "✅ $(printf '%s' "$OUT" | grep -iE 'deployed' | tail -n 3 | tr '\n' ' ' | cut -c1-300)"
# 3. חידוש חודשי: DRY_RUN כבוי + משימה מתוזמנת כל שעה
C=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/secrets" -d '[{"name":"DRY_RUN","value":"0"}]' || echo 000)
[ "$C" = 200 ] || [ "$C" = 201 ] || stop "כיבוי DRY_RUN נכשל: HTTP $C"
if q "$RO" "select (to_regclass('cron.job') is not null and exists (select 1 from cron.job where jobname='hdm-morning-renewals'))::text j" >/dev/null && [ "$(jq -r '.[0].j' /tmp/sa.json)" != true ]; then
  C=$(q "$RW" "$(cat "$F10")"); [ "$C" = 201 ] || [ "$C" = 200 ] || stop "10 נכשל: HTTP $C $(jq -r '.message // empty' /tmp/sa.json | cut -c1-200)"
fi
q "$RO" "select jobname, schedule, active from cron.job where jobname='hdm-morning-renewals'" >/dev/null; ann notice "stagea-cron" "✅ $(jq -c '.[0]' /tmp/sa.json)"
sleep 20
# 4. הרצה ידנית אחת של החידוש עכשיו (אין מנוי שהגיע מועדו → בלי חיוב) — מוכיח שההרשאה והחיבור עובדים
q "$RW" "select decrypted_secret s from vault.decrypted_secrets where name='hdm_cron_secret'" >/dev/null; CS=$(jq -r '.[0].s' /tmp/sa.json); echo "::add-mask::$CS"; rm -f /tmp/sa.json
R1=$(curl -sS -m 60 -X POST "https://$PROD_REF.supabase.co/functions/v1/morning-renewals" -H "x-hdm-cron: $CS" -H 'content-type: application/json' -d '{}')
FN="https://$PROD_REF.supabase.co/functions/v1"
a=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST "$FN/morning-checkout" -H 'content-type: application/json' -d '{"step":"sync"}')
b=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST "$FN/morning-renewals")
d=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST "$FN/morning-webhook" -H 'content-type: application/json' -d '{"id":"fake"}')
ann notice "stagea-verify" "חידוש עכשיו: $R1 (צפוי 0 חיובים) · checkout בלי משתמש: $a (צפוי 401) · renewals בלי סוד: $b (צפוי 401) · webhook מזויף: $d (צפוי 401)"
q "$RO" "$STATE" >/dev/null; AFTER=$(jq -c '.[0]' /tmp/sa.json); ann notice "stagea-after" "$AFTER"
[ "$(echo "$BEFORE" | jq -c '{payments, renewal_charges}')" = "$(echo "$AFTER" | jq -c '{payments, renewal_charges}')" ] && ann notice "stagea-nocharge" "✅ לא נוצר שום תשלום או חיוב חידוש" || ann error "stagea-nocharge" "❗ שינוי בתשלומים — לבדיקה"
ann notice "prod-result" "✅ stageaapply: שלב א׳ הושלם. הסליקה ללקוחות לא נפתחה (לבעלים בלבד)."
