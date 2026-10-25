#!/usr/bin/env bash
# freerehearse — Production: runs 22 inside a transaction that is ROLLED BACK + verifies. Changes nothing.
# freeapply    — Production: runs 22 for real (owner approval required), then verifies. No users/mails/charges touched.
A="https://api.supabase.com/v1/projects/$PROD_REF"
q(){ curl -sS -m 120 -o /tmp/q.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
PERMS="select string_agg(plan||':'||can_rate||':'||rating_details||':'||can_target||':'||can_chat||':'||coalesce(monthly_new_chats::text,'∞')||':'||see_who_targeted||':'||extended_analysis||':'||limor_discount_pct||':'||price_agorot, ' | ' order by sort_order) as p from public.hdm_plans"
C=$(q "$PERMS"); [ "$C" = 201 ] || stop "אין גישה למסד (HTTP $C: $(jq -r '.message//empty' /tmp/q.json | cut -c1-120)) — לא שונה כלום"
ann notice "plans-before" "$(jq -r '.[0].p' /tmp/q.json)"
MIG=$(cat "$ROOT/supabase/production/22_production_free_match_level.sql")
if [ "$MODE" = "freerehearse" ]; then
  BODY=$(printf '%s' "$MIG" | sed -e 's/^begin;$//' -e 's/^commit;$//')
  C=$(q "begin; $BODY ; $PERMS; rollback;")
  ann notice "rehearse" "HTTP $C | אחרי השינוי (בתוך עסקה שבוטלה): $(head -c 600 /tmp/q.json)"
  q "$PERMS" >/dev/null; ann notice "plans-after-rollback" "$(jq -r '.[0].p' /tmp/q.json) (לא השתנה)"
  ann notice "prod-result" "freerehearse: Production לא השתנה"; exit 0
fi
C=$(q "$MIG"); [ "$C" = 201 ] || stop "השינוי נכשל ובוטל במלואו (HTTP $C: $(jq -r '.message//empty' /tmp/q.json | cut -c1-200))"
q "$PERMS" >/dev/null; ann notice "plans-after" "$(jq -r '.[0].p' /tmp/q.json)"
ann notice "prod-result" "✅ freeapply: free.can_rate=true ב-Production; שאר המסלולים נבדקו ללא שינוי"
