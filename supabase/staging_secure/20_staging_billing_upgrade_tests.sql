-- =====================================================================
-- חיים דרך מספרים — בדיקות שדרוג יחסי וחידוש בכרטיס שמור (19). הכול מתבטל בסוף — לא נשמר כלום.
-- אירועי Grow מדומים בלבד. רץ על Staging אחרי 17 ו-19.
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_renewal_charges') is null then
    raise exception 'עצירה: מנגנון השדרוג (19) לא מותקן. שום דבר לא הורץ.';
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
create temp table t_res (n serial, area text, name text, exp text, got text, ok boolean);
create or replace function pg_temp.chk(a text, nm text, e text, g text) returns void language sql as $$
  insert into t_res (area, name, exp, got, ok) values (a, nm, e, g, coalesce(g, '∅') like e)
$$;

do $$
declare
  pfx text := 'up' || substr(md5(random()::text), 1, 6);
  uA uuid := gen_random_uuid(); uB uuid := gen_random_uuid(); uC uuid := gen_random_uuid();
  pA text; pB text; pC text; r text; q jsonb; ck uuid; ckU uuid; amt int; anc timestamptz; pe timestamptz; ch jsonb; chid text;
  req text := public.hdm_required_terms_version();
  bt  text := public.hdm_billing_current_terms();
begin
  insert into auth.users (id, email, aud, role, created_at, raw_user_meta_data)
  select u, pfx || '_' || k || '@example.invalid', 'authenticated', 'authenticated', now(), '{}'::jsonb
    from unnest(array[uA, uB, uC], array['a', 'b', 'c']) as x(u, k);
  pA := substr(pg_temp.as_user(uA, 'select public.hdm_claim_profile()'), 4);
  pB := substr(pg_temp.as_user(uB, 'select public.hdm_claim_profile()'), 4);
  pC := substr(pg_temp.as_user(uC, 'select public.hdm_claim_profile()'), 4);
  insert into public.hdm_consents (user_id, profile_id, version, source)
  select u, p, req, 'gate' from unnest(array[uA, uB, uC], array[pA, pB, pC]) as x(u, p);
  insert into public.docs (collection, id, data)
  select 'profiles', p, '{"currentName":"בדיקה","gender":"אישה","birthdate":"1990-01-01"}'::jsonb from unnest(array[pA, pB, pC]) as p;

  -- ---- חישוב יחסי (טהור) ----
  anc := timestamptz '2026-10-01 10:00 Asia/Jerusalem'; pe := timestamptz '2026-11-01 10:00 Asia/Jerusalem';
  perform pg_temp.chk('חישוב', 'בסיסי→פלוס באמצע התקופה = ₪9.50', '950',
    public.hdm_billing_proration('basic', 'plus', anc, pe, anc + (pe - anc) / 2)::text);
  perform pg_temp.chk('חישוב', 'בסיסי→VIP בתחילת התקופה = ההפרש המלא ₪50.00', '5000',
    public.hdm_billing_proration('basic', 'vip', anc, pe, anc)::text);
  perform pg_temp.chk('חישוב', 'פלוס→VIP כשנשארו 10 מתוך 30 ימים = ₪10.33', '1033',
    public.hdm_billing_proration('plus', 'vip', timestamptz '2026-11-01 10:00 Asia/Jerusalem', timestamptz '2026-12-01 10:00 Asia/Jerusalem',
                                 timestamptz '2026-11-21 10:00 Asia/Jerusalem')::text);
  perform pg_temp.chk('חישוב', 'בסוף התקופה = 0', '0', public.hdm_billing_proration('basic', 'plus', anc, pe, pe)::text);
  perform pg_temp.chk('חישוב', 'שנמוך = 0 (לא מחויב)', '0', public.hdm_billing_proration('vip', 'basic', anc, pe, anc)::text);
  perform pg_temp.chk('חישוב', 'תחילת תקופה בחודש קצר (28.2→31.3)', '2026-02-28',
    to_char(public.hdm_billing_period_start(timestamptz '2026-01-31 10:00 Asia/Jerusalem', timestamptz '2026-03-31 10:00 Asia/Jerusalem') at time zone 'Asia/Jerusalem', 'YYYY-MM-DD'));

  -- ---- מנוי בסיסי בתשלום (תשלום ראשון מדומה) ----
  r := pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt));
  ck := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.ev(jsonb_build_object('transactionId', pfx || 'I1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990, 'checkoutId', ck, 'directDebitId', pfx || 'RD'));
  perform pg_temp.as_service(format('select public.hdm_billing_save_token(%L, %L, ''4242'')::text', pA, pfx || 'TOKEN'));
  perform pg_temp.chk('הכנה', 'בסיסי פעיל', 'basic', public.hdm_plan_of(pA));
  -- מדמים: עברה חצי תקופה
  update public.hdm_subscriptions set period_anchor = now() - interval '15 days',
         current_period_end = public.hdm_billing_add_months(now() - interval '15 days', 1) where profile_id = pA;
  select period_anchor, current_period_end into anc, pe from public.hdm_subscriptions where profile_id = pA;

  -- ---- הרשאות ----
  perform pg_temp.chk('הרשאות', 'משתמש לא קורא Token', 'err:%permission denied%', pg_temp.as_user(uA, 'select count(*)::text from public.hdm_billing_tokens'));
  perform pg_temp.chk('הרשאות', 'משתמש לא תופס חידושים', 'err:%permission denied%', pg_temp.as_user(uA, 'select public.hdm_billing_claim_due_renewals()::text'));
  perform pg_temp.chk('הרשאות', 'משתמש לא שומר Token', 'err:%permission denied%', pg_temp.as_user(uA, format('select public.hdm_billing_save_token(%L, ''x'')::text', pA)));
  perform pg_temp.chk('הרשאות', 'הגרסה הישנה של קליטת האירועים סגורה', 'err:%permission denied%', pg_temp.as_service('select public.hdm_billing_apply_grow_event_v1(''{}'')::text'));

  -- ---- הצעת מחיר ----
  r := pg_temp.as_user(uA, 'select public.hdm_billing_upgrade_quote(''plus'')::text');
  q := substr(r, 4)::jsonb;
  amt := (q->>'chargeNowAgorot')::int;
  perform pg_temp.chk('הצעה', 'סכום יחסי לפי יתרת התקופה', 'true',
    (amt = public.hdm_billing_proration('basic', 'plus', anc, pe) and amt between 800 and 1100)::text);
  perform pg_temp.chk('הצעה', 'תאריך החיוב הבא לא משתנה', 'true', ((q->>'nextChargeAt')::timestamptz = pe)::text);
  perform pg_temp.chk('הצעה', 'מהחיוב הבא — מחיר פלוס ₪48.90', '4890', q->>'nextChargeAgorot');
  perform pg_temp.chk('הצעה', 'שנמוך לא מוצע', 'err:%HDM_BILLING_UPGRADE_PLAN%', pg_temp.as_user(uA, 'select public.hdm_billing_upgrade_quote(''free'')::text'));
  perform pg_temp.chk('הצעה', 'לאותו מסלול — לא', 'err:%HDM_BILLING_UPGRADE_PLAN%', pg_temp.as_user(uA, 'select public.hdm_billing_upgrade_quote(''basic'')::text'));
  perform pg_temp.chk('הצעה', 'בלי מנוי בתשלום — אין שדרוג', 'err:%HDM_BILLING_UPGRADE_NA%', pg_temp.as_user(uB, 'select public.hdm_billing_upgrade_quote(''plus'')::text'));

  -- ---- פתיחת תשלום שדרוג ----
  perform pg_temp.chk('הסכמה', 'בלי אישור — נחסם', 'err:HDM_BILLING_TERMS_REQUIRED%', pg_temp.as_user(uA, format('select public.hdm_billing_start_upgrade(''plus'', %L, false, %s)::text', bt, amt)));
  perform pg_temp.chk('הסכמה', 'סכום שהלקוח לא ראה — נחסם', 'err:HDM_BILLING_QUOTE_CHANGED%', pg_temp.as_user(uA, format('select public.hdm_billing_start_upgrade(''plus'', %L, true, %s)::text', bt, amt - 50)));
  r := pg_temp.as_user(uA, format('select public.hdm_billing_start_upgrade(''plus'', %L, true, %s)::text', bt, amt));
  perform pg_temp.chk('הסכמה', 'נפתח תשלום שדרוג בסכום היחסי', 'ok:%"amountAgorot": ' || amt || '%', r);
  ckU := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.chk('הסכמה', 'ההסכמה נשמרה עם סוג "שדרוג"', '1', (select count(*)::text from public.hdm_checkouts where id = ckU and kind = 'upgrade' and from_plan = 'basic' and terms_version = bt));
  perform pg_temp.chk('אבטחה', 'לפני אישור התשלום — עדיין בסיסי', 'basic', public.hdm_plan_of(pA));
  perform pg_temp.chk('כפילות', 'שדרוג שני בזמן תשלום פתוח — נחסם', 'err:HDM_BILLING_PENDING%', pg_temp.as_user(uA, format('select public.hdm_billing_start_upgrade(''vip'', %L, true, %s)::text', bt,
    public.hdm_billing_proration('basic', 'vip', anc, pe))));

  -- ---- אישור / כישלון ----
  perform pg_temp.chk('תשלום', 'סכום שגוי — לא משדרג', 'ok:%amount_mismatch%', pg_temp.ev(jsonb_build_object('transactionId', pfx || 'U0', 'kind', 'upgrade', 'outcome', 'approved', 'amountAgorot', amt + 1, 'checkoutId', ckU)));
  perform pg_temp.chk('תשלום', 'עדיין בסיסי', 'basic', public.hdm_plan_of(pA));
  perform pg_temp.chk('תשלום', 'תשלום מאושר — שודרג מיד', 'ok:%"result": "upgraded"%', pg_temp.ev(jsonb_build_object('transactionId', pfx || 'U1', 'kind', 'upgrade', 'outcome', 'approved', 'amountAgorot', amt, 'checkoutId', ckU)));
  perform pg_temp.chk('תשלום', 'המסלול פלוס', 'plus', public.hdm_plan_of(pA));
  perform pg_temp.chk('תשלום', 'תאריך החיוב החודשי נשמר', 'true', (select (period_anchor = anc and current_period_end = pe and auto_renew)::text from public.hdm_subscriptions where profile_id = pA));
  perform pg_temp.chk('תשלום', 'מוצג חיוב הבא ₪48.90 באותו תאריך', 'ok:%"nextChargeAgorot": 4890%', pg_temp.as_user(uA, 'select public.hdm_billing_status()::text'));
  perform pg_temp.chk('כפילות', 'אותו אישור פעמיים — נקלט פעם אחת', 'ok:%already_processed%', pg_temp.ev(jsonb_build_object('transactionId', pfx || 'U1', 'kind', 'upgrade', 'outcome', 'approved', 'amountAgorot', amt, 'checkoutId', ckU)));
  perform pg_temp.chk('כפילות', 'תשלום שני לאותו שדרוג — להחזר', 'ok:%"result": "duplicate"%"needsReview": true%', pg_temp.ev(jsonb_build_object('transactionId', pfx || 'U2', 'kind', 'upgrade', 'outcome', 'approved', 'amountAgorot', amt, 'checkoutId', ckU)));
  perform pg_temp.chk('כפילות', 'אירוע שדרוג אחד במנוי', '1', (select count(*)::text from public.hdm_subscription_events where profile_id = pA and action = 'upgrade'));

  -- ---- שדרוג שני (פלוס→VIP) שנכשל ----
  r := pg_temp.as_user(uA, 'select public.hdm_billing_upgrade_quote(''vip'')::text');
  amt := (substr(r, 4)::jsonb->>'chargeNowAgorot')::int;
  r := pg_temp.as_user(uA, format('select public.hdm_billing_start_upgrade(''vip'', %L, true, %s)::text', bt, amt));
  ckU := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.chk('כישלון', 'פלוס→VIP לפי הפרש ₪31.00 יחסי', 'true', (amt between 1300 and 1700)::text);
  perform pg_temp.chk('כישלון', 'תשלום שדרוג נכשל', 'ok:%"result": "failed"%', pg_temp.ev(jsonb_build_object('transactionId', pfx || 'U3', 'kind', 'upgrade', 'outcome', 'failed', 'amountAgorot', amt, 'checkoutId', ckU)));
  perform pg_temp.chk('כישלון', 'נשאר פלוס, התאריך לא השתנה', 'true', (select (plan = 'plus' and current_period_end = pe)::text from public.hdm_subscriptions where profile_id = pA));

  -- ---- הצעה ישנה: המנוי השתנה בין ההצעה לתשלום ----
  r := pg_temp.as_user(uA, format('select public.hdm_billing_start_upgrade(''vip'', %L, true, %s)::text', bt, amt));
  ckU := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  update public.hdm_subscriptions set current_period_end = current_period_end + interval '1 day' where profile_id = pA;
  perform pg_temp.chk('הצעה ישנה', 'תשלום על תקופה שהשתנתה — לא משדרג, להחזר', 'ok:%"result": "stale"%"needsReview": true%', pg_temp.ev(jsonb_build_object('transactionId', pfx || 'U4', 'kind', 'upgrade', 'outcome', 'approved', 'amountAgorot', amt, 'checkoutId', ckU)));
  perform pg_temp.chk('הצעה ישנה', 'נשאר פלוס', 'plus', public.hdm_plan_of(pA));
  update public.hdm_subscriptions set current_period_end = pe where profile_id = pA;
  update public.hdm_checkouts set status = 'expired' where id = ckU;

  -- ---- שעות אחרונות: יתרה קטנה מ-₪1 — שדרוג בלי חיוב ----
  update public.hdm_subscriptions set current_period_end = now() + interval '20 minutes' where profile_id = pA;
  r := pg_temp.as_user(uA, 'select public.hdm_billing_upgrade_quote(''vip'')::text');
  amt := (substr(r, 4)::jsonb->>'chargeNowAgorot')::int;
  perform pg_temp.chk('יתרה קטנה', 'הסכום קטן מ-₪1', 'true', (amt < 100)::text);
  perform pg_temp.chk('יתרה קטנה', 'שודרג מיד בלי חיוב', 'ok:%"charged": false%', pg_temp.as_user(uA, format('select public.hdm_billing_start_upgrade(''vip'', %L, true, %s)::text', bt, amt)));
  perform pg_temp.chk('יתרה קטנה', 'VIP; החידוש הבא ₪79.90', 'ok:%"nextChargeAgorot": 7990%', pg_temp.as_user(uA, 'select public.hdm_billing_status()::text'));

  -- ---- מנוי שבוטל / חיוב שנכשל — אין שדרוג ----
  r := pg_temp.as_user(uB, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt));
  perform pg_temp.ev(jsonb_build_object('transactionId', pfx || 'IB', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990, 'checkoutId', (substr(r, 4)::jsonb->>'checkoutId'), 'directDebitId', pfx || 'RDB'));
  perform pg_temp.as_user(uB, 'select public.hdm_billing_cancel()::text');
  perform pg_temp.chk('מצבים', 'מנוי שבוטל — אין שדרוג', 'err:%HDM_BILLING_UPGRADE_NA%', pg_temp.as_user(uB, 'select public.hdm_billing_upgrade_quote(''plus'')::text'));
  update public.hdm_subscriptions set status = 'past_due', auto_renew = true where profile_id = pB;
  perform pg_temp.chk('מצבים', 'חיוב אחרון נכשל — אין שדרוג', 'err:%HDM_BILLING_UPGRADE_NA%', pg_temp.as_user(uB, 'select public.hdm_billing_upgrade_quote(''plus'')::text'));
  perform set_config('hdm.cancel_reason', 'test', true);
  update public.hdm_subscriptions set status = 'canceled', auto_renew = false where profile_id = pB;

  -- ---- חידוש בכרטיס שמור ----
  r := pg_temp.as_user(uC, format('select public.hdm_billing_start_checkout(''plus'', %L, true)::text', bt));
  perform pg_temp.ev(jsonb_build_object('transactionId', pfx || 'IC', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 4890, 'checkoutId', (substr(r, 4)::jsonb->>'checkoutId'), 'directDebitId', pfx || 'RDC'));
  perform pg_temp.as_service(format('select public.hdm_billing_save_token(%L, %L)::text', pC, pfx || 'TOKC'));
  perform pg_temp.chk('חידוש', 'לפני המועד — אין מה לחייב', 'ok:0',
    pg_temp.as_service(format('select count(*)::text from jsonb_array_elements(public.hdm_billing_claim_due_renewals()) e where e->>''profileId'' = %L', pC)));
  update public.hdm_subscriptions set period_anchor = now() - interval '1 month' - interval '5 minutes',
         current_period_end = public.hdm_billing_add_months(now() - interval '1 month' - interval '5 minutes', 1) where profile_id = pC;
  select period_anchor, current_period_end into anc, pe from public.hdm_subscriptions where profile_id = pC;
  r := pg_temp.as_service('select public.hdm_billing_claim_due_renewals()::text');
  select e into ch from jsonb_array_elements(substr(r, 4)::jsonb) e where e->>'profileId' = pC;
  perform pg_temp.chk('חידוש', 'במועד — נתפס חיוב אחד ₪48.90 עם ה-Token', 'true', (ch->>'amountAgorot' = '4890' and ch->>'token' = pfx || 'TOKC')::text);
  chid := ch->>'chargeId';
  perform pg_temp.chk('כפילות', 'הרצה שנייה של המשימה — לא תופסת שוב', 'ok:0',
    pg_temp.as_service(format('select count(*)::text from jsonb_array_elements(public.hdm_billing_claim_due_renewals()) e where e->>''profileId'' = %L', pC)));
  perform pg_temp.chk('חידוש', 'חיוב מאושר — חודש נוסף באותו תאריך', 'ok:%"result": "renewed"%', pg_temp.ev(jsonb_build_object('transactionId', pfx || 'RC1', 'kind', 'renewal', 'outcome', 'approved', 'amountAgorot', 4890, 'chargeId', chid)));
  perform pg_temp.chk('חידוש', 'התקופה הבאה מסתיימת באותו תאריך', 'true', (select (current_period_end = public.hdm_billing_add_months(anc, 2))::text from public.hdm_subscriptions where profile_id = pC));
  perform pg_temp.chk('חידוש', 'החיוב סומן מאושר', 'approved', (select status from public.hdm_renewal_charges where id = chid::uuid));
  perform pg_temp.chk('כפילות', 'אותו אישור פעמיים — נקלט פעם אחת', 'ok:%already_processed%', pg_temp.ev(jsonb_build_object('transactionId', pfx || 'RC1', 'kind', 'renewal', 'outcome', 'approved', 'amountAgorot', 4890, 'chargeId', chid)));

  -- כישלון וניסיון חוזר
  update public.hdm_subscriptions set period_anchor = now() - interval '2 months' - interval '10 minutes',
         current_period_end = public.hdm_billing_add_months(now() - interval '2 months' - interval '10 minutes', 2) where profile_id = pC;
  select period_anchor into anc from public.hdm_subscriptions where profile_id = pC;
  r := pg_temp.as_service('select public.hdm_billing_claim_due_renewals()::text');
  select e into ch from jsonb_array_elements(substr(r, 4)::jsonb) e where e->>'profileId' = pC;
  perform pg_temp.chk('כישלון', 'חיוב חידוש נכשל', 'ok:%"result": "failed"%', pg_temp.ev(jsonb_build_object('transactionId', pfx || 'RC2', 'kind', 'renewal', 'outcome', 'failed', 'amountAgorot', 4890, 'chargeId', ch->>'chargeId')));
  perform pg_temp.chk('כישלון', 'לא מוארך — חוזר לחינם', 'free', public.hdm_plan_of(pC));
  perform pg_temp.chk('כישלון', 'ניסיון חוזר לא מיד (לפחות 48 שעות)', 'ok:0',
    pg_temp.as_service(format('select count(*)::text from jsonb_array_elements(public.hdm_billing_claim_due_renewals()) e where e->>''profileId'' = %L', pC)));
  update public.hdm_renewal_charges set closed_at = now() - interval '49 hours' where profile_id = pC and status = 'failed';
  r := pg_temp.as_service('select public.hdm_billing_claim_due_renewals()::text');
  select e into ch from jsonb_array_elements(substr(r, 4)::jsonb) e where e->>'profileId' = pC;
  perform pg_temp.chk('כישלון', 'אחרי 48 שעות — ניסיון 2', '2', ch->>'attempt');
  perform pg_temp.ev(jsonb_build_object('transactionId', pfx || 'RC3', 'kind', 'renewal', 'outcome', 'approved', 'amountAgorot', 4890, 'chargeId', ch->>'chargeId'));
  perform pg_temp.chk('כישלון', 'תשלום עבר — שוב פלוס, באותו תאריך', 'true', (select (public.hdm_plan_of(pC) = 'plus' and current_period_end = public.hdm_billing_add_months(anc, 3) and status = 'active')::text from public.hdm_subscriptions where profile_id = pC));

  -- חיוב שלא קיבל תשובה — לא מנסים שוב לבד
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pC;
  r := pg_temp.as_service('select public.hdm_billing_claim_due_renewals()::text');
  update public.hdm_renewal_charges set created_at = now() - interval '3 hours' where profile_id = pC and status = 'pending';
  perform pg_temp.chk('בטיחות', 'חיוב בלי תשובה — לבדיקה ידנית, בלי ניסיון נוסף', 'ok:0',
    pg_temp.as_service(format('select count(*)::text from jsonb_array_elements(public.hdm_billing_claim_due_renewals()) e where e->>''profileId'' = %L', pC)));
  perform pg_temp.chk('בטיחות', 'מסומן "לבדיקה"', '1', (select count(*)::text from public.hdm_renewal_charges where profile_id = pC and status = 'review'));

  -- ביטול: אין יותר חיובים
  update public.hdm_renewal_charges set status = 'failed' where profile_id = pC and status = 'review';
  update public.hdm_subscriptions set current_period_end = now() + interval '1 day' where profile_id = pC;
  perform pg_temp.as_user(uC, 'select public.hdm_billing_cancel()::text');
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pC;
  perform pg_temp.chk('ביטול', 'אחרי ביטול — לא נתפס חיוב', 'ok:0',
    pg_temp.as_service(format('select count(*)::text from jsonb_array_elements(public.hdm_billing_claim_due_renewals()) e where e->>''profileId'' = %L', pC)));

  -- מחיקת חשבון מוחקת את ה-Token
  perform pg_temp.chk('מחיקה', 'מחיקת חשבון', 'ok:%', pg_temp.as_user(uC, 'select public.hdm_delete_my_data()::text'));
  perform pg_temp.chk('מחיקה', 'ה-Token נמחק', '0', (select count(*)::text from public.hdm_billing_tokens where profile_id = pC));
end $$;

select n, area as "תחום", name as "בדיקה", case when ok then '✅' else '❌ צפוי ' || exp || ' התקבל ' || coalesce(got, '∅') end as "תוצאה"
  from t_res order by n;
select 'עברו ' || count(*) filter (where ok) || ' מתוך ' || count(*) as "סיכום" from t_res;

rollback;
