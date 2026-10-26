#!/usr/bin/env bash
# postdeploy (26.10) — READ ONLY אחרי פריסת שתי הפונקציות. בלי חיוב, בלי חידוש, בלי שינוי במסד או בסודות.
set +e +o pipefail
FT="${FN_TOK:-}"; [ -n "$FT" ] && echo "::add-mask::$FT"
A="https://api.supabase.com/v1/projects/$PROD_REF"; F="https://$PROD_REF.supabase.co/functions/v1"
PK=$(sed -n "s/^ *var STAGING_PUBLISHABLE_KEY = '\(sb_publishable_[A-Za-z0-9_-]*\)'.*/\1/p" "$ROOT/index.html" | head -1)
q(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
# 1. הקוד הפרוס הוא הקוד החדש
V=$(curl -sS -m 30 -H "Authorization: Bearer $FT" "$A/functions" | jq -r '[.[] | select(.slug|test("morning-checkout|hdm-billing-worker")) | "\(.slug) v\(.version)"] | join(", ")')
curl -sS -m 60 -o /tmp/mc.bin -H "Authorization: Bearer $FT" "$A/functions/morning-checkout/body"; curl -sS -m 60 -o /tmp/wk.bin -H "Authorization: Bearer $FT" "$A/functions/hdm-billing-worker/body"
m(){ grep -aq "$1" "$2" && echo ✅ || echo "לא נמצא"; }
ann notice "pd-1-code" "גרסאות: $V | morning-checkout: חזרה לאותה כתובת $(m returnBaseFor /tmp/mc.bin), רשימת כתובות $(m haimderechmisparim.com /tmp/mc.bin) | worker: השלמה בצד השרת $(m sweepCardCheckouts /tmp/wk.bin)"
rm -f /tmp/mc.bin /tmp/wk.bin
# 2. הפונקציות עונות כמו שצריך — בלי משתמש, בלי Morning, בלי חיוב
o=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X OPTIONS -H 'Origin: https://haimderechmisparim.com' "$F/morning-checkout")
n=$(curl -sS -m 30 -o /tmp/r1 -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{"step":"start","origin":"https://haimderechmisparim.com"}' "$F/morning-checkout")
b=$(curl -sS -m 30 -o /tmp/r2 -w '%{http_code}' -X POST -H 'authorization: Bearer x.y.z' -H 'content-type: application/json' -d '{"step":"complete"}' "$F/morning-checkout")
w=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST -H 'x-hdm-cron: wrong' "$F/hdm-billing-worker")
ann notice "pd-2-http" "morning-checkout: OPTIONS $o (צפוי 200) | בלי התחברות $n $(cat /tmp/r1) (צפוי 401) | טוקן מזויף $b (צפוי 401) | worker בלי סוד $w (צפוי 401)"
# 3. המשימה המתוזמנת (כל 5 דקות) אחרי הפריסה — ממתינים לריצה הבאה ומציגים את תשובתה
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ); R=""
for i in $(seq 1 24); do
  R=$(q "select json_agg(json_build_object('t', to_char(created at time zone 'Asia/Jerusalem','HH24:MI:SS'), 'status', status_code, 'body', left(content::text, 400), 'err', error_msg) order by created desc) j from (select * from net._http_response where created > '$T0'::timestamptz order by created desc limit 3) x" | jq -c '.[0].j // empty' 2>/dev/null)
  [ -n "$R" ] && [ "$R" != null ] && break; sleep 20
done
ann notice "pd-3-worker" "${R:-לא נמצאה ריצה חדשה תוך 8 דקות (או שאין גישת קריאה ליומן net)}"
# 4. הרשאות המסלולים
P=$(q "select string_agg(plan||': ₪'||(price_agorot/100.0)||' | דירוג '||can_rate||' פירוט '||rating_details||' 🎯 '||can_target||' צ''אט '||can_chat||' שיחות '||coalesce(monthly_new_chats::text,'∞')||' ניתוח '||extended_analysis, ' ;; ' order by sort_order) s from public.hdm_plans" | jq -r '.[0].s // .')
S=$(q "select string_agg(plan||'='||on_sale, ' ') s from public.hdm_plan_sale" | jq -r '.[0].s // .')
ann notice "pd-4-plans" "$P || במכירה: $S"
# 5. הרשמה/התחברות/מיילים
H=$(curl -sS -m 30 -o /tmp/h -w '%{http_code}' -H "apikey: $PK" "https://$PROD_REF.supabase.co/auth/v1/health"); 
C=$(curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/config/auth" | jq -c '{site_url, confirm_email: (.mailer_autoconfirm == false), signup_open: (.disable_signup == false), smtp_host, smtp_sender: .smtp_admin_email, smtp_pass_set: ((.smtp_pass // "") != "")}')
E=$(q "select json_build_object('signups_24h',(select count(*) from auth.users where created_at>now()-interval '24 hours'),'confirmed_24h',(select count(*) from auth.users where email_confirmed_at>now()-interval '24 hours'),'logins_2h',(select count(*) from auth.sessions where created_at>now()-interval '2 hours'),'outbox',(select json_object_agg(coalesce(status,'?'),n) from (select status, count(*) n from public.hdm_email_outbox group by 1) z)) j" | jq -c '.[0].j // .')
ann notice "pd-5-auth" "Auth health: HTTP $H | הגדרות: $C | פעילות: $E"
# 6. האתר החי לא השתנה
L=$(curl -sS -m 30 "https://haimderechmisparim.com/?v=$(date +%s)"); ann notice "pd-6-site" "האתר: #47 $(echo "$L" | grep -q hdmPendSet && echo ✅ || echo ❌) | #48 $(echo "$L" | grep -q hdm-age-range-btn && echo ✅ || echo ❌) | 🎯 $(echo "$L" | grep -q hdmSetTargetMark && echo ✅ || echo ❌)"
rm -f /tmp/r1 /tmp/r2 /tmp/h
ann notice "prod-result" "✅ postdeploy: קריאה בלבד"
