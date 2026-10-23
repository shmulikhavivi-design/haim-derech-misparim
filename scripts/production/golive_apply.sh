#!/usr/bin/env bash
# goliveapply — שלב ב׳ (באישור הבעלים 23.10 14:34): אחרי שהאתר החי בגרסת ההשקה —
#   1. התקנת התקנון 2026-10-21 (קובץ 09: כולם יאשרו מחדש; לא משנה משתמשים, פרופילים או אישורים קודמים)
#   2. הסרת HDM_BILLING_ALLOWED_USERS (הרכישה של בסיסי ופלוס נפתחת לכולם; VIP נשאר חסום בשרת)
# עוצר בכל חריגה. אין חיוב, אין מייל, אין מחיקת משתמשים, אין שינוי במנויים.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d "$(jq -nc --arg q "$1" '{query:$q}')" | jq -c 'if type=="array" then .[0] else . end'; }
for S in https://shmulikhavivi-design.github.io/haim-derech-misparim/ https://haim-derech-misparim.pages.dev/; do
  H=$(curl -sS -m 30 "$S?nocache=$RANDOM")
  echo "$H" | grep -q "HDM_TERMS_VERSION = '2026-10-21'" && echo "$H" | grep -q 'var HDM_BILLING_LIVE = true' || stop "האתר $(echo $S | cut -d/ -f3) עדיין לא בגרסת ההשקה — לא נגעתי בכלום"
done
ann notice "g0-site" "✅ שני האתרים בגרסת ההשקה"
FP="select json_build_object('users',(select count(*) from auth.users),'docs',(select count(*) from public.docs),'consents',(select count(*) from public.hdm_consents),'subs',(select string_agg(profile_id||':'||plan||':'||status||':'||coalesce(to_jsonb(s)->>'auto_renew',''),',') from public.hdm_subscriptions s),'payments',(select count(*) from public.hdm_payments),'checkouts',(select count(*) from public.hdm_checkouts),'renewals',(select count(*) from public.hdm_renewal_charges),'on_sale',(select string_agg(plan||'='||on_sale,' ' order by plan) from public.hdm_plan_sale),'prices',(select string_agg(plan||'='||price_agorot,' ' order by price_agorot) from public.hdm_plans)) r"
pre=$(roq "$FP" | jq -c .r); [ -n "$pre" ] && [ "$pre" != null ] || stop "לא הצלחתי לקרוא את המצב לפני — לא נגעתי בכלום"
ann notice "g1-before" "לפני: $(echo "$pre" | jq -c 'del(.subs)') subs_hash=$(echo "$pre" | jq -r .subs | md5sum | cut -c1-8)"
REQ=$(roq "select max(version) v from public.hdm_terms_versions where requires_reconsent" | jq -r .v)
if [ "$REQ" = "2026-10-21" ]; then ann notice "g2-terms" "התקנון 2026-10-21 כבר מותקן — מדלג"; else
  Q=$(cat "$ROOT/supabase/production/09_production_terms_paid_plans.sql")
  R=$(curl -sS -m 120 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query" -d "$(jq -nc --arg q "$Q" '{query:$q}')")
  echo "$R" | jq -e 'type=="array"' >/dev/null || stop "התקנת התקנון נכשלה: $(echo "$R" | jq -r '.message // .' | cut -c1-400) — ההגבלה לא הוסרה"
  REQ=$(roq "select max(version) v from public.hdm_terms_versions where requires_reconsent" | jq -r .v)
  [ "$REQ" = "2026-10-21" ] || stop "אחרי ההתקנה הגרסה הנדרשת היא $REQ — ההגבלה לא הוסרה"
  ann notice "g2-terms" "✅ התקנון 2026-10-21 הותקן — כל המשתמשים יתבקשו לאשר מחדש בכניסה הבאה"
fi
mid=$(roq "$FP" | jq -c .r); [ "$pre" = "$mid" ] || stop "הנתונים השתנו אחרי התקנת התקנון: $mid — ההגבלה לא הוסרה"
curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/secrets" | jq -r '.[].name' > /tmp/names.txt
if grep -qx HDM_BILLING_ALLOWED_USERS /tmp/names.txt; then
  C=$(curl -sS -m 30 -o /tmp/del.json -w '%{http_code}' -X DELETE -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/secrets" -d '["HDM_BILLING_ALLOWED_USERS"]')
  [ "$C" = 200 ] || stop "הסרת ההגבלה נכשלה: HTTP $C $(head -c 200 /tmp/del.json)"
fi
curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/secrets" > /tmp/sc.json
jq -e 'any(.[]; .name=="HDM_BILLING_ALLOWED_USERS")' /tmp/sc.json >/dev/null && stop "ההגבלה עדיין קיימת"
cmp1(){ local want have; want=$(printf '%s' "$2" | sha256sum | cut -d' ' -f1); have=$(jq -r --arg n "$1" '.[]|select(.name==$n)|.value' /tmp/sc.json); [ "$want" = "$have" ] && echo "$1=$2" || echo "$1≠$2"; }
ann notice "g3-open" "✅ ההגבלה הוסרה — רכישת בסיסי ופלוס פתוחה לכולם | $(cmp1 DRY_RUN 0) $(cmp1 MORNING_LIVE 1) $(cmp1 HDM_ENV production) | BREVO_API_KEY: $(jq -e 'any(.[]; .name=="BREVO_API_KEY")' /tmp/sc.json >/dev/null && echo קיים || echo חסר)"
rm -f /tmp/sc.json /tmp/names.txt
post=$(roq "$FP" | jq -c .r)
[ "$pre" = "$post" ] && ann notice "g4-after" "✅ משתמשים, פרופילים, אישורים קודמים, מנויים, תשלומים, מחירים ומצב VIP — זהים לפני ואחרי" || ann error "g4-after" "שינוי לא צפוי: $post"
ann notice "prod-result" "goliveapply הסתיים"
