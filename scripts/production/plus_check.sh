#!/usr/bin/env bash
# pluscheck (27.10) — READ ONLY: התשלום האמיתי האחרון, הפעלת פלוס, הרשאות, שגיאות. מזהים מוסווים. בלי חיוב, בלי שינוי.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"
q(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
J(){ jq -c '.[0].j // .' ; }
# 1. תשלומים מאז אתמול בערב + מי
PAY=$(q "select json_agg(json_build_object('pid',substr(md5(c.profile_id),1,6),'was_yesterday_customer',c.profile_id='reg_mvmxfyilz2yu20','kind',y.kind,'outcome',y.outcome,'result',y.result,'amount',y.amount_agorot,'review',y.needs_review,'plan',c.plan,'ck_status',c.status,'claimed',c.grow_process_id is not null,'at',to_char(y.received_at at time zone 'Asia/Jerusalem','DD.MM HH24:MI:SS'),'flow',y.raw->>'flow','problems',y.raw->'problems') order by y.received_at) j from public.hdm_payments y left join public.hdm_checkouts c on c.id=y.checkout_id where y.received_at > '2026-10-26 17:00+00'" | J)
ann notice "pc-1-payments" "$PAY"
PID=$(q "select c.profile_id from public.hdm_payments y join public.hdm_checkouts c on c.id=y.checkout_id where y.received_at > '2026-10-26 17:00+00' and y.outcome='approved' order by y.received_at desc limit 1" | jq -r '.[0].profile_id // empty')
[ -n "$PID" ] || { ann warning "pc" "לא נמצא תשלום מאושר מאז אתמול 19:00"; PID=none; }
echo "::add-mask::$PID"
# 2. כפילויות: אותו ניסיון / אותו לקוח / אותו מסמך
DUP=$(q "select json_build_object(
 'approved_for_customer', (select count(*) from public.hdm_payments y join public.hdm_checkouts c on c.id=y.checkout_id where c.profile_id='$PID' and y.outcome='approved'),
 'payments_for_customer_all', (select count(*) from public.hdm_payments y join public.hdm_checkouts c on c.id=y.checkout_id where c.profile_id='$PID'),
 'unbound_payments_since', (select count(*) from public.hdm_payments where checkout_id is null and received_at > '2026-10-26 17:00+00'),
 'dup_per_checkout_all', (select count(*) from (select checkout_id from public.hdm_payments where checkout_id is not null and outcome='approved' group by 1 having count(*)>1) d),
 'dup_document', (select count(*) from (select raw->>'documentId' d from public.hdm_payments where raw->>'documentId' is not null group by 1 having count(*)>1) x),
 'checkouts', (select json_agg(json_build_object('plan',plan,'amount',amount_agorot,'status',status,'claimed',grow_process_id is not null,'at',to_char(created_at at time zone 'Asia/Jerusalem','DD.MM HH24:MI')) order by created_at) from public.hdm_checkouts where profile_id='$PID'),
 'stuck_claims_all', (select count(*) from public.hdm_checkouts where grow_process_id is not null and status='pending')) j" | J)
ann notice "pc-2-dup" "$DUP"
# 3. המנוי
SUB=$(q "select json_build_object('sub',(select row_to_json(s) from (select plan, status, source, auto_renew, to_char(period_anchor at time zone 'Asia/Jerusalem','DD.MM HH24:MI') anchor, to_char(current_period_end at time zone 'Asia/Jerusalem','DD.MM.YYYY HH24:MI') period_end, to_char(last_payment_at at time zone 'Asia/Jerusalem','DD.MM HH24:MI') last_pay from public.hdm_subscriptions where profile_id='$PID') s),
 'events',(select json_agg(json_build_object('ev',coalesce(to_jsonb(e)->>'event',to_jsonb(e)->>'kind',to_jsonb(e)->>'type'),'at',to_char(e.created_at at time zone 'Asia/Jerusalem','DD.MM HH24:MI')) order by e.created_at) from public.hdm_subscription_events e where e.profile_id='$PID'),
 'card_linked',(select count(*) from public.hdm_billing_tokens where profile_id='$PID'),
 'card_last4_present',(select card_last4 is not null from public.hdm_billing_tokens where profile_id='$PID'),
 'morning_customer',(select count(*) from public.hdm_billing_customers where profile_id='$PID'),
 'renewal_charges',(select count(*) from public.hdm_renewal_charges where profile_id='$PID'),
 'hidden',(select count(*) from public.hdm_hidden_profiles where profile_id='$PID'),
 'plus_profiles_total',(select count(*) from public.hdm_subscriptions where plan='plus' and status in ('active','canceled') and (current_period_end is null or current_period_end>now()))) j" | J)
ann notice "pc-3-subscription" "$SUB"
# 4. הרשאות פלוס (טבלת המסלולים) + מה השרת מחזיר למשתמש עצמו
PL=$(q "select row_to_json(p) j from (select plan, price_agorot, can_rate, rating_details, can_target, can_chat, monthly_new_chats, see_who_targeted, extended_analysis, limor_discount_pct from public.hdm_plans where plan='plus') p" | J)
ann notice "pc-4-plus-plan" "$PL"
UID_=$(q "select auth_user_id from public.hdm_accounts where profile_id='$PID'" | jq -r '.[0].auth_user_id // empty'); echo "::add-mask::${UID_:-x}"
ENT=$(q "select public.hdm_my_entitlements() j from (select set_config('request.jwt.claims', json_build_object('sub','$UID_','role','authenticated')::text, true), set_config('request.jwt.claim.sub','$UID_', true)) s" | jq -c '.[0].j // .' | cut -c1-900)
ann notice "pc-5-entitlements" "$ENT"
# 5. שימוש בפועל מאז ההפעלה (ספירות בלבד)
USE=$(q "select json_build_object('targets_sent',(select count(*) from public.docs where collection='interests' and data->>'from'='$PID'),'chats',(select count(*) from public.docs where collection='chats' and data->'participants' ? '$PID'),'chat_openings',(select count(*) from public.hdm_chat_openings where profile_id='$PID')) j" | J)
ann notice "pc-6-usage" "$USE"
# 6. שגיאות: התראות חיוב, תשובות המשימות המתוזמנות מאז אתמול בערב
AL=$(q "select json_build_object('open_alerts',(select json_agg(json_build_object('kind',to_jsonb(a)->>'kind','at',to_char(a.created_at at time zone 'Asia/Jerusalem','DD.MM HH24:MI'))) from public.hdm_billing_alerts a where to_jsonb(a)->>'resolved_at' is null),
 'cron_non200',(select count(*) from net._http_response where created > now() - interval '12 hours' and (status_code is distinct from 200 or error_msg is not null)),
 'cron_runs_12h',(select count(*) from net._http_response where created > now() - interval '12 hours'),
 'worker_card_results',(select json_agg(distinct left(content::text,160)) from net._http_response where created > now() - interval '12 hours' and content::text like '%cards%' and content::text not like '%\"none\":true%')) j" | J)
ann notice "pc-7-errors" "$AL"
# 7. Morning: המסמך של התשלום (קריאה בלבד)
DOC=$(q "select y.raw->>'documentId' d from public.hdm_payments y join public.hdm_checkouts c on c.id=y.checkout_id where c.profile_id='$PID' and y.outcome='approved' order by y.received_at desc limit 1" | jq -r '.[0].d // empty')
CK=$(q "select public.hdm_billing_checkout_lookup(c.id) j from public.hdm_payments y join public.hdm_checkouts c on c.id=y.checkout_id where c.profile_id='$PID' and y.outcome='approved' order by y.received_at desc limit 1" | jq -c '.[0].j // empty')
if [ -n "$DOC" ]; then
  command -v deno >/dev/null || { curl -fsSL https://deno.land/install.sh | sh -s -- -y >/dev/null 2>&1; export PATH="$HOME/.deno/bin:$PATH"; }
  echo "::add-mask::${MORNING_CLIENT_SECRET:-x}"
  DOC="$DOC" CK_JSON="$CK" deno run --allow-net=api.morning.co,api.greeninvoice.co.il --allow-env --allow-read "$ROOT/scripts/production/plus_doc.ts" 2>&1 | grep '::notice' || ann notice "pc-8-morning" "בדיקת Morning לא רצה"
else ann notice "pc-8-morning" "אין מזהה מסמך בתשלום"; fi
ann notice "prod-result" "✅ pluscheck: קריאה בלבד"
