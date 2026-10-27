#!/usr/bin/env bash
# targetinstall (27.10, באישור הבעלים — שלב 1 בלבד): התקנת תשתית התראות 🎯 ב-Production.
#  1) תמונת מצב לפני (טביעות של משתמשים/מנויים/תשלומים/התאמות/פונקציות/טריגרים)
#  2) חזרה גנרלית: אותו קובץ בתוך עסקה שמבוטלת — חייבת לעבור
#  3) התקנה אמיתית ("הכול או כלום")  4) תמונת מצב אחרי והשוואה
# לא פורס פונקציה, לא יוצר משימה מתוזמנת, לא שולח מייל, לא נוגע בחיובים/מנויים/משתמשים.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"
WTOK="${DBW_TOK:-$TOK}"; [ -n "${DBW_TOK:-}" ] && echo "::add-mask::$DBW_TOK"
ann notice "t0-token" "טוקן כתיבה: $([ -n "${DBW_TOK:-}" ] && echo PRODUCTION_DB_WRITE_TOKEN || echo PRODUCTION_SUPABASE_TOKEN)"
q(){ curl -sS -m 180 -o /tmp/q.json -w '%{http_code}' -X POST -H "Authorization: Bearer $WTOK" -H 'Content-Type: application/json' "$A/database/query" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
roj(){ curl -sS -m 120 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
FILE="$ROOT/supabase/staging_secure/49_staging_target_email.sql"
[ "$(sha256sum "$FILE" | cut -d' ' -f1)" = "${EXPECT_SHA:-x}" ] || stop "הקובץ אינו הגרסה שנבדקה ב-Staging — לא שונה כלום"
SNAP="select json_build_object(
 'users',(select count(*)||':'||md5(coalesce(string_agg(id::text||coalesce(email_confirmed_at::text,'')||coalesce(banned_until::text,''),',' order by id),'')) from auth.users),
 'accounts',(select count(*)||':'||md5(coalesce(string_agg(auth_user_id::text||profile_id,',' order by profile_id),'')) from public.hdm_accounts),
 'docs',(select count(*)||':'||md5(coalesce(string_agg(collection||id||data::text,',' order by collection,id),'')) from public.docs),
 'subscriptions',(select count(*)||':'||md5(coalesce(string_agg(to_jsonb(s)::text,',' order by profile_id),'')) from public.hdm_subscriptions s),
 'payments',(select count(*)||':'||md5(coalesce(string_agg(to_jsonb(p)::text,',' order by id),'')) from public.hdm_payments p),
 'checkouts',(select count(*)||':'||md5(coalesce(string_agg(to_jsonb(c)::text,',' order by id),'')) from public.hdm_checkouts c),
 'renewals',(select count(*)||':'||md5(coalesce(string_agg(to_jsonb(r)::text,',' order by id),'')) from public.hdm_renewal_charges r),
 'billing_tokens',(select count(*) from public.hdm_billing_tokens),
 'plans',(select md5(string_agg(to_jsonb(p)::text,',' order by plan)) from public.hdm_plans p),
 'plan_sale',(select md5(string_agg(to_jsonb(p)::text,',' order by plan)) from public.hdm_plan_sale p),
 'cancel_outbox',(select count(*) from public.hdm_email_outbox),
 'cron',(select string_agg(jobname||':'||active,',' order by jobname) from cron.job),
 'functions',(select md5(string_agg(p.proname||pg_get_function_identity_arguments(p.oid)||md5(pg_get_functiondef(p.oid)),',' order by p.proname, pg_get_function_identity_arguments(p.oid))) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prokind='f' and p.proname not in ('hdm_target_email_text','hdm_target_email_on_interest','hdm_target_email_claim','hdm_target_email_done','hdm_my_email_prefs','hdm_set_target_emails','hdm_target_email_begin','hdm_target_email_allowed','hdm_target_email_lock_held')),
 'triggers',(select md5(string_agg(c.relname||t.tgname||pg_get_triggerdef(t.oid),',' order by c.relname, t.tgname)) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not t.tgisinternal and t.tgname<>'hdm_target_email_on_interest'),
 'policies',(select md5(string_agg(tablename||policyname||coalesce(qual,'')||coalesce(with_check,''),',' order by tablename, policyname)) from pg_policies where schemaname='public')) r"
if [ "$MODE" = "targetsnap" ]; then
  ann notice "snap" "$(roj "$SNAP" | jq -c '.[0].r')"; ann notice "prod-result" "targetsnap — קריאה בלבד"; exit 0
fi
if [ "$MODE" = "targetverify" ]; then
  # קריאה בלבד: אחרי שהבעלים הריץ את 49 ב-SQL Editor — השוואה לתמונת המצב שנלקחה לפני (27.10 17:40)
  BEFORE='{"users":"58:e8dc190abaca6a5f5e0a24391f363bb0","accounts":"25:0ec1e5295079c439f7702911df33712a","docs":"25:bd076004b76b5edbf6f479659f7f10c3","subscriptions":"3:2054b5b9747820ed8b312353af6559bf","payments":"2:e4c49b62a27058125ce2087219117963","checkouts":"4:495dcf4d760779bbc834f05d9a0efed6","renewals":"0:d41d8cd98f00b204e9800998ecf8427e","billing_tokens":2,"plans":"568711929e612b91d5dd3c9bcd51b153","plan_sale":"9c0955bccf0f817789724a8f9cf5334c","cancel_outbox":1,"cron":"hdm-billing-alerts-scan:true,hdm-billing-worker:true,hdm-morning-renewals:true","functions":"1b5b06c8721a482f19e352381d642c3f","triggers":"479d6e389853711c06b84cc8aa32c355","policies":"0e964fb0ba65ee8a1182b0e15c3e4915"}'
  ann notice "t1-before" "לפני (נשמר): $BEFORE"
else
BEFORE=$(roj "$SNAP" | jq -c '.[0].r'); echo "$BEFORE" | jq -e . >/dev/null 2>&1 || stop "תמונת המצב לפני נכשלה — לא שונה כלום: $(echo "$BEFORE" | cut -c1-200)"
ann notice "t1-before" "לפני: $BEFORE"
fi
if [ "$MODE" != "targetverify" ]; then
# ---- חזרה גנרלית (עסקה שמבוטלת) ----
BODY=$(sed -e 's/^begin;$//' -e 's/^commit;$//' "$FILE")
C=$(q "begin; $BODY ; select json_build_object('tables',(select count(*) from pg_tables where schemaname='public' and tablename like 'hdm_target_email_%'),'trigger',(select count(*) from pg_trigger where tgname='hdm_target_email_on_interest')) r; rollback;")
ann notice "t2-rehearse" "חזרה גנרלית (בוטלה): HTTP $C $(head -c 600 /tmp/q.json)"
[ "$C" = 201 ] || stop "החזרה הגנרלית נכשלה — Production לא השתנה"
MID=$(roj "$SNAP" | jq -c '.[0].r'); [ "$MID" = "$BEFORE" ] || stop "תמונת מצב שונתה אחרי החזרה (לא צפוי) — עצירה"
[ "$(roj "select to_regclass('public.hdm_target_email_outbox') is null as x" | jq -r '.[0].x')" = true ] || stop "החזרה השאירה אובייקטים — עצירה"
[ "$MODE" = "targetrehearse" ] && { ann notice "prod-result" "targetrehearse: עבר. Production לא השתנה"; exit 0; }
# ---- התקנה ----
C=$(q "$(cat "$FILE")")
[ "$C" = 201 ] || stop "ההתקנה נכשלה ובוטלה במלואה (HTTP $C: $(jq -r '.message//empty' /tmp/q.json | cut -c1-250))"
fi
AFTER=$(roj "$SNAP" | jq -c '.[0].r'); ann notice "t3-after" "אחרי: $AFTER"
DIFF=$(jq -rn --argjson a "$BEFORE" --argjson b "$AFTER" '[$a|keys[] as $k | select($a[$k] != $b[$k]) | $k] | join(",")')
ann notice "t4-compare" "השוואה לפני/אחרי — שדות שהשתנו: ${DIFF:-אף אחד}"
V=$(roj "select json_build_object('marker',exists(select 1 from public.hdm_release_marker where version='target_email_v1'),
 'tables',(select json_agg(tablename order by tablename) from pg_tables where schemaname='public' and tablename like 'hdm_target_email_%'),
 'rls',(select bool_and(rowsecurity) from pg_tables where schemaname='public' and tablename like 'hdm_target_email_%'),
 'trigger',(select pg_get_triggerdef(oid) from pg_trigger where tgname='hdm_target_email_on_interest'),
 'outbox_rows',(select count(*) from public.hdm_target_email_outbox),'log_rows',(select count(*) from public.hdm_target_email_log),'prefs_rows',(select count(*) from public.hdm_target_email_prefs),
 'app_can_call',(select json_agg(p.proname order by p.proname) from pg_proc p where p.proname like 'hdm_%email%' and has_function_privilege('authenticated',p.oid,'execute')),
 'anon_can_call',(select count(*) from pg_proc p where p.proname like 'hdm_%target_email%' and has_function_privilege('anon',p.oid,'execute')),
 'mailer_cron',(select count(*) from cron.job where jobname='hdm-target-mailer')) r" | jq -c '.[0].r')
ann notice "t5-verify" "אימות: $V"
if [ -n "${FN_TOK:-}" ]; then echo "::add-mask::$FN_TOK"
  ann notice "t6-functions" "פונקציות פרוסות (שליחה לא פרוסה): $(curl -sS -m 30 -H "Authorization: Bearer $FN_TOK" "$A/functions" | jq -c '[.[]?.slug]') | סוד TARGET_EMAILS_LIVE קיים: $(curl -sS -m 30 -H "Authorization: Bearer $FN_TOK" "$A/secrets" | jq -c '[.[]?.name] | index("TARGET_EMAILS_LIVE") != null')"
fi
[ -z "$DIFF" ] || stop "נתונים קיימים השתנו ($DIFF) — לבדוק מיד"
INST=$(echo "$V" | jq -r 'if (.marker == true and (.tables|length) == 3 and .rls == true and (.trigger|type) == "string" and .outbox_rows == 0 and .anon_can_call == 0 and .mailer_cron == 0) then "yes" else "no" end' 2>/dev/null)
[ "$INST" = yes ] || { ann notice "prod-result" "ℹ️ $MODE: התשתית עדיין לא מותקנת ב-Production (או לא במלואה). נתונים קיימים ללא שינוי."; exit 0; }
ann notice "prod-result" "✅ $MODE: תשתית התראות 🎯 הותקנה ב-Production. מנויים/תשלומים/משתמשים/התאמות/פונקציות קיימות ללא שינוי. אף מייל לא נשלח; פונקציית השליחה לא פרוסה."
