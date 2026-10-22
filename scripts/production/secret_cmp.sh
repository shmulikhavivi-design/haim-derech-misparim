#!/usr/bin/env bash
# secretcmp — משווה טביעת SHA-256 של סודות Morning בפונקציות מול הערך ב-GitHub. לא מדפיס ערכים או טביעות, רק תואם/לא תואם.
A="https://api.supabase.com/v1/projects/$PROD_REF"
curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/secrets" > /tmp/sc.json
cmp1(){ local n="$1" v="$2"; local want; want=$(printf '%s' "$v" | sha256sum | cut -d' ' -f1); local have; have=$(jq -r --arg n "$n" '.[] | select(.name==$n) | .value' /tmp/sc.json)
  local cut; cut=$(printf '%s' "$v" | sed 's/[[:space:]]*#.*//' | sha256sum | cut -d' ' -f1)
  if [ "$want" = "$have" ]; then echo "$n=תואם"; elif [ -z "$have" ]; then echo "$n=חסר"; elif [ "$cut" = "$have" ]; then echo "$n=לא תואם (נחתך ב-#)"; else echo "$n=לא תואם"; fi; }
OID=$(curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d '{"query":"select id from auth.users where md5(lower(email))=\u0027162e004328485070b0af8b256ad2e798\u0027"}' | jq -r '.[0].id // empty')
R="$(cmp1 DRY_RUN 0) | $(cmp1 HDM_BILLING_ALLOWED_USERS "$OID") | $(cmp1 MORNING_CLIENT_ID "${MORNING_CLIENT_ID:-}") | $(cmp1 MORNING_CLIENT_SECRET "${MORNING_CLIENT_SECRET:-}") | $(cmp1 MORNING_API_BASE 'https://api.greeninvoice.co.il/api/v1') | $(cmp1 MORNING_LIVE 1) | $(cmp1 HDM_ENV production) | $(cmp1 MORNING_PLUGIN_ID 53ed9395-02de-4902-a1dd-28dd3f74a5fa) | $(cmp1 HDM_APP_URL https://haim-derech-misparim.pages.dev)"
S=$(printf '%s' "${MORNING_CLIENT_SECRET:-}" | grep -o '[#$"'"'"'\\` ]' | sort -u | tr -d '\n' | sed 's/\$/dollar/;s/#/hash/;s/ /space/;s/"/dq/;s/'"'"'/sq/;s/`/bt/;s/\\/bs/')
rm -f /tmp/sc.json
ann notice "secret-cmp" "$R | סוגי תווים מיוחדים בסוד: ${S:-אין}"
ann notice "prod-result" "$MODE הסתיים"
