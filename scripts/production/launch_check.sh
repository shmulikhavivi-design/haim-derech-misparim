#!/usr/bin/env bash
# launchcheck — קריאה בלבד: Brevo, החידוש של 22.11 (מה צפוי ואם יחויב), הגדרות החיוב בפונקציות (השוואת טביעות בלבד), ותצוגה מקדימה של PR #41.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
case "${COMMIT_MSG:-}" in *nobrevo*) ;; *) source "$HERE/readiness_brevo.sh";; esac
Q=$(cat <<'SQL'
with me as (select a.profile_id pid from public.hdm_accounts a join auth.users u on u.id=a.auth_user_id where md5(lower(u.email))='162e004328485070b0af8b256ad2e798')
select json_build_object(
 'plan', s.plan, 'price_ils', (select price_agorot/100.0 from public.hdm_plans where plan=s.plan), 'status', s.status, 'source', s.source, 'auto_renew', to_jsonb(s)->>'auto_renew',
 'period_end_il', to_char(s.current_period_end at time zone 'Asia/Jerusalem','DD.MM.YYYY HH24:MI'),
 'card_saved', exists (select 1 from public.hdm_billing_tokens t where t.profile_id=s.profile_id), 'card_last4_present', (select card_last4 is not null from public.hdm_billing_tokens t where t.profile_id=s.profile_id),
 'renewal_job', (select jobname||' ['||schedule||'] '||active from cron.job where jobname='hdm-morning-renewals'),
 'hidden_from_dating', exists (select 1 from public.hdm_hidden_profiles h where h.profile_id=s.profile_id),
 'pending_charges', (select count(*) from public.hdm_renewal_charges c where c.profile_id=s.profile_id),
 'other_paid_subs', (select count(*) from public.hdm_subscriptions x where x.source='payment' and x.profile_id<>s.profile_id)) r
from public.hdm_subscriptions s, me where s.profile_id = me.pid
SQL
)
ann notice "lc-renewal" "החידוש של הבעלים: $(roq "$Q" | jq -c 'if type=="array" then .[0].r else . end' | tr -d ':' | cut -c1-900)"
curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/secrets" > /tmp/sc.json
cmp1(){ local want; want=$(printf '%s' "$2" | sha256sum | cut -d' ' -f1); local have; have=$(jq -r --arg n "$1" '.[] | select(.name==$n) | .value' /tmp/sc.json); [ "$want" = "$have" ] && echo "$1=$2" || { [ -z "$have" ] && echo "$1=חסר" || echo "$1≠$2"; }; }
ann notice "lc-billing-flags" "הגדרות החיוב בפונקציות: $(cmp1 DRY_RUN 0) | $(cmp1 MORNING_LIVE 1) | $(cmp1 HDM_ENV production) (DRY_RUN=0 + MORNING_LIVE=1 = חיוב אמיתי פעיל)"
rm -f /tmp/sc.json
ann notice "prod-result" "launchcheck — קריאה בלבד"
