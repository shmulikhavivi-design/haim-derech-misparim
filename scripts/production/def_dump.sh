#!/usr/bin/env bash
# defdump — READ ONLY: הגדרת hdm_billing_pending_card_checkouts כפי שהותקנה (קוד, לא נתונים).
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"
D=$(curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d "$(jq -nc '{query:"select encode(convert_to(pg_get_functiondef(to_regprocedure($$public.hdm_billing_pending_card_checkouts(int)$$)), $$UTF8$$), $$base64$$) b"}')" | jq -r '.[0].b // .')
echo "::notice title=def-dump::$(echo "$D" | tr -d '\n')"
ann notice "prod-result" "✅ defdump: קריאה בלבד"
