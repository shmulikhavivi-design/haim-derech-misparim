#!/usr/bin/env bash
# stagebready — קריאה בלבד לפני שלב ב׳: מחירים, VIP, תקנון, הגדרות חיוב, פונקציות, הרשמה/כניסה, האתר החי, כיסוי הגיבוי. בלי שינוי ובלי שליחה.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
Q=$(cat <<'SQL'
select json_build_object(
 'plans', (select string_agg(plan||'='||price_agorot, ' ' order by sort_order) from public.hdm_plans),
 'on_sale', (select string_agg(plan||'='||on_sale, ' ' order by plan) from public.hdm_plan_sale),
 'vip_trigger', exists(select 1 from pg_trigger where tgname='hdm_checkouts_require_on_sale' and not tgisinternal),
 'billing_marker', exists(select 1 from public.hdm_release_marker where version='production_billing_v1'),
 'terms_required_now', public.hdm_required_terms_version(),
 'terms_versions', (select string_agg(version||(case when requires_reconsent then '*' else '' end), ' ' order by version) from public.hdm_terms_versions),
 'consents', (select count(*) from public.hdm_consents)) r
SQL
)
ann notice "b1-plans-terms" "$(roq "$Q" | jq -c '.[0].r // .' | cut -c1-900)"
Q2="select json_build_object('public_tables',(select count(*) from pg_tables where schemaname='public'),'users',(select count(*) from auth.users),'profiles',(select count(*) from public.docs where collection='profiles'),'subs',(select count(*) from public.hdm_subscriptions),'payments',(select count(*) from public.hdm_payments),'tokens',(select count(*) from public.hdm_billing_tokens),'checkouts_open',(select count(*) from public.hdm_checkouts where to_jsonb(hdm_checkouts)->>'status' in ('pending','created')),'renewal_charges',(select count(*) from public.hdm_renewal_charges),'outbox_pending',(select count(*) from public.hdm_email_outbox where sent_at is null),'alerts_open',(select count(*) from public.hdm_billing_alerts where resolved_at is null),'worker_runs_ok',(select count(*) from cron.job_run_details r join cron.job j using(jobid) where j.jobname='hdm-billing-worker' and r.status='succeeded'),'worker_runs_fail',(select count(*) from cron.job_run_details r join cron.job j using(jobid) where j.jobname='hdm-billing-worker' and r.status<>'succeeded'),'worker_http_last',(select string_agg(status_code::text,',') from (select status_code from net._http_response order by id desc limit 5) x)) r"
ann notice "b2-data" "$(roq "$Q2" | jq -c '.[0].r // .' | cut -c1-900)"
curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/secrets" > /tmp/sc.json
cmp1(){ local want have; want=$(printf '%s' "$2" | sha256sum | cut -d' ' -f1); have=$(jq -r --arg n "$1" '.[]|select(.name==$n)|.value' /tmp/sc.json); [ "$want" = "$have" ] && echo "$1=$2" || { [ -z "$have" ] && echo "$1=חסר" || echo "$1≠$2"; }; }
has(){ jq -e --arg n "$1" 'any(.[]; .name==$n)' /tmp/sc.json >/dev/null && echo "$1:קיים" || echo "$1:חסר"; }
ann notice "b3-flags" "$(cmp1 DRY_RUN 0) | $(cmp1 MORNING_LIVE 1) | $(cmp1 HDM_ENV production) | $(has HDM_BILLING_ALLOWED_USERS) (=רק משתמשים מורשים יכולים לשלם) | $(has BREVO_API_KEY) | $(has MAIL_FROM) | $(has MORNING_API_KEY)$(has MORNING_KEY_ID >/dev/null; echo)"
rm -f /tmp/sc.json
ann notice "b4-functions" "$(curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/functions" | jq -r '[.[]|"\(.slug) v\(.version) \(.status) \((.updated_at/1000|todate)[0:16])"]|join(" | ")' | cut -c1-900)"
ANON=$(curl -sS -m 30 https://shmulikhavivi-design.github.io/haim-derech-misparim/ | grep -oE 'eyJ[A-Za-z0-9._-]{100,}' | head -1)
ann notice "b5-auth" "$(curl -sS -m 30 -H "apikey: $ANON" "https://$PROD_REF.supabase.co/auth/v1/settings" | jq -c '{signup_open:(.disable_signup|not), email:.external.email, autoconfirm:.mailer_autoconfirm}')"
for S in https://shmulikhavivi-design.github.io/haim-derech-misparim/ https://haim-derech-misparim.pages.dev/; do
  H=$(curl -sS -m 30 "$S"); ann notice "b6-site" "$(echo "$S" | cut -d/ -f3): BILLING_LIVE=$(echo "$H" | grep -oE 'var HDM_BILLING_LIVE = [a-z]+' | awk '{print $4}') terms=$(echo "$H" | grep -oE "HDM_TERMS_VERSION = '[0-9-]+'" | grep -oE '[0-9-]{10}') VIP_soon=$(echo "$H" | grep -c 'HDM_PLAN_SOON = { vip: true }')"
done
python3 -m pip install -q playwright >/dev/null 2>&1 && timeout 420 python3 -m playwright install --with-deps chromium >/dev/null 2>&1
export SMOKE_OUT="${RUNNER_TEMP:-/tmp}/smoke"; OUT=$(timeout 300 python3 "$HERE/smoke.py" 2>&1); RC=$?
ann notice "b7-smoke" "rc=$RC $(echo "$OUT" | tail -c 700)"
ann notice "prod-result" "stagebready — קריאה בלבד"
