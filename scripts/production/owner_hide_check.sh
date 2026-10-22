#!/usr/bin/env bash
# ownerhidecheck — קריאה בלבד: מה מחובר לפרופיל של הבעלים לפני שמסתירים אותו מחיפוש הזוגיות.
RO="https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only"
Q=$(cat <<'SQL'
with me as (select a.profile_id pid from public.hdm_accounts a join auth.users u on u.id=a.auth_user_id where md5(lower(u.email))='162e004328485070b0af8b256ad2e798')
select json_build_object(
 'has_profile', (select count(*) from public.docs d, me where d.collection='profiles' and d.id=me.pid),
 'targets_sent', (select count(*) from public.docs d, me where d.collection='interests' and split_part(d.id,'__',1)=me.pid),
 'targets_received', (select count(*) from public.docs d, me where d.collection='interests' and split_part(d.id,'__',2)=me.pid),
 'matches', (select count(*) from public.docs d, me where d.collection='matches' and position(me.pid in d.id) > 0),
 'chats', (select count(*) from public.docs d, me where d.collection='chats' and position(me.pid in d.id) > 0),
 'blocks', (select count(*) from public.docs d, me where d.collection='blocks' and position(me.pid in d.id) > 0),
 'reports_about', (select count(*) from public.docs d, me where d.collection='reports' and d.data->>'target'=me.pid),
 'subscription', (select json_build_object('plan',plan,'status',status,'source',source,'auto_renew',(to_jsonb(s)->>'auto_renew'),'period_end',current_period_end) from public.hdm_subscriptions s, me where s.profile_id=me.pid),
 'card_saved', (select count(*) from public.hdm_billing_tokens t, me where t.profile_id=me.pid),
 'other_profiles', (select count(*) from public.docs d, me where d.collection='profiles' and d.id<>me.pid),
 'profiles_read_policy', (select pg_get_expr(polqual, polrelid) from pg_policy where polname='profiles_read')
) r
SQL
)
curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$Q" '{query:$q}')" > /tmp/oh.json
ann notice "own-hide" "$(jq -c '.[0].r // .' /tmp/oh.json | cut -c1-1500)"
ann notice "prod-result" "ownerhidecheck — קריאה בלבד"
