#!/usr/bin/env bash
# pre49 — READ-ONLY (27.10): לפני מיזוג PR #49 — מצב המערכת החיה: תשלומים, מנויים, חצים, התאמות, מיילים.
# רק שאילתות דרך נקודת הקצה לקריאה בלבד. בלי שמות/מיילים/מזהים בפלט. לא משנה כלום, לא שולח, לא מחייב.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')" | jq -c '.[0].r // .'; }
# 0. מה שהבדיקה האדומה (local-db) בודקת: מסלול חינם — האם בחיים זה מוגדר כמו שהבדיקה מצפה
ann notice "p0-plans" "0. מסלולים בחיים (מחיר:דירוג:פירוט:🎯:צ'אט:שיחות:מי סימן:ניתוח:הנחה): $(roq "select json_object_agg(plan, price_agorot||':'||can_rate||':'||rating_details||':'||can_target||':'||can_chat||':'||coalesce(monthly_new_chats::text,'∞')||':'||see_who_targeted||':'||extended_analysis||':'||limor_discount_pct) r from public.hdm_plans") | למכירה: $(roq "select json_object_agg(plan,on_sale) r from public.hdm_plan_sale") | סמן: $(roq "select json_agg(version) r from public.hdm_release_marker where version ~ 'free|target'")"
# 1. תשלומים — כפילויות וחריגים
ann notice "p1-payments" "1. תשלומים: $(roq "select json_build_object(
 'by_kind_outcome',(select json_object_agg(k,n) from (select kind||'/'||outcome k,count(*) n from public.hdm_payments group by 1) x),
 'needs_review_open',(select count(*) from public.hdm_payments where needs_review),
 'dup_tx_ids',(select count(*) from (select grow_transaction_id from public.hdm_payments group by 1 having count(*)>1) d),
 'checkouts_with_2plus_approved',(select count(*) from (select checkout_id from public.hdm_payments where outcome='approved' and checkout_id is not null group by 1 having count(*)>1) d),
 'profiles_2plus_approved_same_day',(select count(*) from (select profile_id, received_at::date from public.hdm_payments where outcome='approved' group by 1,2 having count(*)>1) d),
 'last_payment',(select max(received_at) from public.hdm_payments)) r")"
ann notice "p2-billing" "2. ניסיונות תשלום/חידושים/התראות: $(roq "select json_build_object(
 'checkouts',(select json_object_agg(s,n) from (select status s,count(*) n from public.hdm_checkouts group by 1) x),
 'checkouts_pending_over_15m',(select count(*) from public.hdm_checkouts where status='pending' and created_at<now()-interval '15 minutes'),
 'renewals',(select json_object_agg(s,n) from (select status s,count(*) n from public.hdm_renewal_charges group by 1) x),
 'renewal_dup_period',(select count(*) from (select profile_id,period_end from public.hdm_renewal_charges where status in ('approved','succeeded','paid') group by 1,2 having count(*)>1) d),
 'alerts_open',(select json_object_agg(k,n) from (select kind k,count(*) n from public.hdm_billing_alerts where resolved_at is null group by 1) x)) r")"
ann notice "p3-subs" "3. מנויים: $(roq "select json_build_object('by_plan_status',(select json_object_agg(k,n) from (select plan||'/'||status k,count(*) n from public.hdm_subscriptions group by 1) x),
 'paid_active_next_end',(select min(current_period_end) from public.hdm_subscriptions where plan<>'free' and status='active'),
 'updated_last_24h',(select count(*) from public.hdm_subscriptions where updated_at>now()-interval '24 hours')) r")"
# 4. חצים והתאמות
ann notice "p4-targets" "4. חצים/התאמות/צ'אטים: $(roq "select json_build_object(
 'interests',(select count(*) from public.docs where collection='interests'),
 'interests_7d',(select count(*) from public.docs where collection='interests' and (data->>'ts')::bigint > (extract(epoch from now()-interval '7 days')*1000)),
 'last_interest',(select to_timestamp(max((data->>'ts')::bigint)/1000) from public.docs where collection='interests'),
 'matches',(select count(*) from public.docs where collection='matches'),'chats',(select count(*) from public.docs where collection='chats'),
 'mutual_pairs_without_chat',(select count(*) from public.docs a join public.docs b on b.collection='interests' and b.id=(a.data->>'to')||'__'||(a.data->>'from')
     where a.collection='interests' and a.data->>'from' < a.data->>'to'
     and not exists (select 1 from public.docs c where c.collection='chats' and c.id=public.hdm_pair_id(a.data->>'from',a.data->>'to'))),
 'docs_triggers',(select json_agg(tgname order by tgname) from pg_trigger where tgrelid='public.docs'::regclass and not tgisinternal)) r")"
# 5. מיילים
ann notice "p5-mail" "5. מיילים: $(roq "select json_build_object('cancel_outbox_pending',(select count(*) from public.hdm_email_outbox where sent_at is null),
 'worker_runs_24h',(select json_object_agg(s,n) from (select d.status s,count(*) n from cron.job_run_details d join cron.job j on j.jobid=d.jobid where j.jobname='hdm-billing-worker' and d.start_time>now()-interval '24 hours' group by 1) x),
 'http_non200_24h',(select count(*) from net._http_response where created>now()-interval '24 hours' and status_code<>200),
 'target_email_installed',to_regclass('public.hdm_target_email_outbox') is not null) r")"
# 6. טביעות קוד של פונקציות 🎯/צ'אט/מסלול בחיים (להשוואה מול Staging שבו נבדק PR #49)
ann notice "p6-defhash" "6. $(roq "select string_agg(p.proname||'='||substr(md5(pg_get_functiondef(p.oid)),1,10), ' ' order by p.proname) r from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('hdm_send_target','hdm_remove_target','hdm_open_chat','hdm_open_chat_internal','hdm_who_targeted_me','hdm_my_targets','hdm_has_interest','hdm_blocked_between','hdm_docs_guard','hdm_block_hidden_target','hdm_plan_row','hdm_plan_of')")"
ann notice "prod-result" "pre49 — קריאה בלבד. לא שונה דבר, לא נשלח מייל, לא בוצע חיוב."
