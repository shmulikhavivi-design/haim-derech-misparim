-- =====================================================================
-- חיים דרך מספרים — כפילויות חיוב, ביטול מנוי, החזר בתוך 14 יום ותור מיילי הביטול (Brevo). אירועים מדומים, בלי חיוב ובלי שליחת מייל. הכול מתבטל בסוף.
-- =====================================================================
begin;
do $$ begin if to_regprocedure('public.hdm_billing_alerts_on_cancel()') is null then raise exception 'עצירה: קודם 36. שום דבר לא הורץ.'; end if; end $$;
create or replace function pg_temp.as_user(p_uid uuid, p_sql text) returns text language plpgsql as $$
declare r text; begin begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true); perform set_config('role', 'authenticated', true);
  execute p_sql into r; execute 'reset role'; return 'ok:' || coalesce(r, '');
exception when others then execute 'reset role'; return 'err:' || sqlerrm; end; end $$;
create or replace function pg_temp.as_service(p_sql text) returns text language plpgsql as $$
declare r text; begin begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true); perform set_config('role', 'service_role', true);
  execute p_sql into r; execute 'reset role'; return 'ok:' || coalesce(r, '');
exception when others then execute 'reset role'; return 'err:' || sqlerrm; end; end $$;
create temp table t_res (n serial, area text, name text, exp text, got text, ok boolean);
create or replace function pg_temp.chk(a text, nm text, e text, g text) returns void language sql as $$
  insert into t_res (area, name, exp, got, ok) values (a, nm, e, g, coalesce(g, '∅') like e) $$;
create or replace function pg_temp.ev(j jsonb) returns text language sql as $$
  select pg_temp.as_service(format('select public.hdm_billing_apply_grow_event(%L::jsonb)::text', j)) $$;
create or replace function pg_temp.perms(p text) returns text language sql as $$
  select price_agorot || ':' || can_rate || ':' || rating_details || ':' || can_target || ':' || can_chat || ':' || coalesce(monthly_new_chats::text, '∞')
         || ':' || see_who_targeted || ':' || extended_analysis || ':' || limor_discount_pct from public.hdm_plans where plan = p $$;
do $$
declare
  pfx text := 'cx' || substr(md5(random()::text), 1, 6);
  uA uuid := gen_random_uuid(); uB uuid := gen_random_uuid(); uC uuid := gen_random_uuid(); uX uuid := gen_random_uuid();
  pA text; pB text; pC text; pX text; r text; ck uuid; ck2 uuid; ch jsonb; j jsonb; eid bigint;
  req text := public.hdm_required_terms_version(); bt text := public.hdm_billing_current_terms();
begin
  insert into auth.users (id, email, aud, role, created_at, raw_user_meta_data)
  select u, pfx || '_' || k || '@example.invalid', 'authenticated', 'authenticated', now(), '{}'::jsonb
    from unnest(array[uA, uB, uC, uX], array['a', 'b', 'c', 'x']) as x(u, k);
  pA := substr(pg_temp.as_user(uA, 'select public.hdm_claim_profile()'), 4); pB := substr(pg_temp.as_user(uB, 'select public.hdm_claim_profile()'), 4);
  pC := substr(pg_temp.as_user(uC, 'select public.hdm_claim_profile()'), 4); pX := substr(pg_temp.as_user(uX, 'select public.hdm_claim_profile()'), 4);
  insert into public.hdm_consents (user_id, profile_id, version, source) select u, p, req, 'gate' from unnest(array[uA, uB, uC, uX], array[pA, pB, pC, pX]) as x(u, p);
  insert into public.docs (collection, id, data) select 'profiles', p, '{"currentName":"בדיקה","gender":"אישה","birthdate":"1990-01-01"}'::jsonb from unnest(array[pA, pB, pC, pX]) as p;

  -- ---- כפילויות: אותו אישור פעמיים / חיוב שני לאותו ניסיון / ניסיון שני בזמן מנוי פעיל ----
  r := pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt)); ck := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.chk('כפילויות', 'תפיסת חיוב ראשונה', 'ok:%', pg_temp.as_service(format('select public.hdm_billing_claim_checkout(%L, %L)::text', ck, 'morning-charge:' || ck)));
  perform pg_temp.chk('כפילויות', 'תפיסה שנייה של אותו ניסיון נחסמת (אין חיוב כפול)', 'false', (pg_temp.as_service(format('select public.hdm_billing_claim_checkout(%L, %L)::text', ck, 'morning-charge:' || ck)) = 'ok:true')::text);
  perform pg_temp.ev(jsonb_build_object('transactionId', 'morning:' || pfx || 'A1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990, 'checkoutId', ck));
  perform pg_temp.ev(jsonb_build_object('transactionId', 'morning:' || pfx || 'A1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990, 'checkoutId', ck));
  perform pg_temp.chk('כפילויות', 'אותו אישור פעמיים → תשלום אחד', '1', (select count(*)::text from public.hdm_payments where profile_id = pA));
  j := (select jsonb_build_object('end', current_period_end) from public.hdm_subscriptions where profile_id = pA);
  perform pg_temp.ev(jsonb_build_object('transactionId', 'morning:' || pfx || 'A2', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990, 'checkoutId', ck));
  perform pg_temp.chk('כפילויות', 'אישור שני לאותו ניסיון → לא מאריך, מסומן לבדיקה', 'true|true',
    ((select current_period_end from public.hdm_subscriptions where profile_id = pA) = (j->>'end')::timestamptz)::text || '|' ||
    (select needs_review::text from public.hdm_payments where grow_transaction_id = 'morning:' || pfx || 'A2'));
  perform pg_temp.chk('התראות', 'תשלום כפול → התראת בדיקה', '1', (select count(*)::text from public.hdm_billing_alerts where kind = 'needs_review' and profile_id = pA));
  perform pg_temp.chk('כפילויות', 'מנוי פעיל לא יכול לפתוח הצטרפות נוספת', 'err:%', pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt)));
  perform pg_temp.as_service(format('select public.hdm_billing_save_token(%L, %L, ''1111'')::text', pA, pfx || 'TA'));
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pA;
  perform pg_temp.chk('כפילויות', 'חידוש: נתפס פעם אחת גם בהרצה כפולה', '1|0',
    (select count(*)::text from jsonb_array_elements(substr(pg_temp.as_service('select public.hdm_billing_claim_due_renewals(500)::text'), 4)::jsonb) x where x->>'profileId' = pA) || '|' ||
    (select count(*)::text from jsonb_array_elements(substr(pg_temp.as_service('select public.hdm_billing_claim_due_renewals(500)::text'), 4)::jsonb) x where x->>'profileId' = pA));
  delete from public.hdm_renewal_charges where profile_id = pA;
  update public.hdm_subscriptions set current_period_end = now() + interval '20 days' where profile_id = pA;

  -- ---- ביטול רגיל: עוצר חידוש, פעיל עד סוף התקופה, מייל אישור אחד ----
  r := pg_temp.as_user(uA, 'select public.hdm_billing_cancel()::text');
  perform pg_temp.chk('ביטול', 'ביטול מאושר מיד (אין הוראת קבע אצל Grow)', 'ok:%"cancelState": "confirmed"%', r);
  perform pg_temp.chk('ביטול', 'החידוש כבוי, המסלול נשאר עד סוף התקופה', 'false|basic', (select auto_renew::text from public.hdm_subscriptions where profile_id = pA) || '|' || public.hdm_plan_of(pA));
  perform pg_temp.chk('ביטול', 'ביטול שני → "כבר בוטל", בלי בקשה נוספת', 'ok:%"already": true%|1', pg_temp.as_user(uA, 'select public.hdm_billing_cancel()::text') || '|' || (select count(*)::text from public.hdm_cancel_requests where profile_id = pA));
  perform pg_temp.chk('מייל ביטול', 'בתור: מייל "אישור ביטול" אחד בלבד', 'cancel_confirmed:1', (select string_agg(kind || ':' || n, ',') from (select kind, count(*) n from public.hdm_email_outbox where profile_id = pA group by kind) x));
  perform pg_temp.chk('מייל ביטול', 'הנושא', 'אישור ביטול מנוי — חיים דרך מספרים', (select subject from public.hdm_email_outbox where profile_id = pA));
  perform pg_temp.chk('מייל ביטול', 'התוכן: שם, מסלול, תאריך סיום, "לא יתבצעו חיובים נוספים"', 'true',
    (select body_text like 'שלום בדיקה,%' and body_text like '%מנוי בסיסי אושר%' and body_text like '%לא יתבצעו חיובים נוספים%'
            and body_text like '%' || public.hdm_fmt_date_il(now() + interval '20 days') || '%' from public.hdm_email_outbox where profile_id = pA)::text);
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pA;
  perform pg_temp.chk('ביטול', 'בסוף התקופה: אין חיוב חידוש, חוזר לחינם', '0|free',
    (select count(*)::text from jsonb_array_elements(substr(pg_temp.as_service('select public.hdm_billing_claim_due_renewals(500)::text'), 4)::jsonb) x where x->>'profileId' = pA) || '|' || public.hdm_plan_of(pA));

  -- ---- תור המיילים (מה שהפונקציה hdm-billing-worker עושה מול Brevo) ----
  perform pg_temp.chk('מייל ביטול', 'משתמש לא קורא את תור המיילים', 'err:%permission denied%', pg_temp.as_user(uA, 'select count(*)::text from public.hdm_email_outbox'));
  perform pg_temp.chk('מייל ביטול', 'משתמש לא מפעיל את שליפת התור', 'err:%', pg_temp.as_user(uA, 'select count(*)::text from public.hdm_email_outbox_pending(20)'));
  eid := (select id from public.hdm_email_outbox where profile_id = pA);
  perform pg_temp.chk('מייל ביטול', 'השרת שולף את המייל עם כתובת הנמען', 'ok:' || pfx || '_a@example.invalid',
    pg_temp.as_service(format('select to_email from public.hdm_email_outbox_pending(500) where id = %s', eid)));
  perform pg_temp.as_service(format('select public.hdm_email_outbox_done(%s, false, ''brevo 503'')::text', eid));
  perform pg_temp.chk('מייל ביטול', 'כישלון שליחה → נשאר בתור לניסיון נוסף', 'ok:1', pg_temp.as_service(format('select count(*)::text from public.hdm_email_outbox_pending(500) where id = %s', eid)));
  perform pg_temp.as_service(format('select public.hdm_email_outbox_done(%s, true)::text', eid));
  perform pg_temp.chk('מייל ביטול', 'אחרי שליחה מוצלחת → יוצא מהתור, נשמר מועד השליחה', 'ok:0|true',
    pg_temp.as_service(format('select count(*)::text from public.hdm_email_outbox_pending(500) where id = %s', eid)) || '|' || (select (sent_at is not null)::text from public.hdm_email_outbox where id = eid));

  -- ---- החזר בתוך 14 יום → התראה לבעלים; אחרי 14 יום → נחסם ----
  r := pg_temp.as_user(uB, format('select public.hdm_billing_start_checkout(''plus'', %L, true)::text', bt)); ck2 := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.ev(jsonb_build_object('transactionId', 'morning:' || pfx || 'B1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 4890, 'checkoutId', ck2));
  perform pg_temp.chk('החזר', 'ביטול עם בקשת החזר (יום 0)', 'ok:%"refundRequested": true%', pg_temp.as_user(uB, 'select public.hdm_billing_cancel(true)::text'));
  perform pg_temp.chk('התראות', 'בקשת החזר → התראה עם הסכום ₪48.90', '1|4890', (select count(*)::text || '|' || max(amount_agorot) from public.hdm_billing_alerts where kind = 'refund_requested' and profile_id = pB));
  perform pg_temp.chk('החזר', 'הבקשה פתוחה לטיפול', 'open', (select refund_state from public.hdm_cancel_requests where profile_id = pB));
  r := pg_temp.as_user(uC, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt)); ck := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.ev(jsonb_build_object('transactionId', 'morning:' || pfx || 'C1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990, 'checkoutId', ck));
  update public.hdm_subscriptions set period_anchor = now() - interval '15 days' where profile_id = pC;
  perform pg_temp.chk('החזר', 'אחרי 14 יום — בקשת החזר נחסמת, המנוי לא בוטל', 'err:HDM_BILLING_REFUND_WINDOW%|true', pg_temp.as_user(uC, 'select public.hdm_billing_cancel(true)::text') || '|' || (select auto_renew::text from public.hdm_subscriptions where profile_id = pC));
  perform pg_temp.chk('ביטול', 'אחרי 14 יום — ביטול רגיל עובד', 'ok:%"canceled": true%', pg_temp.as_user(uC, 'select public.hdm_billing_cancel()::text'));
  perform pg_temp.chk('ביטול', 'משתמש בלי מנוי — אין מה לבטל', 'err:%HDM_BILLING_NOTHING_TO_CANCEL%', pg_temp.as_user(uX, 'select public.hdm_billing_cancel()::text'));

  -- ---- מייל שלא נשלח 30 דקות (למשל Brevo לא מחובר) → התראה ----
  update public.hdm_email_outbox set created_at = now() - interval '31 minutes' where profile_id = pC;
  perform pg_temp.as_service('select public.hdm_billing_scan_alerts()::text');
  perform pg_temp.chk('התראות', 'מייל ביטול תקוע 30 דק׳ → התראה', '1', (select count(*)::text from public.hdm_billing_alerts where kind = 'email_delayed' and profile_id = pC));
  perform pg_temp.as_service('select public.hdm_billing_scan_alerts()::text');
  perform pg_temp.chk('התראות', 'סריקה חוזרת לא מכפילה', '1', (select count(*)::text from public.hdm_billing_alerts where kind = 'email_delayed' and profile_id = pC));
  perform pg_temp.chk('התראות', 'מייל שנשלח לא מתריע', '0', (select count(*)::text from public.hdm_billing_alerts where kind = 'email_delayed' and profile_id = pA));
end $$;
select area || ' — ' || name || ': ' || case when ok then '✅' else '❌ (צפוי ' || exp || ', התקבל ' || coalesce(got, '∅') || ')' end as "תוצאה" from t_res order by n;
select 'עברו ' || count(*) filter (where ok) || ' מתוך ' || count(*) as "סיכום" from t_res;
rollback;
