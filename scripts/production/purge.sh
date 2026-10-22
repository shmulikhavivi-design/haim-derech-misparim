#!/usr/bin/env bash
# purgerehearse — 12 בעסקה שמבוטלת (מדפיס רק ספירות לכל טבלה). purgeapply — 12 באמת (אישור הבעלים 22.10 11:25).
RW="https://api.supabase.com/v1/projects/$PROD_REF/database/query"; RO="$RW/read-only"
PF="$ROOT/supabase/production/12_delete_three_profiles.sql"; case "$MODE" in *2) PF="$ROOT/supabase/production/15_delete_dina_and_orphans.sql";; esac
if [ "$MODE" = purgerehearse ] || [ "$MODE" = purgerehearse2 ]; then
  SQL=$(python3 -I -c "import sys;print(open(sys.argv[1]).read().replace('__FINAL__', sys.argv[2]))" "$PF" "do \$r\$ begin raise exception 'HDM_PURGE_OK %', (select string_agg(t||'='||n, ' ' order by t) from rep); end \$r\$; rollback;")
  C=$(curl -sS -m 120 -o /tmp/pg.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --arg q "$SQL" '{query:$q}')" || echo 000)
  MSG=$(jq -r '.message // tostring' /tmp/pg.json | cut -c1-1200)
  case "$MSG" in *HDM_PURGE_OK*) ann notice "purge-rehearse" "✅ $(echo "$MSG" | grep -o 'HDM_PURGE_OK.*' | cut -c1-900)";; *) ann error "purge-rehearse" "❌ HTTP $C $MSG";; esac
else
  SQL=$(python3 -I -c "import sys;print(open(sys.argv[1]).read().replace('__FINAL__', 'commit;'))" "$PF")
  C=$(curl -sS -m 120 -o /tmp/pg.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --arg q "$SQL" '{query:$q}')" || echo 000)
  [ "$C" = 201 ] || [ "$C" = 200 ] || stop "המחיקה נעצרה — לא נמחק כלום: HTTP $C $(jq -r '.message // empty' /tmp/pg.json | cut -c1-400)"
fi
Q="select (select count(*) from public.docs where collection='profiles') profiles, (select string_agg(id, ',') from public.docs where collection='profiles') profile_ids, (select count(*) from auth.users where id <> '9f1f6992-d302-44c0-b133-7f6595de9c2a') other_logins, (select count(*) from auth.users) auth_users, (select count(*) from public.hdm_accounts) accounts, (select json_object_agg(plan, n) from (select plan, count(*) n from public.hdm_subscriptions group by plan) z) plans, (select count(*) from public.docs where collection='chats') chats, (select count(*) from public.docs) docs, exists(select 1 from public.docs where collection='profiles' and id='reg_mupj1bkt75rzke') owner_profile, (select plan from public.hdm_subscriptions where profile_id='reg_mupj1bkt75rzke') owner_plan"
curl -sS -m 60 -o /tmp/pv.json -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$Q" '{query:$q}')"
ann notice "purge-state" "$(jq -c '.[0] // .' /tmp/pv.json)"
ann notice "prod-result" "$MODE הסתיים"
