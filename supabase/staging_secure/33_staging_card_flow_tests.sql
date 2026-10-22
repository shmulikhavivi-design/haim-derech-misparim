-- =====================================================================
-- חיים דרך מספרים — בדיקות מסד לאפשרות 2 (כרטיס פעם אחת → חיוב מהשרת). אירועי Morning מדומים. הכול מתבטל בסוף.
-- =====================================================================
begin;
do $$ begin if to_regclass('public.hdm_billing_customers') is null then raise exception 'עצירה: 32 לא מותקן. שום דבר לא הורץ.'; end if; end $$;
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
do $$
declare
  pfx text := 'cf' || substr(md5(random()::text), 1, 6);
  uA uuid := gen_random_uuid(); uB uuid := gen_random_uuid(); pA text; pB text; r text; ckA uuid; ckB uuid; ckA2 uuid;
  req text := public.hdm_required_terms_version(); bt text := public.hdm_billing_current_terms();
begin
  insert into auth.users (id, email, aud, role, created_at, raw_user_meta_data)
  select u, pfx || '_' || k || '@example.invalid', 'authenticated', 'authenticated', now(), '{}'::jsonb from unnest(array[uA, uB], array['a', 'b']) as x(u, k);
  pA := substr(pg_temp.as_user(uA, 'select public.hdm_claim_profile()'), 4);
  pB := substr(pg_temp.as_user(uB, 'select public.hdm_claim_profile()'), 4);
  insert into public.hdm_consents (user_id, profile_id, version, source) select u, p, req, 'gate' from unnest(array[uA, uB], array[pA, pB]) as x(u, p);
  insert into public.docs (collection, id, data) select 'profiles', p, '{"currentName":"בדיקה","gender":"אישה","birthdate":"1990-01-01"}'::jsonb from unnest(array[pA, pB]) as p;

  -- טבלת הלקוחות: רק לשרת
  perform pg_temp.chk('הרשאות', 'האפליקציה לא קוראת לקוחות Morning', 'err:%permission denied%', pg_temp.as_user(uA, 'select count(*)::text from public.hdm_billing_customers'));
  perform pg_temp.chk('הרשאות', 'האפליקציה לא כותבת לקוחות Morning', 'err:%permission denied%', pg_temp.as_user(uA, format('insert into public.hdm_billing_customers values (%L, ''x'') returning 1', pA)));
  perform pg_temp.chk('הרשאות', 'השרת שומר לקוח Morning', 'ok:1', pg_temp.as_service(format('insert into public.hdm_billing_customers (profile_id, morning_client_id) values (%L, %L) returning 1', pA, pfx || '-client')));
  perform pg_temp.chk('הרשאות', 'האפליקציה לא מזינה תוצאת תשלום', 'err:%permission denied%', pg_temp.as_user(uA, 'select public.hdm_billing_apply_grow_event(''{}''::jsonb)::text'));

  -- הצטרפות: ניסיון תשלום → שמירת כרטיס (טוקן) → תפיסה → חיוב מאושר
  r := pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt)); ckA := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.chk('לפני', 'לפני חיוב — עדיין חינם', 'free', public.hdm_plan_of(pA));
  perform pg_temp.as_service(format('select public.hdm_billing_save_token(%L, %L, ''4580'')::text', pA, pfx || '-tok'));
  perform pg_temp.chk('לפני', 'שמירת כרטיס בלבד לא מפעילה מנוי', 'free', public.hdm_plan_of(pA));
  perform pg_temp.chk('כרטיס', 'נשמרים רק טוקן ו-4 ספרות', 'true', (select (grow_token = pfx || '-tok' and card_last4 = '4580') from public.hdm_billing_tokens where profile_id = pA)::text);
  perform pg_temp.chk('כרטיס', 'בטבלה אין עמודה למספר כרטיס מלא או CVV', '0',
    (select count(*)::text from information_schema.columns where table_schema = 'public' and table_name = 'hdm_billing_tokens'
      and (column_name ~* '(number|pan|cvv|cvc|card_no|cardnum)' or (column_name ~* 'card' and column_name !~* '^card_(last4|exp)$'))));
  perform pg_temp.chk('כרטיס', 'המסד דוחה מספר כרטיס מלא', 'err:%',
    pg_temp.as_service(format('select public.hdm_billing_save_token(%L, ''x'', ''4580123412341234'')::text', pB)));
  perform pg_temp.chk('כרטיס', 'האפליקציה לא קוראת טוקנים', 'err:%permission denied%', pg_temp.as_user(uA, 'select count(*)::text from public.hdm_billing_tokens'));
  perform pg_temp.chk('תפיסה', 'תפיסה ראשונה לפני חיוב מצליחה', 'ok:true', pg_temp.as_service(format('select public.hdm_billing_claim_checkout(%L, %L)::text', ckA, 'morning-charge:' || ckA)));
  perform pg_temp.chk('תפיסה', 'תפיסה שנייה נכשלת — אין חיוב כפול', 'ok:false', pg_temp.as_service(format('select public.hdm_billing_claim_checkout(%L, %L)::text', ckA, 'morning-charge:' || ckA)));
  perform pg_temp.chk('חיוב', 'חיוב מאושר עם מסמך → המנוי מופעל', 'ok:%started%',
    pg_temp.ev(jsonb_build_object('transactionId', 'morning:' || pfx || '-doc1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990, 'checkoutId', ckA)));
  perform pg_temp.chk('חיוב', 'בסיסי פעיל, מתחדש, מקור תשלום', 'basic|active|true|payment',
    (select public.hdm_plan_of(pA) || '|' || status || '|' || auto_renew || '|' || source from public.hdm_subscriptions where profile_id = pA));
  perform pg_temp.chk('חיוב', 'מועד החידוש בעוד חודש', 'true',
    (select (current_period_end between now() + interval '27 days' and now() + interval '32 days')::text from public.hdm_subscriptions where profile_id = pA));
  perform pg_temp.chk('חיוב', 'אותו מסמך פעם שנייה → כבר טופל, לא מאריך', 'ok:%already_processed%|true',
    pg_temp.ev(jsonb_build_object('transactionId', 'morning:' || pfx || '-doc1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990, 'checkoutId', ckA))
    || '|' || (select (current_period_end < now() + interval '32 days')::text from public.hdm_subscriptions where profile_id = pA)::text);
  perform pg_temp.chk('חיוב', 'אין הצטרפות שנייה בזמן מנוי פעיל', 'err:%ALREADY_SUBSCRIBED%',
    pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''plus'', %L, true)::text', bt)));
  perform pg_temp.chk('חיוב', 'תשלום אחד בלבד נרשם', '1', (select count(*)::text from public.hdm_payments where profile_id = pA and outcome = 'approved'));

  -- כרטיס נדחה
  r := pg_temp.as_user(uB, format('select public.hdm_billing_start_checkout(''plus'', %L, true)::text', bt)); ckB := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.as_service(format('select public.hdm_billing_claim_checkout(%L, %L)::text', ckB, 'morning-charge:' || ckB));
  perform pg_temp.ev(jsonb_build_object('transactionId', 'morning-fail:' || ckB, 'kind', 'initial', 'outcome', 'failed', 'amountAgorot', 4890, 'checkoutId', ckB));
  perform pg_temp.chk('נדחה', 'כרטיס נדחה → נשאר חינם', 'free', public.hdm_plan_of(pB));
  perform pg_temp.chk('נדחה', 'ניסיון התשלום נסגר', 'failed', (select status from public.hdm_checkouts where id = ckB));
  perform pg_temp.chk('נדחה', 'אפשר לנסות שוב (ניסיון חדש)', 'ok:%checkoutId%', pg_temp.as_user(uB, format('select public.hdm_billing_start_checkout(''plus'', %L, true)::text', bt)));

  -- חידוש באותו כרטיס, וביטול
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pA;
  perform pg_temp.chk('חידוש', 'במועד — נתפס חיוב חידוש בכרטיס השמור', 'true',
    (select exists (select 1 from jsonb_array_elements(substr(pg_temp.as_service('select public.hdm_billing_claim_due_renewals(500)::text'), 4)::jsonb) x
                     where x->>'profileId' = pA and x->>'token' = pfx || '-tok' and (x->>'amountAgorot')::int = 2990))::text);
  delete from public.hdm_renewal_charges where profile_id = pA;
  update public.hdm_subscriptions set current_period_end = now() + interval '20 days' where profile_id = pA;
  perform pg_temp.chk('ביטול', 'ביטול מתוך האפליקציה', 'ok:%"canceled": true%', pg_temp.as_user(uA, 'select public.hdm_billing_cancel()::text'));
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pA;
  perform pg_temp.chk('ביטול', 'אחרי ביטול — לא נתפס חיוב', '0',
    (select count(*)::text from jsonb_array_elements(substr(pg_temp.as_service('select public.hdm_billing_claim_due_renewals(500)::text'), 4)::jsonb) x where x->>'profileId' = pA));
  perform pg_temp.chk('ביטול', 'אחרי סוף התקופה — חינם', 'free', public.hdm_plan_of(pA));
end $$;
select area || ' — ' || name || ': ' || case when ok then '✅' else '❌ (צפוי ' || exp || ', התקבל ' || coalesce(got, '∅') || ')' end as "תוצאה" from t_res order by n;
select 'עברו ' || count(*) filter (where ok) || ' מתוך ' || count(*) as "סיכום" from t_res;
rollback;
