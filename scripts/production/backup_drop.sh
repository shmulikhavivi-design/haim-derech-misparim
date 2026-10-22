#!/usr/bin/env bash
# backupdrop — חזרה (rollback) ואז ביצוע של 13, ואימות חשבון הבעלים במסלול חינם. מדפיס רק ספירות/דגלים.
RW="https://api.supabase.com/v1/projects/$PROD_REF/database/query"; RO="$RW/read-only"; F="$ROOT/supabase/production/13_drop_old_internal_backups.sql"
run(){ C=$(curl -sS -m 120 -o /tmp/bd.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --arg q "$1" '{query:$q}')" || echo 000); }
run "$(python3 -I -c "import sys;print(open(sys.argv[1]).read().replace('__FINAL__', \"do \$r\$ begin raise exception 'HDM_DROP_OK'; end \$r\$; rollback;\"))" "$F")"
MSG=$(jq -r '.message // tostring' /tmp/bd.json | cut -c1-500)
case "$MSG" in *HDM_DROP_OK*) ann notice "backupdrop-rehearse" "✅ חזרה עברה (בוטלה)";; *) stop "החזרה נעצרה — לא נמחק כלום: HTTP $C $MSG";; esac
run "$(python3 -I -c "import sys;print(open(sys.argv[1]).read().replace('__FINAL__', 'commit;'))" "$F")"
[ "$C" = 201 ] || [ "$C" = 200 ] || stop "המחיקה נעצרה — לא נמחק כלום: HTTP $C $(jq -r '.message // empty' /tmp/bd.json | cut -c1-400)"
Q="select (to_regnamespace('hdm_backup') is null) backups_gone, (select count(*) from public.docs) docs, (select count(*) from public.docs where collection='profiles') profiles, (select count(*) from auth.users) auth_users,
 (select row_to_json(o) from (select s.plan, s.status, s.source, s.current_period_end, s.auto_renew, a.auth_user_id is not null has_account, u.email_confirmed_at is not null email_confirmed, u.banned_until is null not_banned, u.deleted_at is null not_deleted, p.id is not null has_profile from public.hdm_subscriptions s left join public.hdm_accounts a on a.profile_id = s.profile_id left join auth.users u on u.id = a.auth_user_id left join public.docs p on p.collection='profiles' and p.id = s.profile_id where s.profile_id='reg_mupj1bkt75rzke') o) owner,
 (select row_to_json(p) from (select plan, price_agorot, can_rate, rating_details, can_target, can_chat, monthly_new_chats, see_who_targeted, extended_analysis, limor_discount_pct from public.hdm_plans where plan='free') p) free_plan"
curl -sS -m 60 -o /tmp/bv.json -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$Q" '{query:$q}')"
ann notice "backupdrop-after" "$(jq -c '.[0] // .' /tmp/bv.json)"
ann notice "prod-result" "✅ backupdrop: הגיבויים הפנימיים הישנים נמחקו"
