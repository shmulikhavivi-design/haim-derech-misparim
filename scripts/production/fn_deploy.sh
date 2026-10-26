#!/usr/bin/env bash
# =====================================================================
# fndeploy / fnrollback (26.10) — רק אחרי אישור מפורש של הבעלים בצ'אט.
#   fndeploy:   (1) 20_production_card_sweep.sql (פונקציית קריאה בלבד, service_role) עם טוקן המסד; (2) פריסת morning-checkout +
#               hdm-billing-worker מהקוד של main אחרי #47 (c3c62d4) עם PRODUCTION_FUNCTIONS_TOKEN; (3) בדיקה: גרסאות עלו, הסודות לא השתנו.
#   fnrollback: פריסה מחדש של שתי הפונקציות מהקוד שלפני #47 (7e3e2ca — מה שרץ עד היום) + drop של פונקציית המסד.
# לא משנה סודות, משתמשים, מנויים או תשלומים. לא מחייב.
# =====================================================================
set -euo pipefail
DEPLOY_SHA=c3c62d4b; ROLLBACK_SHA=7e3e2ca
[ -n "${FN_TOK:-}" ] || stop "חסר PRODUCTION_FUNCTIONS_TOKEN"; echo "::add-mask::$FN_TOK"
SHA=$([ "$MODE" = fndeploy ] && echo $DEPLOY_SHA || echo $ROLLBACK_SHA)
W=$(mktemp -d); git -C "$W" init -q; git -C "$W" fetch -q https://github.com/shmulikhavivi-design/haim-derech-misparim.git main || stop "הורדת הקוד נכשלה"
git -C "$W" checkout -q "$(git -C "$W" rev-parse --verify -q "$SHA^{commit}")" 2>/dev/null || stop "הקוד $SHA לא נמצא"
GOT=$(git -C "$W" rev-parse --short=7 HEAD); case "$GOT" in ${SHA:0:7}*) ;; *) stop "התקבל קוד $GOT במקום $SHA";; esac
A="https://api.supabase.com/v1/projects/$PROD_REF"
ver(){ curl -sS -m 30 -H "Authorization: Bearer $FN_TOK" "$A/functions" | jq -r '[.[] | select(.slug=="morning-checkout" or .slug=="hdm-billing-worker") | "\(.slug) v\(.version)"] | join(", ")'; }
SEC_BEFORE=$(curl -sS -m 30 -H "Authorization: Bearer $FN_TOK" "$A/secrets" | jq -c '[.[] | {name, value}] | sort_by(.name)' | sha256sum | cut -c1-16)
BEFORE=$(ver)
SQLF=$([ "$MODE" = fndeploy ] && echo "$W/supabase/production/20_production_card_sweep.sql" || echo "")
if [ -n "$SQLF" ]; then
  [ -f "$SQLF" ] || stop "קובץ ה-SQL לא נמצא"
  C=$(curl -sS -m 120 -o /tmp/sq.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query" -d "$(jq -nc --rawfile q "$SQLF" '{query:$q}')" || echo 000)
  [ "$C" = 201 ] || stop "SQL: HTTP $C $(jq -r '.message // empty' /tmp/sq.json | cut -c1-200)"
  ann notice "fn-sql" "✅ hdm_billing_pending_card_checkouts הותקנה"
else
  C=$(curl -sS -m 60 -o /tmp/sq.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query" -d '{"query":"drop function if exists public.hdm_billing_pending_card_checkouts(int)"}' || echo 000)
  ann notice "fn-sql" "drop: HTTP $C"
fi
cd "$W"; export SUPABASE_ACCESS_TOKEN="$FN_TOK"
OUT=$(supabase functions deploy morning-checkout hdm-billing-worker --project-ref "$PROD_REF" --use-api --no-verify-jwt 2>&1) || { ann error "fn-deploy" "$(echo "$OUT" | grep -vE 'sbp_|eyJ' | tail -6 | tr '\n' ' ')"; stop "הפריסה נכשלה — שום דבר אחר לא שונה"; }
sleep 5
SEC_AFTER=$(curl -sS -m 30 -H "Authorization: Bearer $FN_TOK" "$A/secrets" | jq -c '[.[] | {name, value}] | sort_by(.name)' | sha256sum | cut -c1-16)
ann notice "fn-deploy" "$MODE מקוד $GOT | לפני: $BEFORE | אחרי: $(ver) | סודות הפונקציות ללא שינוי: $([ "$SEC_BEFORE" = "$SEC_AFTER" ] && echo ✅ || echo ❌)"
ann notice "prod-result" "✅ $MODE הושלם"
