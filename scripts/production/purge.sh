#!/usr/bin/env bash
# purgerehearse — 12 בעסקה שמבוטלת (מדפיס רק ספירות לכל טבלה). purgeapply — 12 באמת (אישור הבעלים 22.10 11:25).
RW="https://api.supabase.com/v1/projects/$PROD_REF/database/query"; RO="$RW/read-only"
SQL=$(cat "$ROOT/supabase/production/12_delete_three_profiles.sql")
if [ "$MODE" = purgerehearse ]; then
  SQL="${SQL/__FINAL__/do \$r\$ begin raise exception 'HDM_PURGE_OK %', (select string_agg(t||'='||n, ' ' order by t) from rep); end \$r\$; rollback;}"
  C=$(curl -sS -m 120 -o /tmp/pg.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --arg q "$SQL" '{query:$q}')" || echo 000)
  MSG=$(jq -r '.message // tostring' /tmp/pg.json | cut -c1-1200)
  case "$MSG" in *HDM_PURGE_OK*) ann notice "purge-rehearse" "✅ $(echo "$MSG" | grep -o 'HDM_PURGE_OK.*' | cut -c1-900)";; *) ann error "purge-rehearse" "❌ HTTP $C $MSG";; esac
else
  SQL="${SQL/__FINAL__/commit;}"
  C=$(curl -sS -m 120 -o /tmp/pg.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --arg q "$SQL" '{query:$q}')" || echo 000)
  [ "$C" = 201 ] || [ "$C" = 200 ] || stop "המחיקה נעצרה — לא נמחק כלום: HTTP $C $(jq -r '.message // empty' /tmp/pg.json | cut -c1-400)"
fi
Q="select (select count(*) from public.docs where collection='profiles') profiles, (select count(*) from public.docs where collection='profiles' and id in ('reg_muwrknqi6g320q','reg_muv7ffi3345nmx','reg_musrb6jotbe85d')) deleted_left, (select count(*) from auth.users) auth_users, (select count(*) from public.hdm_accounts) accounts, (select json_object_agg(plan, n) from (select plan, count(*) n from public.hdm_subscriptions group by plan) z) plans, (select count(*) from public.docs where collection='chats') chats, (select count(*) from public.docs) docs, exists(select 1 from public.docs where collection='profiles' and id='reg_mupj1bkt75rzke') owner_profile, (select plan from public.hdm_subscriptions where profile_id='reg_mupj1bkt75rzke') owner_plan"
curl -sS -m 60 -o /tmp/pv.json -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$Q" '{query:$q}')"
ann notice "purge-state" "$(jq -c '.[0] // .' /tmp/pv.json)"
ann notice "prod-result" "$MODE הסתיים"
