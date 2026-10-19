-- =====================================================================
-- חיים דרך מספרים — בדיקות המנויים המתחדשים (17). הכול מתבטל בסוף — לא נשמר כלום.
-- אירועי Grow מדומים בלבד (אין חיבור ל-Grow ואין חיובים). רץ על Staging אחרי 17.
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_payments') is null then
    raise exception 'עצירה: מנגנון המנויים המתחדשים (17) לא מותקן. שום דבר לא הורץ.';
  end if;
end $$;

create or replace function pg_temp.as_user(p_uid uuid, p_sql text)
returns text language plpgsql as $$
declare r text;
begin
  begin
    perform set_config('request.jwt.claims',
      case when p_uid is null then '{"role":"anon"}'
           else json_build_object('sub', p_uid, 'role', 'authenticated')::text end, true);
    perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
    perform set_config('role', case when p_uid is null then 'anon' else 'authenticated' end, true);
    execute p_sql into r;
    execute 'reset role';
    return 'ok:' || coalesce(r, '');
  exception when others then
    execute 'reset role';
    return 'err:' || sqlerrm;
  end;
end $$;

-- כמו פונקציית השרת שתקבל את האירועים מ-Grow (הרשאת service_role)
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

create or replace function pg_temp.ev(tx text, kind text, outcome text, amt int, ck uuid, dd text)
returns text language sql as $$
  select pg_temp.as_service(format('select public.hdm_billing_apply_grow_event(%L::jsonb)::text',
    jsonb_build_object('transactionId', tx, 'kind', kind, 'outcome', outcome, 'amountAgorot', amt,
                       'checkoutId', ck, 'directDebitId', dd)))
$$;

create temp table t_res (n serial, area text, name text, exp text, got text, ok boolean);
create or replace function pg_temp.chk(a text, nm text, e text, g text) returns void language sql as $$
  insert into t_res (area, name, exp, got, ok) values (a, nm, e, g, coalesce(g, '∅') like e)
$$;
grant all on t_res to service_role, authenticated, anon;

do $$
declare
  pfx text := 'bl' || substr(md5(random()::text), 1, 6);
  uA uuid := gen_random_uuid();   -- לקוח שמצטרף, מתחדש, נכשל
  uB uuid := gen_random_uuid();   -- לקוח שמבטל
  uC uuid := gen_random_uuid();   -- לקוח שמוחק חשבון
  uM uuid := gen_random_uuid();   -- חשבון ותיק עם פלוס ידני (כמו 4 החשבונות הקיימים)
  pA text; pB text; pC text; pM text; r text; ck1 uuid; ck2 uuid; ckB uuid; ckC uuid;
  req text := public.hdm_required_terms_version();
  bt  text := public.hdm_billing_current_terms();
  e1 timestamptz; e2 timestamptz; anc timestamptz; n0 int;
begin
  insert into auth.users (id, email, aud, role, created_at, raw_user_meta_data)
  select u, pfx || '_' || k || '@example.invalid', 'authenticated', 'authenticated', now(), '{}'::jsonb
    from unnest(array[uA, uB, uC, uM], array['a', 'b', 'c', 'm']) as x(u, k);
  pA := substr(pg_temp.as_user(uA, 'select public.hdm_claim_profile()'), 4);
  pB := substr(pg_temp.as_user(uB, 'select public.hdm_claim_profile()'), 4);
  pC := substr(pg_temp.as_user(uC, 'select public.hdm_claim_profile()'), 4);
  pM := substr(pg_temp.as_user(uM, 'select public.hdm_claim_profile()'), 4);
  insert into public.hdm_consents (user_id, profile_id, version, source)
  select u, p, req, 'gate' from unnest(array[uA, uB, uC, uM], array[pA, pB, pC, pM]) as x(u, p);
  insert into public.docs (collection, id, data)
  select 'profiles', p, jsonb_build_object('currentName', 'בדיקה', 'gender', 'אישה', 'birthdate', '1990-01-01')
    from unnest(array[pA, pB, pC, pM]) as p;

  -- ---- הרשאות ----
  perform pg_temp.chk('הרשאות', 'אורח לא רואה מצב מנוי', 'err:%', pg_temp.as_user(null, 'select public.hdm_billing_status()::text'));
  perform pg_temp.chk('הרשאות', 'משתמש לא יכול לדווח תשלום בעצמו', 'err:%permission denied%',
    pg_temp.as_user(uA, 'select public.hdm_billing_apply_grow_event(''{"transactionId":"x","kind":"initial","outcome":"approved"}'')::text'));
  perform pg_temp.chk('הרשאות', 'משתמש לא רואה פעולות מול Grow', 'err:%permission denied%', pg_temp.as_user(uA, 'select count(*)::text from public.hdm_billing_outbox_pending()'));
  perform pg_temp.chk('הרשאות', 'משתמש לא קורא טבלת תשלומים', 'err:%permission denied%', pg_temp.as_user(uA, 'select count(*)::text from public.hdm_payments'));
  perform pg_temp.chk('הרשאות', 'משתמש לא משנה מנוי ישירות', 'err:%permission denied%', pg_temp.as_user(uA, 'update public.hdm_subscriptions set plan = ''vip'' returning plan'));
  perform pg_temp.chk('הרשאות', 'משתמש לא פותח תשלום לאחר', 'err:%', pg_temp.as_user(uA, format('insert into public.hdm_checkouts (user_id, profile_id, plan, amount_agorot, terms_version) values (%L, %L, ''vip'', 1, %L) returning id', uB, pB, bt)));

  -- ---- מצב התחלתי ----
  perform pg_temp.chk('מצב', 'לקוח חדש — חינם', 'ok:free', pg_temp.as_user(uA, 'select public.hdm_billing_status()->>''plan'''));
  perform pg_temp.chk('מצב', 'אין אפשרות ביטול בלי מנוי', 'ok:false', pg_temp.as_user(uA, 'select public.hdm_billing_status()->>''canCancel'''));
  perform pg_temp.chk('מצב', 'תנאי החידוש מוצגים', 'ok:%מתחדש אוטומטית מדי חודש%', pg_temp.as_user(uA, 'select public.hdm_billing_status()->>''termsText'''));

  -- ---- הסכמה לפני תשלום ----
  perform pg_temp.chk('הסכמה', 'בלי אישור התנאים — נחסם', 'err:HDM_BILLING_TERMS_REQUIRED%', pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''basic'', %L, false)::text', bt)));
  perform pg_temp.chk('הסכמה', 'גרסת תנאים ישנה — נחסם', 'err:HDM_BILLING_TERMS_VERSION%', pg_temp.as_user(uA, 'select public.hdm_billing_start_checkout(''basic'', ''billing-2000-01-01'', true)::text'));
  perform pg_temp.chk('הסכמה', 'מסלול חינם/לא מוכר — נחסם', 'err:HDM_BILLING_PLAN%', pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''free'', %L, true)::text', bt)));
  r := pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt));
  perform pg_temp.chk('הסכמה', 'עם אישור — נפתח ניסיון תשלום ₪29.90', 'ok:%"amountAgorot": 2990%', r);
  ck1 := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.chk('הסכמה', 'ההסכמה נשמרה (משתמש, גרסה, מועד)', '1',
    (select count(*)::text from public.hdm_checkouts where id = ck1 and user_id = uA and terms_version = bt and terms_accepted_at is not null));
  perform pg_temp.chk('כפילות', 'לחיצה שנייה — אותו ניסיון תשלום', 'ok:%"reused": true%' || ck1::text || '%', pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt)));
  perform pg_temp.chk('כפילות', 'מסלול אחר בזמן תשלום פתוח — נחסם', 'err:HDM_BILLING_PENDING%', pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''plus'', %L, true)::text', bt)));
  perform pg_temp.chk('אבטחה', 'פתיחת תשלום לא נותנת הרשאות', 'free', public.hdm_plan_of(pA));

  -- ---- תשלום ראשון ----
  perform pg_temp.chk('תשלום ראשון', 'תשלום שנכשל', 'ok:%"result": "failed"%', pg_temp.ev(pfx || 'T0', 'initial', 'failed', 2990, ck1, null));
  perform pg_temp.chk('תשלום ראשון', 'אחרי כישלון — עדיין חינם', 'free', public.hdm_plan_of(pA));
  r := pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''plus'', %L, true)::text', bt));
  ck2 := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.chk('תשלום ראשון', 'אחרי כישלון אפשר לנסות שוב', 'ok:%"amountAgorot": 4890%', r);
  perform pg_temp.chk('תשלום ראשון', 'סכום לא תואם — לא מפעיל', 'ok:%"result": "amount_mismatch"%', pg_temp.ev(pfx || 'T00', 'initial', 'approved', 100, ck2, pfx || 'DDA'));
  perform pg_temp.chk('תשלום ראשון', 'אחרי סכום שגוי — עדיין חינם', 'free', public.hdm_plan_of(pA));
  perform pg_temp.chk('תשלום ראשון', 'תשלום מאושר — מנוי הופעל', 'ok:%"result": "started"%', pg_temp.ev(pfx || 'T1', 'initial', 'approved', 4890, ck2, pfx || 'DDA'));
  perform pg_temp.chk('תשלום ראשון', 'המסלול פלוס', 'plus', public.hdm_plan_of(pA));
  select current_period_end, period_anchor into e1, anc from public.hdm_subscriptions where profile_id = pA;
  perform pg_temp.chk('תשלום ראשון', 'החיוב הבא בעוד חודש, באותו תאריך', 'true', (e1 = public.hdm_billing_add_months(anc, 1) and anc > now() - interval '1 minute')::text);
  perform pg_temp.chk('תשלום ראשון', 'מקור: תשלום, מתחדש', 'true', (select (source = 'payment' and auto_renew)::text from public.hdm_subscriptions where profile_id = pA));
  perform pg_temp.chk('תשלום ראשון', 'נרשם אירוע start', '1', (select count(*)::text from public.hdm_subscription_events where profile_id = pA and action = 'start'));
  r := pg_temp.as_user(uA, 'select public.hdm_billing_status()::text');
  perform pg_temp.chk('תצוגה', 'מוצג תאריך החיוב הבא', 'true', ((substr(r, 4)::jsonb->>'nextChargeAt')::timestamptz = e1)::text);
  perform pg_temp.chk('תצוגה', 'מוצג סכום החיוב הבא', 'ok:%"nextChargeAgorot": 4890%', r);
  perform pg_temp.chk('תצוגה', 'מוצגת אפשרות ביטול', 'ok:%"canCancel": true%', r);

  -- ---- מניעת חיוב כפול ----
  perform pg_temp.chk('כפילות', 'אותו אירוע פעמיים — נקלט פעם אחת', 'ok:%already_processed%', pg_temp.ev(pfx || 'T1', 'initial', 'approved', 4890, ck2, pfx || 'DDA'));
  perform pg_temp.chk('כפילות', 'רשומת תשלום אחת לעסקה', '1', (select count(*)::text from public.hdm_payments where grow_transaction_id = pfx || 'T1'));
  perform pg_temp.chk('כפילות', 'תשלום שני לאותו ניסיון — מסומן להחזר', 'ok:{"result": "duplicate"%"needsReview": true}', pg_temp.ev(pfx || 'T2', 'initial', 'approved', 4890, ck2, pfx || 'DDA2'));
  perform pg_temp.chk('כפילות', 'התקופה לא הוארכה בגלל הכפילות', 'true', (select (current_period_end = e1)::text from public.hdm_subscriptions where profile_id = pA));
  perform pg_temp.chk('כפילות', 'אי אפשר לפתוח תשלום כשיש מנוי פעיל', 'err:HDM_BILLING_ALREADY_SUBSCRIBED%', pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''vip'', %L, true)::text', bt)));
  begin
    perform public.hdm_admin_set_plan(pA, 'vip');
    r := 'no error';
  exception when others then
    r := sqlerrm;
  end;
  perform pg_temp.chk('כפילות', 'שינוי מסלול ידני למנוי בתשלום — נחסם', '%HDM_PAID_PLAN_LOCKED%', r);

  -- ---- חידוש חודשי ----
  -- מדמים: עבר חודש, היום יום החידוש
  update public.hdm_subscriptions set period_anchor = now() - interval '1 month' - interval '1 hour' where profile_id = pA;
  update public.hdm_subscriptions set current_period_end = public.hdm_billing_add_months(period_anchor, 1) where profile_id = pA;
  select current_period_end, period_anchor into e1, anc from public.hdm_subscriptions where profile_id = pA;
  perform pg_temp.chk('חידוש', 'בלי חיוב — התקופה נגמרה, חוזר לחינם', 'free', public.hdm_plan_of(pA));
  perform pg_temp.chk('חידוש', 'חיוב חידוש מאושר', 'ok:%"result": "renewed"%', pg_temp.ev(pfx || 'R1', 'renewal', 'approved', 4890, null, pfx || 'DDA'));
  select current_period_end into e2 from public.hdm_subscriptions where profile_id = pA;
  perform pg_temp.chk('חידוש', 'הוארך לחודש הבא באותו תאריך', 'true', (e2 = public.hdm_billing_add_months(anc, 2))::text);
  perform pg_temp.chk('חידוש', 'שוב פלוס', 'plus', public.hdm_plan_of(pA));
  perform pg_temp.chk('חידוש', 'חיוב חידוש כפול לאותה תקופה — לא מאריך', 'ok:%"result": "duplicate"%', pg_temp.ev(pfx || 'R1b', 'renewal', 'approved', 4890, null, pfx || 'DDA'));
  perform pg_temp.chk('חידוש', 'התקופה לא השתנתה', 'true', (select (current_period_end = e2)::text from public.hdm_subscriptions where profile_id = pA));
  perform pg_temp.chk('חידוש', 'חידוש בסכום שגוי — לא מאריך', 'ok:%amount_mismatch%', pg_temp.ev(pfx || 'R1c', 'renewal', 'approved', 2990, null, pfx || 'DDA'));
  perform pg_temp.chk('חידוש', 'הוראת קבע לא מוכרת — לבדיקה, בלי שינוי', 'ok:%"result": "unknown"%"needsReview": true%', pg_temp.ev(pfx || 'R9', 'renewal', 'approved', 4890, null, pfx || 'NOPE'));
  -- Grow מחייבת כמה שעות לפני סוף התקופה: מאריכים מסוף התקופה, לא מתאריך החיוב
  update public.hdm_subscriptions set period_anchor = now() + interval '3 hours' - interval '2 months' where profile_id = pA;
  update public.hdm_subscriptions set current_period_end = public.hdm_billing_add_months(period_anchor, 2) where profile_id = pA;
  select period_anchor into anc from public.hdm_subscriptions where profile_id = pA;
  perform pg_temp.chk('חידוש', 'חיוב מוקדם בכמה שעות — מתקבל', 'ok:%"result": "renewed"%', pg_temp.ev(pfx || 'R3', 'renewal', 'approved', 4890, null, pfx || 'DDA'));
  perform pg_temp.chk('חידוש', 'הוארך מסוף התקופה (לא קוצר)', 'true',
    (select (current_period_end = public.hdm_billing_add_months(anc, 3))::text from public.hdm_subscriptions where profile_id = pA));

  -- ---- חיוב שנכשל ----
  update public.hdm_subscriptions set current_period_end = now() + interval '1 hour' where profile_id = pA;
  select current_period_end into e1 from public.hdm_subscriptions where profile_id = pA;
  perform pg_temp.chk('כישלון', 'חיוב חידוש נכשל', 'ok:%"result": "failed"%', pg_temp.ev(pfx || 'F1', 'renewal', 'failed', 4890, null, pfx || 'DDA'));
  perform pg_temp.chk('כישלון', 'המנוי לא הוארך', 'true', (select (current_period_end = e1 and status = 'past_due')::text from public.hdm_subscriptions where profile_id = pA));
  perform pg_temp.chk('כישלון', 'בתוקף רק עד סוף התקופה ששולמה', 'plus', public.hdm_plan_of(pA));
  perform pg_temp.chk('כישלון', 'הלקוח רואה שהחיוב נכשל', 'ok:true', pg_temp.as_user(uA, 'select public.hdm_billing_status()->>''paymentFailed'''));
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pA;
  perform pg_temp.chk('כישלון', 'אחרי סוף התקופה — חינם, בלי הארכה', 'free', public.hdm_plan_of(pA));
  perform pg_temp.ev(pfx || 'F2', 'renewal', 'failed', 4890, null, pfx || 'DDA');
  perform pg_temp.chk('כישלון', 'כישלון שלישי — החידוש נעצר', 'ok:%"result": "failed"%', pg_temp.ev(pfx || 'F3', 'renewal', 'failed', 4890, null, pfx || 'DDA'));
  perform pg_temp.chk('כישלון', 'לא מתחדש יותר', 'false', (select auto_renew::text from public.hdm_subscriptions where profile_id = pA));
  perform pg_temp.chk('כישלון', 'נרשם ביטול הוראת הקבע ב-Grow', '1', (select count(*)::text from public.hdm_grow_outbox where grow_direct_debit_id = pfx || 'DDA' and reason = 'payment_failed' and done_at is null));
  perform pg_temp.chk('כישלון', 'חיוב שמגיע אחרי העצירה — לא מאריך, להחזר', 'ok:%"result": "after_cancel"%"needsReview": true%', pg_temp.ev(pfx || 'R2', 'renewal', 'approved', 4890, null, pfx || 'DDA'));
  perform pg_temp.chk('כישלון', 'עדיין חינם', 'free', public.hdm_plan_of(pA));
  perform pg_temp.chk('כישלון', 'אפשר להצטרף מחדש', 'ok:%checkoutId%', pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt)));

  -- ---- ביטול על ידי הלקוח ----
  r := pg_temp.as_user(uB, format('select public.hdm_billing_start_checkout(''vip'', %L, true)::text', bt));
  ckB := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.chk('ביטול', 'VIP ₪79.90 הופעל', 'ok:%started%', pg_temp.ev(pfx || 'TB', 'initial', 'approved', 7990, ckB, pfx || 'DDB'));
  select current_period_end into e1 from public.hdm_subscriptions where profile_id = pB;
  perform pg_temp.chk('ביטול', 'ביטול מתוך האפליקציה', 'ok:{"already": false, "canceled": true%', pg_temp.as_user(uB, 'select public.hdm_billing_cancel()::text'));
  perform pg_temp.chk('ביטול', 'ממשיך ליהנות מ-VIP עד סוף התקופה', 'vip', public.hdm_plan_of(pB));
  r := pg_temp.as_user(uB, 'select public.hdm_billing_status()::text');
  perform pg_temp.chk('ביטול', 'אין יותר חיוב הבא', 'ok:%"nextChargeAt": null%', r);
  perform pg_temp.chk('ביטול', 'מוצג "בתוקף עד"', 'true', ((substr(r, 4)::jsonb->>'activeUntil')::timestamptz = e1)::text);
  perform pg_temp.chk('ביטול', 'נרשם ביטול הוראת הקבע ב-Grow', '1', (select count(*)::text from public.hdm_grow_outbox where grow_direct_debit_id = pfx || 'DDB' and reason = 'customer'));
  perform pg_temp.chk('ביטול', 'ביטול שני — לא כופל', 'ok:%"already": true%', pg_temp.as_user(uB, 'select public.hdm_billing_cancel()::text'));
  perform pg_temp.chk('ביטול', 'בקשת ביטול אחת מול Grow', '1', (select count(*)::text from public.hdm_grow_outbox where grow_direct_debit_id = pfx || 'DDB'));
  perform pg_temp.chk('ביטול', 'אין תשלום חדש עד סוף התקופה', 'err:HDM_BILLING_STILL_ACTIVE%', pg_temp.as_user(uB, format('select public.hdm_billing_start_checkout(''plus'', %L, true)::text', bt)));
  update public.hdm_subscriptions set current_period_end = now() + interval '1 hour' where profile_id = pB;
  perform pg_temp.chk('ביטול', 'חיוב שמגיע אחרי ביטול — לא מאריך, להחזר', 'ok:%after_cancel%', pg_temp.ev(pfx || 'RB', 'renewal', 'approved', 7990, null, pfx || 'DDB'));
  perform pg_temp.chk('ביטול', 'התקופה לא הוארכה', 'true', (select (current_period_end < now() + interval '2 hours')::text from public.hdm_subscriptions where profile_id = pB));
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pB;
  perform pg_temp.chk('ביטול', 'בסוף התקופה — חוזר לחינם', 'free', public.hdm_plan_of(pB));
  perform pg_temp.chk('ביטול', 'משתמש אחר לא יכול לבטל לי', 'err:HDM_BILLING_NOTHING_TO_CANCEL%', pg_temp.as_user(uM, 'select public.hdm_billing_cancel()::text'));

  -- ---- חשבון ותיק עם פלוס ידני (כמו 4 החשבונות הקיימים) ----
  perform public.hdm_admin_set_plan(pM, 'plus', null, 'בדיקה: פלוס ללא הגבלה');
  r := pg_temp.as_user(uM, 'select public.hdm_billing_status()::text');
  perform pg_temp.chk('ותיקים', 'פלוס ידני — לא מסומן כמנוי בתשלום', 'ok:%"paid": false%', r);
  perform pg_temp.chk('ותיקים', 'אין תאריך חיוב ואין כפתור ביטול', 'ok:%"canCancel": false%"nextChargeAt": null%', r);
  perform pg_temp.chk('ותיקים', 'נשאר פלוס', 'plus', public.hdm_plan_of(pM));

  -- ---- מחיקת חשבון עם מנוי פעיל ----
  r := pg_temp.as_user(uC, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt));
  ckC := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.ev(pfx || 'TC', 'initial', 'approved', 2990, ckC, pfx || 'DDC');
  perform pg_temp.chk('מחיקה', 'בסיסי הופעל', 'basic', public.hdm_plan_of(pC));
  perform pg_temp.chk('מחיקה', 'מחיקת חשבון', 'ok:%', pg_temp.as_user(uC, 'select public.hdm_delete_my_data()::text'));
  perform pg_temp.chk('מחיקה', 'נרשם ביטול הוראת הקבע ב-Grow', '1', (select count(*)::text from public.hdm_grow_outbox where grow_direct_debit_id = pfx || 'DDC' and reason = 'account_deleted'));
  perform pg_temp.chk('מחיקה', 'רשומת התשלום נשמרת לתיעוד', '1', (select count(*)::text from public.hdm_payments where grow_transaction_id = pfx || 'TC'));

  -- ---- תור הפעולות מול Grow ----
  perform pg_temp.chk('Grow', 'פונקציית השרת רואה את הפעולות הפתוחות', 'ok:3', pg_temp.as_service(format('select count(*)::text from public.hdm_billing_outbox_pending() where grow_direct_debit_id like %L', pfx || '%')));
  perform pg_temp.as_service(format('select public.hdm_billing_outbox_done(%s, true)::text', (select id from public.hdm_grow_outbox where grow_direct_debit_id = pfx || 'DDB')));
  perform pg_temp.chk('Grow', 'פעולה שבוצעה יוצאת מהתור', 'ok:2', pg_temp.as_service(format('select count(*)::text from public.hdm_billing_outbox_pending() where grow_direct_debit_id like %L', pfx || '%')));

  -- ---- תאריכים ----
  anc := timestamptz '2026-01-31 10:00 Asia/Jerusalem';
  perform pg_temp.chk('תאריכים', '31.1 ← 28.2', '2026-02-28 10:00', to_char(public.hdm_billing_add_months(anc, 1) at time zone 'Asia/Jerusalem', 'YYYY-MM-DD HH24:MI'));
  perform pg_temp.chk('תאריכים', '31.1 ← 31.3 (חוזר ל-31)', '2026-03-31 10:00', to_char(public.hdm_billing_add_months(anc, 2) at time zone 'Asia/Jerusalem', 'YYYY-MM-DD HH24:MI'));
  anc := timestamptz '2026-03-01 10:00 Asia/Jerusalem';
  perform pg_temp.chk('תאריכים', 'מעבר לשעון קיץ — אותה שעה בישראל', '2026-04-01 10:00', to_char(public.hdm_billing_add_months(anc, 1) at time zone 'Asia/Jerusalem', 'YYYY-MM-DD HH24:MI'));
  anc := timestamptz '2026-10-31 01:00 Asia/Jerusalem';
  perform pg_temp.chk('תאריכים', 'הצטרפות בלילה — התאריך לפי ישראל', '2026-11-30', to_char(public.hdm_billing_add_months(anc, 1) at time zone 'Asia/Jerusalem', 'YYYY-MM-DD'));
end $$;

select n, area as "תחום", name as "בדיקה", case when ok then '✅' else '❌ צפוי ' || exp || ' התקבל ' || coalesce(got, '∅') end as "תוצאה"
  from t_res order by n;
select 'עברו ' || count(*) filter (where ok) || ' מתוך ' || count(*) as "סיכום" from t_res;

rollback;
