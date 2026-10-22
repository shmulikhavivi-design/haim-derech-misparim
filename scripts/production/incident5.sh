#!/usr/bin/env bash
# incident5 — מי מצליח ומי לא: ציר זמן לכל חשבון (בלי שמות/אימיילים), איך כל אחד נכנס (amr), חשבונות מהגרסה הקודמת. קריאה בלבד.
set +e +o pipefail
RO="https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only"
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
Q="select json_agg(x order by x.created) r from (
 select to_char(u.created_at at time zone 'Asia/Jerusalem','DD.MM HH24:MI') created,
   case when u.email like 'life.through.numbers333+inc%' then 'בדיקה שלי' when md5(lower(u.email))='162e004328485070b0af8b256ad2e798' then 'הבעלים' else 'לקוח' end kind,
   to_char(u.confirmation_sent_at at time zone 'Asia/Jerusalem','HH24:MI') conf_sent,
   to_char(u.email_confirmed_at at time zone 'Asia/Jerusalem','DD.MM HH24:MI') confirmed,
   to_char(u.last_sign_in_at at time zone 'Asia/Jerusalem','DD.MM HH24:MI') last_signin,
   to_char(u.recovery_sent_at at time zone 'Asia/Jerusalem','DD.MM HH24:MI') recovery_sent,
   (select string_agg(distinct i.provider, ',') from auth.identities i where i.user_id=u.id) providers,
   (select string_agg(distinct c.authentication_method, ',') from auth.mfa_amr_claims c join auth.sessions s on s.id=c.session_id where s.user_id=u.id) signin_methods,
   (select count(*) from auth.sessions s where s.user_id=u.id) sessions,
   (u.raw_user_meta_data ? 'hdm_terms') via_app_signup,
   exists (select 1 from public.hdm_accounts a where a.auth_user_id=u.id) has_account,
   exists (select 1 from public.hdm_accounts a join public.docs d on d.collection='profiles' and d.id=a.profile_id where a.auth_user_id=u.id) has_profile,
   exists (select 1 from public.hdm_consents c where c.user_id=u.id) consented,
   exists (select 1 from public.hdm_legacy_accounts l where l.email=lower(u.email)) legacy_email
 from auth.users u) x"
ann notice "i5-accounts" "$(roq "$Q" | jq -c 'if type=="array" then .[0].r else . end' | tr -d ':' | cut -c1-3500)"
Q2="select json_build_object(
 'legacy_total', (select count(*) from public.hdm_legacy_accounts),
 'legacy_linked', (select count(*) from public.hdm_legacy_accounts where linked_at is not null),
 'legacy_without_auth_user', (select count(*) from public.hdm_legacy_accounts l where not exists (select 1 from auth.users u where lower(u.email)=l.email)),
 'legacy_review', (select count(*) from public.hdm_legacy_review),
 'legacy_profiles_visible', (select count(*) from public.hdm_legacy_accounts l join public.docs d on d.collection='profiles' and d.id=l.profile_id),
 'profiles_total', (select count(*) from public.docs where collection='profiles'),
 'profiles_without_account', (select count(*) from public.docs d where d.collection='profiles' and not exists (select 1 from public.hdm_accounts a where a.profile_id=d.id) and not exists (select 1 from public.hdm_legacy_accounts l where l.profile_id=d.id)),
 'old_user_docs', (select count(*) from public.docs where collection in ('users','data') or id like 'data/users/%'),
 'pending_tokens', (select coalesce(json_object_agg(token_type, n),'{}') from (select token_type, count(*) n from auth.one_time_tokens group by 1) t),
 'flow_states_24h', (select count(*) from auth.flow_state where created_at > now()-interval '24 hours'),
 'audit_rows_total', (select count(*) from auth.audit_log_entries)
) r"
ann notice "i5-legacy" "$(roq "$Q2" | jq -c 'if type=="array" then .[0].r else . end' | tr -d ':' | cut -c1-2000)"
ann notice "prod-result" "incident5 הסתיים — קריאה בלבד"
