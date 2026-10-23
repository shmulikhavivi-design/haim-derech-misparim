#!/usr/bin/env bash
# custcheck — קריאה בלבד: תקלות פתוחות שמשפיעות על לקוחות (מיילי הרשמה, התחברות, תשלומים). בלי שינוי ובלי שליחה. כתובות לא מודפסות.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
Q="select json_build_object(
 'real_users',count(*),
 'unconfirmed',count(*) filter (where email_confirmed_at is null),
 'unconfirmed_list',(select json_agg(json_build_object('age_h',round(extract(epoch from now()-created_at)/3600.0,1),'mail_sent',confirmation_sent_at is not null,'resent_h',round(extract(epoch from now()-confirmation_sent_at)/3600.0,1),'domain',split_part(email,'@',2)) order by created_at) from auth.users x where email_confirmed_at is null and email not like '%example.invalid' and email not like 'life.through.numbers333+%'),
 'confirmed_no_profile',count(*) filter (where email_confirmed_at is not null and not exists(select 1 from public.hdm_accounts a join public.docs d on d.collection='profiles' and d.id=a.profile_id where a.auth_user_id=u.id)),
 'signed_in_after_launch',count(*) filter (where last_sign_in_at > '2026-10-23 11:45+00'),
 'accepted_new_terms',(select count(*) from public.hdm_consents where version='2026-10-21'),
 'checkouts',(select coalesce(json_object_agg(status,n),'{}') from (select status,count(*) n from public.hdm_checkouts where created_at>'2026-10-23 11:40+00' group by status) z),
 'payments_after_launch',(select count(*) from public.hdm_payments where received_at>'2026-10-23 11:40+00'),
 'alerts_open',(select count(*) from public.hdm_billing_alerts where resolved_at is null),
 'emails_failed',(select count(*) from public.hdm_email_outbox where sent_at is null and attempts>=5),
 'cron_fail_24h',(select count(*) from cron.job_run_details d join cron.job j using(jobid) where j.jobname like 'hdm-%' and d.status<>'succeeded' and d.start_time>now()-interval '24 hours')
) r from auth.users u where email not like '%example.invalid' and email not like 'life.through.numbers333+%'"
ann notice "cc-db" "$(roq "$Q" | jq -c 'if type=="array" then .[0].r else . end' | cut -c1-1500)"
K=$(printf '%s' "$GH_BREVO_API" | tr -d '[:space:]"'"'")
curl -sS -m 40 -H "api-key: $K" -H 'accept: application/json' "https://api.brevo.com/v3/smtp/statistics/events?limit=300&days=3&sort=desc" > /tmp/ev.json
ann notice "cc-brevo" "$(jq -c '[.events[]? | select((.email|test("example\\.invalid|^life\\.through\\.numbers333\\+"))|not) | select(.subject|test("Confirm|Reset|Magic|Change";"i"))] | {by_subject_event: (group_by(.subject+" / "+.event) | map({(.[0].subject+" / "+.[0].event): length}) | add), bounces: [ .[] | select(.event|test("ounce|blocked|spam|invalid|deferred")) | {at:.date[0:16], ev:.event, subj:.subject, domain:(.email|split("@")[1]), reason:(.reason//""|.[0:120])}]}' /tmp/ev.json | cut -c1-1800)"
rm -f /tmp/ev.json
ann notice "prod-result" "custcheck — קריאה בלבד"
