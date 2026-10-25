-- =====================================================================
-- חיים דרך מספרים — בדיקת כל המסלולים (חינם/בסיסי/פלוס/VIP בקרוב) + התראות סליקה לבעלים. אירועים מדומים. הכול מתבטל בסוף.
-- =====================================================================
begin;
do $$ begin if to_regclass('public.hdm_billing_alerts') is null then raise exception 'עצירה: התראות הסליקה לא מותקנות. שום דבר לא הורץ.'; end if; end $$;
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
  pfx text := 'pa' || substr(md5(random()::text), 1, 6);
  uB uuid := gen_random_uuid(); uP uuid := gen_random_uuid(); uV uuid := gen_random_uuid(); uR uuid := gen_random_uuid(); uX uuid := gen_random_uuid();
  pB text; pP text; pV text; pR text; pX text; r text; ck uuid; q jsonb; ch jsonb;
  req text := public.hdm_required_terms_version(); bt text := public.hdm_billing_current_terms();
  n0 int := (select count(*) from public.hdm_billing_alerts);
begin
  insert into auth.users (id, email, aud, role, created_at, raw_user_meta_data)
  select u, pfx || '_' || k || '@example.invalid', 'authenticated', 'authenticated', now(), '{}'::jsonb
    from unnest(array[uB, uP, uV, uR, uX], array['b', 'p', 'v', 'r', 'x']) as x(u, k);
  pB := substr(pg_temp.as_user(uB, 'select public.hdm_claim_profile()'), 4); pP := substr(pg_temp.as_user(uP, 'select public.hdm_claim_profile()'), 4);
  pV := substr(pg_temp.as_user(uV, 'select public.hdm_claim_profile()'), 4); pR := substr(pg_temp.as_user(uR, 'select public.hdm_claim_profile()'), 4);
  pX := substr(pg_temp.as_user(uX, 'select public.hdm_claim_profile()'), 4);
  insert into public.hdm_consents (user_id, profile_id, version, source) select u, p, req, 'gate' from unnest(array[uB, uP, uV, uR, uX], array[pB, pP, pV, pR, pX]) as x(u, p);
  insert into public.docs (collection, id, data) select 'profiles', p, '{"currentName":"בדיקה","gender":"אישה","birthdate":"1990-01-01"}'::jsonb from unnest(array[pB, pP, pV, pR, pX]) as p;

  -- ---- הגדרות המסלולים (מחיר : דירוג : פירוט : 🎯 : צ'אט : שיחות בחודש : מי סימן אותי : ניתוח מורחב : הנחה) ----
  perform pg_temp.chk('מסלולים', 'חינם — רמת התאמה בלבד', '0:true:false:false:false:0:false:none:0', pg_temp.perms('free'));
  perform pg_temp.chk('מסלולים', 'בסיסי ₪29.90 — דירוג, 🎯, 5 שיחות חדשות בחודש', '2990:true:false:true:true:5:false:none:0', pg_temp.perms('basic'));
  perform pg_temp.chk('מסלולים', 'פלוס ₪48.90 — פירוט, שיחות ללא הגבלה, בלי ניתוח מורחב', '4890:true:true:true:true:∞:true:none:0', pg_temp.perms('plus'));
  perform pg_temp.chk('מסלולים', 'VIP ₪79.90 — נשמר כמו שהוא (ניתוח מורחב, 30%)', '7990:true:true:true:true:∞:true:after_my_target:30', pg_temp.perms('vip'));
  perform pg_temp.chk('מסלולים', 'פתוחים לרכישה: בסיסי ופלוס; VIP בקרוב', 'basic=true,plus=true,vip=false', (select string_agg(plan || '=' || on_sale, ',' order by plan) from public.hdm_plan_sale));
  perform pg_temp.chk('מסלולים', 'משתמש חדש — חינם', 'free', public.hdm_plan_of(pX));

  -- ---- בסיסי: הצטרפות → פעיל ₪29.90; חידוש בסכום הנכון ----
  r := pg_temp.as_user(uB, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt)); ck := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.chk('בסיסי', 'ניסיון תשלום ₪29.90', '2990', (select amount_agorot::text from public.hdm_checkouts where id = ck));
  perform pg_temp.ev(jsonb_build_object('transactionId', 'morning:' || pfx || 'B1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990, 'checkoutId', ck));
  perform pg_temp.as_service(format('select public.hdm_billing_save_token(%L, %L, ''1111'')::text', pB, pfx || 'TB'));
  perform pg_temp.chk('בסיסי', 'פעיל ומתחדש', 'basic|true', public.hdm_plan_of(pB) || '|' || (select auto_renew from public.hdm_subscriptions where profile_id = pB));
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pB;
  ch := coalesce((select x from jsonb_array_elements(substr(pg_temp.as_service('select public.hdm_billing_claim_due_renewals(500)::text'), 4)::jsonb) x where x->>'profileId' = pB limit 1), '{}');
  perform pg_temp.chk('בסיסי', 'חידוש: ₪29.90 בכרטיס השמור', '2990|' || pfx || 'TB', (ch->>'amountAgorot') || '|' || (ch->>'token'));
  perform pg_temp.chk('בסיסי', 'חידוש מאושר → מוארך', 'ok:%renewed%', pg_temp.as_service(format('select public.hdm_billing_apply_morning_renewal(%L::jsonb)::text',
    jsonb_build_object('chargeId', ch->>'chargeId', 'transactionId', 'morning:' || pfx || 'BR1', 'outcome', 'approved', 'amountAgorot', 2990))));

  -- ---- בסיסי → פלוס: שדרוג יחסי (לא נמוך יותר) ----
  update public.hdm_subscriptions set period_anchor = now() - interval '10 days', current_period_end = public.hdm_billing_add_months(now() - interval '10 days', 1) where profile_id = pB;
  q := substr(pg_temp.as_user(uB, 'select public.hdm_billing_upgrade_quote(''plus'')::text'), 4)::jsonb;
  perform pg_temp.chk('שדרוג', 'בסיסי→פלוס: חיוב יחסי בין ₪0 ל-₪19', 'true', ((q->>'chargeNowAgorot')::int between 1 and 1900)::text);
  perform pg_temp.chk('שדרוג', 'בסיסי→VIP חסום (בקרוב)', 'err:HDM_BILLING_PLAN_SOON%',
    pg_temp.as_user(uB, format('select public.hdm_billing_start_upgrade(''vip'', %L, true, %s)::text', bt,
      coalesce((substr(pg_temp.as_user(uB, 'select public.hdm_billing_upgrade_quote(''vip'')::text'), 4)::jsonb->>'chargeNowAgorot'), '0'))));
  r := pg_temp.as_user(uB, format('select public.hdm_billing_start_upgrade(''plus'', %L, true, %s)::text', bt, q->>'chargeNowAgorot'));
  ck := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.chk('שדרוג', 'נפתח ניסיון שדרוג בכרטיס השמור', 'true', (ck is not null)::text);
  perform pg_temp.ev(jsonb_build_object('transactionId', 'morning:' || pfx || 'U1', 'kind', 'upgrade', 'outcome', 'approved', 'amountAgorot', (q->>'chargeNowAgorot')::int, 'checkoutId', ck));
  perform pg_temp.chk('שדרוג', 'אחרי אישור — פלוס, אותו תאריך חיוב', 'plus|true', public.hdm_plan_of(pB) || '|' ||
    (select (current_period_end = public.hdm_billing_add_months(now() - interval '10 days', 1))::text from public.hdm_subscriptions where profile_id = pB));
  perform pg_temp.chk('שדרוג', 'שדרוג "למטה" (פלוס→בסיסי) לא אפשרי', 'err:%', pg_temp.as_user(uB, 'select public.hdm_billing_upgrade_quote(''basic'')::text'));

  -- ---- פלוס: הצטרפות ישירה ₪48.90, חידוש ₪48.90, ביטול ----
  r := pg_temp.as_user(uP, format('select public.hdm_billing_start_checkout(''plus'', %L, true)::text', bt)); ck := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.ev(jsonb_build_object('transactionId', 'morning:' || pfx || 'P1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 4890, 'checkoutId', ck));
  perform pg_temp.as_service(format('select public.hdm_billing_save_token(%L, %L, ''2222'')::text', pP, pfx || 'TP'));
  perform pg_temp.chk('פלוס', 'פעיל', 'plus', public.hdm_plan_of(pP));
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pP;
  ch := coalesce((select x from jsonb_array_elements(substr(pg_temp.as_service('select public.hdm_billing_claim_due_renewals(500)::text'), 4)::jsonb) x where x->>'profileId' = pP limit 1), '{}');
  perform pg_temp.chk('פלוס', 'חידוש: ₪48.90', '4890', ch->>'amountAgorot');
  perform pg_temp.as_service(format('select public.hdm_billing_apply_morning_renewal(%L::jsonb)::text',
    jsonb_build_object('chargeId', ch->>'chargeId', 'transactionId', 'morning-fail:' || pfx || 'PR1', 'outcome', 'failed', 'amountAgorot', 4890)));
  perform pg_temp.chk('התראות', 'חידוש נדחה → התראה', '1', (select count(*)::text from public.hdm_billing_alerts where kind = 'renewal_failed' and profile_id = pP));
  delete from public.hdm_renewal_charges where profile_id = pP;
  update public.hdm_subscriptions set current_period_end = now() + interval '15 days' where profile_id = pP;
  perform pg_temp.chk('פלוס', 'ביטול → פעיל עד סוף התקופה', 'ok:%"canceled": true%|plus', pg_temp.as_user(uP, 'select public.hdm_billing_cancel()::text') || '|' || public.hdm_plan_of(pP));
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pP;
  perform pg_temp.chk('פלוס', 'אחרי ביטול: לא נתפס חיוב, חוזר לחינם', '0|free',
    (select count(*)::text from jsonb_array_elements(substr(pg_temp.as_service('select public.hdm_billing_claim_due_renewals(500)::text'), 4)::jsonb) x where x->>'profileId' = pP) || '|' || public.hdm_plan_of(pP));

  -- ---- VIP: לא ניתן להצטרף ----
  perform pg_temp.chk('VIP', 'הצטרפות ל-VIP נחסמת', 'err:HDM_BILLING_PLAN_SOON%', pg_temp.as_user(uV, format('select public.hdm_billing_start_checkout(''vip'', %L, true)::text', bt)));
  perform pg_temp.chk('VIP', 'נשאר חינם', 'free', public.hdm_plan_of(pV));

  -- ---- התראות: חיוב ראשון נדחה, חידוש נדחה ×3, חיוב בלי תשובה, תשלום לבדיקה ----
  r := pg_temp.as_user(uR, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt)); ck := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.ev(jsonb_build_object('transactionId', 'morning-fail:' || ck, 'kind', 'initial', 'outcome', 'failed', 'amountAgorot', 2990, 'checkoutId', ck));
  perform pg_temp.chk('התראות', 'חיוב ראשון נדחה → התראה', '1', (select count(*)::text from public.hdm_billing_alerts where kind = 'first_charge_failed' and profile_id = pR));
  -- חיוב שנשלח ולא נסגר 15 דקות
  r := pg_temp.as_user(uX, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt)); ck := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.as_service(format('select public.hdm_billing_claim_checkout(%L, %L)::text', ck, 'morning-charge:' || ck));
  update public.hdm_checkouts set created_at = now() - interval '20 minutes' where id = ck;
  perform pg_temp.chk('התראות', 'חיוב בלי אישור 15 דק׳ → התראה (סריקה)', 'ok:1', pg_temp.as_service('select public.hdm_billing_scan_alerts()::text'));
  perform pg_temp.chk('התראות', 'סריקה חוזרת לא מכפילה', 'ok:0', pg_temp.as_service('select public.hdm_billing_scan_alerts()::text'));
  -- חידוש: בלי תשובה (review) ואז כישלון שלישי
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute', status = 'active', auto_renew = true where profile_id = pB;
  delete from public.hdm_renewal_charges where profile_id = pB;
  ch := coalesce((select x from jsonb_array_elements(substr(pg_temp.as_service('select public.hdm_billing_claim_due_renewals(500)::text'), 4)::jsonb) x where x->>'profileId' = pB limit 1), '{}');
  update public.hdm_renewal_charges set created_at = now() - interval '3 hours' where id = (ch->>'chargeId')::uuid;
  perform pg_temp.as_service('select public.hdm_billing_claim_due_renewals(0)::text');    -- מסמן "בלי תשובה" אחרי שעתיים
  perform pg_temp.chk('התראות', 'חידוש בלי תשובה ברורה → התראה', '1', (select count(*)::text from public.hdm_billing_alerts where kind = 'charge_unconfirmed' and profile_id = pB));
  insert into public.hdm_renewal_charges (profile_id, period_end, attempt, amount_agorot, status) values (pB, now() - interval '2 days', 3, 4890, 'pending');
  update public.hdm_renewal_charges set status = 'failed', closed_at = now() where profile_id = pB and attempt = 3;
  perform pg_temp.chk('התראות', 'כישלון חידוש שלישי → התראה', '1', (select count(*)::text from public.hdm_billing_alerts where kind = 'renewal_final_failure' and profile_id = pB));
  perform pg_temp.chk('התראות', 'התראה אחת לכל אירוע (4 אירועים)', 'charge_unconfirmed,charge_unconfirmed,first_charge_failed,renewal_final_failure',
    (select string_agg(kind, ',' order by kind) from public.hdm_billing_alerts where profile_id in (pB, pR, pX)));
  -- גישה: רק מקבלי התראות
  perform pg_temp.chk('התראות', 'משתמש רגיל לא רואה התראות', 'ok:[]', pg_temp.as_user(uX, 'select public.hdm_billing_alerts_mine()::text'));
  perform pg_temp.chk('התראות', 'משתמש רגיל לא קורא את הטבלה', 'err:%permission denied%', pg_temp.as_user(uX, 'select count(*)::text from public.hdm_billing_alerts'));
  perform pg_temp.chk('התראות', 'משתמש רגיל לא מסמן טופל', 'err:%HDM_NOT_ALLOWED%', pg_temp.as_user(uX, 'select public.hdm_billing_alert_resolve(1)::text'));
  insert into public.hdm_billing_alert_recipients (user_id) values (uR);
  perform pg_temp.chk('התראות', 'מקבל התראות רואה אותן', 'true', (jsonb_array_length(substr(pg_temp.as_user(uR, 'select public.hdm_billing_alerts_mine()::text'), 4)::jsonb) >= 4)::text);
  perform pg_temp.chk('התראות', 'סימון טופל', 'ok:true', pg_temp.as_user(uR, format('select public.hdm_billing_alert_resolve(%s)::text',
    (select max(id) from public.hdm_billing_alerts where profile_id = pR))));
end $$;
select area || ' — ' || name || ': ' || case when ok then '✅' else '❌ (צפוי ' || exp || ', התקבל ' || coalesce(got, '∅') || ')' end as "תוצאה" from t_res order by n;
select 'עברו ' || count(*) filter (where ok) || ' מתוך ' || count(*) as "סיכום" from t_res;
rollback;
