#!/usr/bin/env bash
# ownercardsync — אישור הבעלים 22.10 14:10: קישור הכרטיס השמור (טוקן + 4 ספרות) למנוי הבסיסי של הבעלים. בלי חיוב. ואימות מועד החידוש.
command -v deno >/dev/null || { curl -fsSL https://deno.land/install.sh | sh -s -- -y >/dev/null 2>&1; export PATH="$HOME/.deno/bin:$PATH"; }
echo "::add-mask::$MORNING_CLIENT_SECRET"
OUTF=/tmp/oc.json deno run --allow-net=api.morning.co,api.greeninvoice.co.il --allow-env --allow-read --allow-write=/tmp "$ROOT/scripts/production/owner_card_find.ts" || stop "הכרטיס לא נמצא — לא שונה כלום"
TOKV=$(jq -r .token /tmp/oc.json); L4=$(jq -r .last4 /tmp/oc.json); echo "::add-mask::$TOKV"; shred -u /tmp/oc.json
RW="https://api.supabase.com/v1/projects/$PROD_REF/database/query"
Q=$(jq -rn --arg t "$TOKV" --arg l "$L4" '"select public.hdm_billing_save_token(" + ("reg_mupj1bkt75rzke"|@sh) + ", " + ($t|@sh) + ", " + ($l|@sh) + ")"')
C=$(curl -sS -m 60 -o /tmp/os.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
[ "$C" = 201 ] || [ "$C" = 200 ] || stop "קישור הכרטיס נכשל: HTTP $C $(jq -r '.message // empty' /tmp/os.json | cut -c1-200)"
V2="select (select row_to_json(s) from (select plan, status, source, auto_renew, (current_period_end at time zone 'Asia/Jerusalem')::text as renew_local from public.hdm_subscriptions where profile_id='reg_mupj1bkt75rzke') s) sub,
 (select card_last4 from public.hdm_billing_tokens where profile_id='reg_mupj1bkt75rzke') card_last4,
 (select count(*) from public.hdm_renewal_charges) renewal_charges, (select count(*) from public.hdm_payments) payments,
 (select current_period_end > now() from public.hdm_subscriptions where profile_id='reg_mupj1bkt75rzke') not_due_yet,
 (to_regclass('cron.job') is not null) cron_exists"
curl -sS -m 60 -o /tmp/ov.json -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW/read-only" -d "$(jq -nc --arg q "$V2" '{query:$q}')"
ann notice "owner-card-sub" "$(jq -c '.[0] // .' /tmp/ov.json)"
S=$(curl -sS -m 30 -H "Authorization: Bearer $TOK" "https://api.supabase.com/v1/projects/$PROD_REF/secrets" | jq -r '[.[]|select(.name=="DRY_RUN")|.value]|length')
ann notice "owner-renewal-guard" "DRY_RUN מוגדר בפונקציית החידוש: $([ "$S" = 1 ] && echo כן || echo לא)"
ann notice "prod-result" "✅ ownercardsync: הכרטיס קושר למנוי. בלי חיוב."
