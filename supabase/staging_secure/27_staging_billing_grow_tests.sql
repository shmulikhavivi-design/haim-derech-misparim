-- =====================================================================
-- חיים דרך מספרים — בדיקות החיבור הישיר ל-Grow (26) לאורך כל חיי המנוי. הכול מתבטל בסוף — לא נשמר כלום.
-- תשובות Grow מדומות בלבד (אין קריאה ל-Grow ואין חיוב). רץ על Staging אחרי 26.
-- תשלום ← חידוש אוטומטי ← חיוב שנכשל ← שדרוג יחסי ← ביטול חידוש (גישה עד סוף התקופה) ← ביטול עסקה לפי החוק.
-- =====================================================================
begin;

do $$
begin
  if to_regprocedure('public.hdm_billing_save_grow_card(text, text, text, text, text, text)') is null then
    raise exception 'עצירה: החיבור ל-Grow (26) לא מותקן. שום דבר לא הורץ.';
  end if;
end $$;

create or replace function pg_temp.as_user(p_uid uuid, p_sql text)
returns text language plpgsql as $$
declare r text;
begin
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', p_uid::text, true);
    perform set_config('role', 'authenticated', true);
    execute p_sql into r;
    execute 'reset role';
    return 'ok:' || coalesce(r, '');
  exception when others then
    execute 'reset role';
    return 'err:' || sqlerrm;
  end;
end $$;
create or replace function pg_temp.as_service(p_sql text)
returns text language plpgsql as $$
declare r text;
begin
  begin
    perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
    perform set_config('role', 'service_role', true);
    execute p_sql into r;
    execute 'reset role';
    return 'ok:' || coalesce(r, '');
  exception when others then
    execute 'reset role';
    return 'err:' || sqlerrm;
  end;
end $$;
create or replace function pg_temp.ev(j jsonb) returns text language sql as $$
  select pg_temp.as_service(format('select public.hdm_billing_apply_grow_event(%L::jsonb)::text', j))
$$;
create or replace function pg_temp.svc(q text) returns jsonb language sql as $$
  select nullif(substr(pg_temp.as_service(q), 4), '')::jsonb
$$;
create or replace function pg_temp.claim_for(p text) returns jsonb language sql as $$
  select coalesce((select e from jsonb_array_elements(pg_temp.svc('select public.hdm_billing_claim_due_renewals()::text')) e
                    where e->>'profileId' = p limit 1), '{}'::jsonb)
$$;
create temp table t_res (n serial, area text, name text, exp text, got text, ok boolean);
create or replace function pg_temp.chk(a text, nm text, e text, g text) returns void language sql as $$
  insert into t_res (area, name, exp, got, ok) values (a, nm, e, g, coalesce(g, '∅') like e)
$$;

do $$
declare
  pfx text := 'gr' || substr(md5(random()::text), 1, 6);
  uA uuid := gen_random_uuid(); uB uuid := gen_random_uuid(); uC uuid := gen_random_uuid(); uD uuid := gen_random_uuid();
  pA text; pB text; pC text; pD text; r text; ck uuid; ckU uuid; ch jsonb; q jsonb; d jsonb;
  anc timestamptz; pe timestamptz; pe2 timestamptz;
  req text := public.hdm_required_terms_version();
  bt  text := public.hdm_billing_current_terms();
begin
  insert into auth.users (id, email, aud, role, created_at, raw_user_meta_data)
  select u, pfx || '_' || k || '@example.invalid', 'authenticated', 'authenticated', now(), '{}'::jsonb
    from unnest(array[uA, uB, uC, uD], array['a', 'b', 'c', 'd']) as x(u, k);
  pA := substr(pg_temp.as_user(uA, 'select public.hdm_claim_profile()'), 4);
  pB := substr(pg_temp.as_user(uB, 'select public.hdm_claim_profile()'), 4);
  pC := substr(pg_temp.as_user(uC, 'select public.hdm_claim_profile()'), 4);
  pD := substr(pg_temp.as_user(uD, 'select public.hdm_claim_profile()'), 4);
  insert into public.hdm_consents (user_id, profile_id, version, source)
  select u, p, req, 'gate' from unnest(array[uA, uB, uC, uD], array[pA, pB, pC, pD]) as x(u, p);
  insert into public.docs (collection, id, data)
  select 'profiles', p, '{"currentName":"בדיקה","gender":"אישה","birthdate":"1990-01-01"}'::jsonb from unnest(array[pA, pB, pC, pD]) as p;

  -- ---- 1. שלושת המסלולים: המחיר שנגבה נקבע בשרת ----
  r := pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt));
  perform pg_temp.chk('מסלולים', 'בסיסי = ₪29.90', '2990', substr(r, 4)::jsonb->>'amountAgorot');
  ck := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  r := pg_temp.as_user(uB, format('select public.hdm_billing_start_checkout(''plus'', %L, true)::text', bt));
  perform pg_temp.chk('מסלולים', 'פלוס = ₪48.90', '4890', substr(r, 4)::jsonb->>'amountAgorot');
  update public.hdm_checkouts set status = 'expired', closed_at = now() where profile_id = pB;
  r := pg_temp.as_user(uB, format('select public.hdm_billing_start_checkout(''vip'', %L, true)::text', bt));
  perform pg_temp.chk('מסלולים', 'VIP = ₪79.90', '7990', substr(r, 4)::jsonb->>'amountAgorot');
  update public.hdm_checkouts set status = 'expired', closed_at = now() where profile_id = pB;
  perform pg_temp.chk('מסלולים', 'בלי אישור תנאים — אין תשלום', 'err:%', pg_temp.as_user(uB, format('select public.hdm_billing_start_checkout(''basic'', %L, false)::text', bt)));

  -- ---- 2. הרשאות: הפונקציות החדשות לשרת בלבד ----
  perform pg_temp.chk('הרשאות', 'משתמש לא שומר כרטיס', 'err:%permission denied%',
    pg_temp.as_user(uA, format('select public.hdm_billing_save_grow_card(%L, ''t'', ''1234'', ''א ב'', ''0500000000'', ''1230'')::text', pA)));
  perform pg_temp.chk('הרשאות', 'משתמש לא קורא כרטיס', 'err:%permission denied%', pg_temp.as_user(uA, format('select public.hdm_billing_card_details(%L)::text', pA)));
  perform pg_temp.chk('הרשאות', 'משתמש לא קובע מזהה חיוב חוזר', 'err:%permission denied%', pg_temp.as_user(uA, format('select public.hdm_billing_set_recurring_id(%L, ''x'')::text', pA)));
  perform pg_temp.chk('הרשאות', 'משתמש לא מאשר ביטולים', 'err:%permission denied%', pg_temp.as_user(uA, 'select public.hdm_billing_grow_confirm_cancellations()::text'));

  -- ---- 3. תשלום ראשון בדף של Grow, מאומת בשרת ----
  perform pg_temp.chk('תשלום', 'אושר → בסיסי פעיל', 'ok:%"started"%',
    pg_temp.ev(jsonb_build_object('transactionId', 'grow:' || pfx || 'T1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990, 'checkoutId', ck)));
  perform pg_temp.chk('תשלום', 'המסלול: בסיסי', 'basic', public.hdm_plan_of(pA));
  perform pg_temp.chk('תשלום', 'אותה עסקה שוב — לא נקלטת פעמיים', 'ok:%already_processed%',
    pg_temp.ev(jsonb_build_object('transactionId', 'grow:' || pfx || 'T1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990, 'checkoutId', ck)));
  perform pg_temp.chk('תשלום', 'סכום אחר מהמחיר → לא מפעיל, לבדיקה', 'ok:%"needsReview": true%',
    pg_temp.ev(jsonb_build_object('transactionId', 'grow:' || pfx || 'T1x', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 100, 'checkoutId', ck)));
  r := pg_temp.as_user(uB, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt));
  perform pg_temp.chk('תשלום', 'תשלום שנדחה → המסלול לא משתנה', 'ok:%"failed"%',
    pg_temp.ev(jsonb_build_object('transactionId', 'grow:' || pfx || 'T1f', 'kind', 'initial', 'outcome', 'failed', 'amountAgorot', 2990, 'checkoutId', substr(r, 4)::jsonb->>'checkoutId')));
  perform pg_temp.chk('תשלום', 'B נשאר בחינם', 'free', public.hdm_plan_of(pB));
  perform pg_temp.chk('תשלום', 'A נשאר בסיסי', 'basic', public.hdm_plan_of(pA));

  -- ---- 4. שמירת הכרטיס ופרטי המשלם מהודעת השרת של Grow ----
  perform pg_temp.chk('כרטיס', 'טלפון לא תקין נדחה', 'err:%',
    pg_temp.as_service(format('select public.hdm_billing_save_grow_card(%L, %L, ''4580'', ''נועה כהן'', ''123'', ''1230'')::text', pA, pfx || 'CT')));
  perform pg_temp.as_service(format('select public.hdm_billing_save_grow_card(%L, %L, ''4580'', ''נועה כהן'', ''0500000000'', ''1230'')::text', pA, pfx || 'CT'));
  d := pg_temp.svc(format('select public.hdm_billing_card_details(%L)::text', pA));
  perform pg_temp.chk('כרטיס', 'Token, 4 ספרות, שם וטלפון נשמרו', pfx || 'CT|4580|נועה כהן|0500000000',
    concat_ws('|', d->>'token', d->>'last4', d->>'name', d->>'phone'));
  perform pg_temp.chk('כרטיס', 'עוד אין מזהה חיוב חוזר', '∅', coalesce(d->>'recurringDebitId', '∅'));

  -- ---- 5. חידוש אוטומטי באותו תאריך ----
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pA;
  select period_anchor into anc from public.hdm_subscriptions where profile_id = pA;
  ch := pg_temp.claim_for(pA);
  perform pg_temp.chk('חידוש', 'נתפס חיוב אחד בסכום המסלול', '2990', ch->>'amountAgorot');
  perform pg_temp.chk('חידוש', 'הרצה כפולה לא תופסת שוב', '{}', pg_temp.claim_for(pA)::text);
  perform pg_temp.chk('חידוש', 'שמירת recurringDebitId מהחיוב הראשון', 'ok:true', pg_temp.as_service(format('select public.hdm_billing_set_recurring_id(%L, %L)::text', pA, pfx || 'RD')));
  perform pg_temp.chk('חידוש', 'לא נדרס בפעם השנייה', 'ok:false', pg_temp.as_service(format('select public.hdm_billing_set_recurring_id(%L, ''other'')::text', pA)));
  perform pg_temp.chk('חידוש', 'חיוב מאושר → חודש נוסף', 'ok:%"renewed"%',
    pg_temp.ev(jsonb_build_object('transactionId', 'grow:' || pfx || 'R1', 'kind', 'renewal', 'outcome', 'approved', 'amountAgorot', 2990, 'chargeId', ch->>'chargeId')));
  perform pg_temp.chk('חידוש', 'התקופה הוארכה', 'true', ((select current_period_end from public.hdm_subscriptions where profile_id = pA) > now() + interval '20 days')::text);
  perform pg_temp.chk('חידוש', 'תאריך החיוב (העוגן) לא השתנה', anc::text, (select period_anchor::text from public.hdm_subscriptions where profile_id = pA));
  perform pg_temp.chk('חידוש', 'אותה עסקה שוב — לא מאריכה פעמיים', 'ok:%already_processed%',
    pg_temp.ev(jsonb_build_object('transactionId', 'grow:' || pfx || 'R1', 'kind', 'renewal', 'outcome', 'approved', 'amountAgorot', 2990, 'chargeId', ch->>'chargeId')));

  -- ---- 6. חיוב חידוש שנכשל ----
  update public.hdm_subscriptions set current_period_end = now() - interval '2 minutes' where profile_id = pA;
  select current_period_end into pe2 from public.hdm_subscriptions where profile_id = pA;
  ch := pg_temp.claim_for(pA);
  perform pg_temp.chk('כישלון', 'כרטיס נדחה', 'ok:%"failed"%',
    pg_temp.ev(jsonb_build_object('transactionId', 'grow-fail:' || (ch->>'chargeId') || ':1', 'kind', 'renewal', 'outcome', 'failed', 'amountAgorot', 2990, 'chargeId', ch->>'chargeId')));
  perform pg_temp.chk('כישלון', 'המנוי לא הוארך', pe2::text, (select current_period_end::text from public.hdm_subscriptions where profile_id = pA));
  perform pg_temp.chk('כישלון', 'אין ניסיון חוזר לפני 48 שעות', '{}', pg_temp.claim_for(pA)::text);
  -- ניסיון שני מצליח
  update public.hdm_renewal_charges set closed_at = now() - interval '49 hours' where id = (ch->>'chargeId')::uuid;
  ch := pg_temp.claim_for(pA);
  perform pg_temp.chk('כישלון', 'ניסיון שני מצליח → חודש נוסף', 'ok:%"renewed"%',
    pg_temp.ev(jsonb_build_object('transactionId', 'grow:' || pfx || 'R2', 'kind', 'renewal', 'outcome', 'approved', 'amountAgorot', 2990, 'chargeId', ch->>'chargeId')));

  -- ---- 7. שדרוג יחסי באמצע התקופה (בסיסי → פלוס) ----
  update public.hdm_subscriptions set period_anchor = now() - interval '15 days', status = 'active',
         current_period_end = public.hdm_billing_add_months(now() - interval '15 days', 1) where profile_id = pA;
  select period_anchor, current_period_end into anc, pe from public.hdm_subscriptions where profile_id = pA;
  q := substr(pg_temp.as_user(uA, 'select public.hdm_billing_upgrade_quote(''plus'')::text'), 4)::jsonb;
  perform pg_temp.chk('שדרוג', 'סכום יחסי: בין ₪8 ל-₪11', 'true', ((q->>'chargeNowAgorot')::int between 800 and 1100)::text);
  r := pg_temp.as_user(uA, format('select public.hdm_billing_start_upgrade(''plus'', %L, true, %s)::text', bt, q->>'chargeNowAgorot'));
  ckU := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.chk('שדרוג', 'לפני אישור התשלום — עדיין בסיסי', 'basic', public.hdm_plan_of(pA));
  perform pg_temp.chk('שדרוג', 'אושר → פלוס', 'ok:%"upgraded"%',
    pg_temp.ev(jsonb_build_object('transactionId', 'grow:' || pfx || 'U1', 'kind', 'upgrade', 'outcome', 'approved', 'amountAgorot', (q->>'chargeNowAgorot')::int, 'checkoutId', ckU)));
  perform pg_temp.chk('שדרוג', 'המסלול: פלוס', 'plus', public.hdm_plan_of(pA));
  perform pg_temp.chk('שדרוג', 'תאריך החיוב לא השתנה', pe::text, (select current_period_end::text from public.hdm_subscriptions where profile_id = pA));
  perform pg_temp.chk('שדרוג', 'שנמוך לא אפשרי', 'err:%', pg_temp.as_user(uA, 'select public.hdm_billing_upgrade_quote(''basic'')::text'));
  update public.hdm_subscriptions set current_period_end = now() - interval '3 minutes' where profile_id = pA;
  perform pg_temp.chk('שדרוג', 'מהחידוש הבא — מחיר פלוס', '4890', pg_temp.claim_for(pA)->>'amountAgorot');
  update public.hdm_renewal_charges set status = 'failed', closed_at = now() where profile_id = pA and status = 'pending';
  update public.hdm_subscriptions set current_period_end = now() + interval '10 days', status = 'active' where profile_id = pA;

  -- ---- 8. ביטול חידוש: מפסיק חיובים עתידיים, גישה עד סוף התקופה ששולמה ----
  select current_period_end into pe from public.hdm_subscriptions where profile_id = pA;
  r := pg_temp.as_user(uA, 'select public.hdm_billing_cancel()::text');
  perform pg_temp.chk('ביטול', 'הבקשה התקבלה — "בטיפול" עד שהשרת מאשר', 'ok:%"cancelState": "pending"%', r);
  perform pg_temp.chk('ביטול', 'החידוש כבוי מיד', 'false', (select auto_renew::text from public.hdm_subscriptions where profile_id = pA));
  perform pg_temp.chk('ביטול', 'הגישה נשארת: עדיין פלוס', 'plus', public.hdm_plan_of(pA));
  perform pg_temp.chk('ביטול', 'בתוקף עד סוף התקופה ששולמה', pe::text, (select current_period_end::text from public.hdm_subscriptions where profile_id = pA));
  perform pg_temp.chk('ביטול', 'אישור הביטול בשרת', 'ok:1', pg_temp.as_service('select public.hdm_billing_grow_confirm_cancellations()::text'));
  perform pg_temp.chk('ביטול', 'הבקשה אושרה', 'confirmed', (select state from public.hdm_cancel_requests where profile_id = pA order by requested_at desc limit 1));
  perform pg_temp.chk('ביטול', 'מייל אישור בתור', 'true', (exists (select 1 from public.hdm_email_outbox where profile_id = pA and kind = 'cancel_confirmed'))::text);
  perform pg_temp.chk('ביטול', 'אישור חוזר לא עושה כלום', 'ok:0', pg_temp.as_service('select public.hdm_billing_grow_confirm_cancellations()::text'));
  perform pg_temp.chk('ביטול', 'ביטול שני — לא כופל', 'ok:%"already": true%', pg_temp.as_user(uA, 'select public.hdm_billing_cancel()::text'));
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pA;
  perform pg_temp.chk('ביטול', 'בסוף התקופה — שום חיוב לא נתפס', '{}', pg_temp.claim_for(pA)::text);
  perform pg_temp.chk('ביטול', 'בסוף התקופה — המסלול חוזר לחינם', 'free', public.hdm_plan_of(pA));
  perform pg_temp.chk('ביטול', 'אחרי הביטול לא נקבע מזהה חיוב חוזר חדש', 'ok:false', pg_temp.as_service(format('select public.hdm_billing_set_recurring_id(%L, ''z'')::text', pA)));

  -- ---- 9. ביטול עסקה לפי חוק הגנת הצרכן (בתוך 14 יום): השירות מופסק, החזר לטיפול ----
  r := pg_temp.as_user(uC, format('select public.hdm_billing_start_checkout(''vip'', %L, true)::text', bt));
  perform pg_temp.ev(jsonb_build_object('transactionId', 'grow:' || pfx || 'C1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 7990, 'checkoutId', substr(r, 4)::jsonb->>'checkoutId'));
  perform pg_temp.chk('לפי החוק', 'VIP פעיל', 'vip', public.hdm_plan_of(pC));
  perform pg_temp.chk('לפי החוק', 'ביטול עסקה', 'ok:%"refundRequested": true%', pg_temp.as_user(uC, 'select public.hdm_billing_cancel(true)::text'));
  perform pg_temp.chk('לפי החוק', 'השירות הופסק', 'free', public.hdm_plan_of(pC));
  perform pg_temp.chk('לפי החוק', 'החזר פתוח לטיפול', 'open', (select refund_state from public.hdm_cancel_requests where profile_id = pC));
  perform pg_temp.chk('לפי החוק', 'שום חידוש לא נתפס', '{}', pg_temp.claim_for(pC)::text);

  -- ---- 10. חיוב שהגיע אחרי ביטול: לא מאריך, להחזר ----
  r := pg_temp.as_user(uD, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt));
  perform pg_temp.ev(jsonb_build_object('transactionId', 'grow:' || pfx || 'D1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990, 'checkoutId', substr(r, 4)::jsonb->>'checkoutId'));
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pD;
  perform pg_temp.as_service(format('select public.hdm_billing_save_grow_card(%L, %L, ''1111'', ''דני לוי'', ''0520000000'', ''0128'')::text', pD, pfx || 'CD'));
  ch := pg_temp.claim_for(pD);
  perform pg_temp.as_user(uD, 'select public.hdm_billing_cancel()::text');      -- ביטול בזמן שהחיוב בדרך
  perform pg_temp.chk('בטיחות', 'חיוב שאושר אחרי ביטול → לבדיקה והחזר', 'ok:%"needsReview": true%',
    pg_temp.ev(jsonb_build_object('transactionId', 'grow:' || pfx || 'D2', 'kind', 'renewal', 'outcome', 'approved', 'amountAgorot', 2990, 'chargeId', ch->>'chargeId')));

  -- ---- 11. מחיקת חשבון מוחקת את הכרטיס ופרטי המשלם ----
  perform pg_temp.chk('מחיקה', 'מחיקת חשבון', 'ok:%', pg_temp.as_user(uD, 'select public.hdm_delete_my_data()::text'));
  perform pg_temp.chk('מחיקה', 'הכרטיס ופרטי המשלם נמחקו', '0', (select count(*)::text from public.hdm_billing_tokens where profile_id = pD));
end $$;

select n, area as "תחום", name as "בדיקה", case when ok then '✅' else '❌ צפוי ' || exp || ' התקבל ' || coalesce(got, '∅') end as "תוצאה"
  from t_res order by n;
select 'עברו ' || count(*) filter (where ok) || ' מתוך ' || count(*) as "סיכום" from t_res;

rollback;
