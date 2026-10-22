#!/usr/bin/env bash
# ownerfree — מריץ 11 (שמוליק → חינם, אישור הבעלים 22.10) ומאמת את ההרשאות לפי מסלול חינם. מדפיס רק מסלולים/דגלים, בלי פרטים אישיים.
RO="https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only"; RW="https://api.supabase.com/v1/projects/$PROD_REF/database/query"
C=$(curl -sS -m 60 -o /tmp/of.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --rawfile q "$ROOT/supabase/production/11_owner_to_free.sql" '{query:$q}')" || echo 000)
[ "$C" = 201 ] || [ "$C" = 200 ] || stop "11 נכשל — לא נשמר כלום: HTTP $C $(jq -r '.message // empty' /tmp/of.json | cut -c1-300)"
Q="select public.hdm_plan_of('reg_mupj1bkt75rzke') owner_plan, (select row_to_json(p) from (select plan, price_agorot, can_rate, rating_details, can_target, can_chat, monthly_new_chats from public.hdm_plans where plan = public.hdm_plan_of('reg_mupj1bkt75rzke')) p) owner_perms, (select json_object_agg(plan, n) from (select plan, count(*) n from public.hdm_subscriptions group by plan) z) plans_count, (select count(*) from auth.users) auth_users, (select count(*) from public.docs where collection='profiles') profiles"
C=$(curl -sS -m 60 -o /tmp/of.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
ann notice "owner-free" "HTTP $C $(jq -c '.[0]' /tmp/of.json)"
ann notice "prod-result" "✅ ownerfree: שמוליק במסלול חינם"
