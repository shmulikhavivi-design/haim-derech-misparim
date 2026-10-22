#!/usr/bin/env bash
# billingdeploy  — שלב 1 של ההפעלה (משנה Production! רק באישור מפורש): 08 → סודות לפונקציות → פריסת 3 פונקציות.
#                   התשלום פתוח רק לבעלים (HDM_BILLING_ALLOWED_USERS = מזהה הבעלים); לכל השאר 403. האפליקציה הציבורית לא משתנה.
# billingdeploycheck — אותן בדיקות מקדימות בלי שום שינוי.
OWNER_MD5='162e004328485070b0af8b256ad2e798'   # md5 של כתובת האימייל של הבעלים (לא הכתובת עצמה)
RO="https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only"
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
OID=$(roq "select id from auth.users where md5(lower(email))='$OWNER_MD5' and email_confirmed_at is not null" | jq -r '.[0].id // empty')
[ -n "$OID" ] && ann notice "deploy-owner" "✅ חשבון הבעלים נמצא ומאומת (מזהה …${OID: -6})" || stop "חשבון הבעלים לא נמצא/לא מאומת ב-Production"
[ -n "${MORNING_CLIENT_ID:-}" ] && [ -n "${MORNING_CLIENT_SECRET:-}" ] || stop "חסרים מפתחות Morning בסביבה production"
MK=$(roq "select (select count(*) from public.hdm_release_marker where version='production_billing_v1') b" | jq -r '.[0].b')
ann notice "deploy-08" "08 כבר הותקן: $([ "$MK" = 1 ] && echo כן || echo לא)"
supabase --version >/dev/null 2>&1 && ann notice "deploy-cli" "Supabase CLI: $(supabase --version)" || stop "Supabase CLI לא זמין"
if [ "$MODE" = billingdeploycheck ]; then ann notice "prod-result" "billingdeploycheck — הכול מוכן לפריסה, שום דבר לא שונה"; exit 0; fi

# ---- מכאן משנה Production ----
if [ "$MK" != 1 ]; then
  C=$(curl -sS -m 180 -o /tmp/m8.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query" -d "$(jq -nc --rawfile q "$ROOT/supabase/production/08_production_billing.sql" '{query:$q}')" || echo 000)
  MK=$(roq "select (select count(*) from public.hdm_release_marker where version='production_billing_v1') b" | jq -r '.[0].b')
  [ "$MK" = 1 ] || stop "08 לא הותקן — לא נשמר כלום (הכול או כלום). HTTP $C $(jq -r '.message // empty' /tmp/m8.json | cut -c1-400)"
  ann notice "deploy-08" "✅ 08 הותקן"
fi
WT=$(openssl rand -hex 32); CS=$(openssl rand -hex 32); WS=$(openssl rand -hex 32); for v in "$WT" "$CS" "$WS"; do echo "::add-mask::$v"; done
umask 077; F=$(mktemp)
{ echo "HDM_ENV=production"; echo "MORNING_LIVE=1"; echo "MORNING_API_BASE=https://api.greeninvoice.co.il/api/v1"
  echo "MORNING_PLUGIN_ID=53ed9395-02de-4902-a1dd-28dd3f74a5fa"
  echo "MORNING_WEBHOOK_TOKEN=$WT"; echo "MORNING_WEBHOOK_SECRET=$WS"; echo "HDM_CRON_SECRET=$CS"
  echo "HDM_APP_URL=https://haim-derech-misparim.pages.dev"; echo "HDM_BILLING_ALLOWED_USERS=$OID"; echo "DRY_RUN=1"; } > "$F"
export SUPABASE_ACCESS_TOKEN="$TOK"
OUT=$(cd "$ROOT" && supabase secrets set --project-ref "$PROD_REF" --env-file "$F" 2>&1); RC=$?; rm -f "$F"
# מפתחות Morning עוברים ב-API כ-JSON (לא ב-env-file: ערך עם # נחתך שם) — תיקון 22.10
if [ $RC = 0 ]; then jq -n --arg id "$MORNING_CLIENT_ID" --arg sec "$MORNING_CLIENT_SECRET" '[{name:"MORNING_CLIENT_ID",value:$id},{name:"MORNING_CLIENT_SECRET",value:$sec}]' > /tmp/sk.json
  C=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/secrets" --data-binary @/tmp/sk.json || echo 000); shred -u /tmp/sk.json
  [ "$C" = 200 ] || [ "$C" = 201 ] || RC=1; fi
[ $RC = 0 ] || stop "קביעת סודות נכשלה: $(printf '%s' "$OUT" | grep -vE 'sbp_|eyJ' | tail -n 5 | tr '\n' ' ' | cut -c1-400)"
OUT=$(cd "$ROOT" && supabase functions deploy morning-checkout morning-webhook morning-renewals --project-ref "$PROD_REF" --use-api --no-verify-jwt 2>&1) || stop "פריסה נכשלה: $(printf '%s' "$OUT" | tail -n 6 | tr '\n' ' ' | cut -c1-400)"
ann notice "deploy-functions" "✅ $(printf '%s' "$OUT" | grep -iE 'deployed' | tail -n 4 | tr '\n' ' ' | cut -c1-400)"
# סוד משימת החידוש נשמר גם ב-Vault (למשימה המתוזמנת שתופעל אחרי הבדיקות). לא מודפס.
VQ="do \$v\$ begin if exists (select 1 from vault.secrets where name='hdm_cron_secret') then perform vault.update_secret((select id from vault.secrets where name='hdm_cron_secret'), '$CS'); else perform vault.create_secret('$CS', 'hdm_cron_secret', 'x-hdm-cron for morning-renewals'); end if; end \$v\$;"
C=$(curl -sS -m 60 -o /tmp/vs.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query" -d "$(jq -nc --arg q "$VQ" '{query:$q}')" || echo 000); rm -f /tmp/vs.json
ann notice "deploy-vault" "סוד החידוש ב-Vault: HTTP $C"
sleep 8; FN="https://$PROD_REF.supabase.co/functions/v1"
a=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST "$FN/morning-checkout" -H 'content-type: application/json' -d '{}')
b=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST "$FN/morning-renewals")
c=$(curl -sS -m 30 -X POST "$FN/morning-renewals" -H "x-hdm-cron: $CS")
d=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST "$FN/morning-webhook" -H 'content-type: application/json' -d '{"id":"fake"}')
ann notice "deploy-verify" "checkout בלי משתמש: $a (צפוי 401/403) · renewals בלי סוד: $b (צפוי 401) · renewals עם סוד: $c (צפוי dryRun) · webhook מזויף: $d (צפוי 401/403)"
ann notice "prod-result" "✅ billingdeploy: 08 + סודות + פונקציות. התשלום פתוח לבעלים בלבד; האפליקציה הציבורית לא שונתה."
