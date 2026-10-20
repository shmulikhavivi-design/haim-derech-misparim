-- =====================================================================
-- חיים דרך מספרים — בדיקות החיבור ל-Morning (24). הכול מתבטל בסוף — לא נשמר כלום.
-- תוצאות Morning מדומות בלבד (אין קריאה ל-Morning ואין חיוב). רץ על Staging אחרי 24.
-- =====================================================================
begin;

do $$
begin
  if to_regprocedure('public.hdm_billing_checkout_lookup(uuid)') is null then
    raise exception 'עצירה: החיבור ל-Morning (24) לא מותקן. שום דבר לא הורץ.';
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
create or replace function pg_temp.ren(j jsonb) returns text language sql as $$
  select pg_temp.as_service(format('select public.hdm_billing_apply_morning_renewal(%L::jsonb)::text', j))
$$;
create or replace function pg_temp.claim_for(p text) returns jsonb language sql as $$
  select coalesce((select e from jsonb_array_elements(substr(pg_temp.as_service('select public.hdm_billing_claim_due_renewals()::text'), 4)::jsonb) e
                    where e->>'profileId' = p limit 1), '{}'::jsonb)
$$;
create temp table t_res (n serial, area text, name text, exp text, got text, ok boolean);
create or replace function pg_temp.chk(a text, nm text, e text, g text) returns void language sql as $$
  insert into t_res (area, name, exp, got, ok) values (a, nm, e, g, coalesce(g, '∅') like e)
$$;

do $$
declare
  pfx text := 'mo' || substr(md5(random()::text), 1, 6);
  uA uuid := gen_random_uuid(); uB uuid := gen_random_uuid();
  pA text; pB text; r text; ck uuid; ckU uuid; ch jsonb; ch2 jsonb; pe timestamptz; pe2 timestamptz; q jsonb;
  req text := public.hdm_required_terms_version();
  bt  text := public.hdm_billing_current_terms();
begin
  insert into auth.users (id, email, aud, role, created_at, raw_user_meta_data)
  select u, pfx || '_' || k || '@Example.invalid', 'authenticated', 'authenticated', now(), '{}'::jsonb
    from unnest(array[uA, uB], array['a', 'b']) as x(u, k);
  pA := substr(pg_temp.as_user(uA, 'select public.hdm_claim_profile()'), 4);
  pB := substr(pg_temp.as_user(uB, 'select public.hdm_claim_profile()'), 4);
  insert into public.hdm_consents (user_id, profile_id, version, source)
  select u, p, req, 'gate' from unnest(array[uA, uB], array[pA, pB]) as x(u, p);
  insert into public.docs (collection, id, data)
  select 'profiles', p, '{"currentName":"בדיקה","gender":"אישה","birthdate":"1990-01-01"}'::jsonb from unnest(array[pA, pB]) as p;

  -- ---- הרשאות ----
  r := pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt));
  ck := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.chk('הרשאות', 'משתמש לא קורא פרטי ניסיון תשלום', 'err:%permission denied%',
    pg_temp.as_user(uA, format('select public.hdm_billing_checkout_lookup(%L)::text', ck)));
  perform pg_temp.chk('הרשאות', 'משתמש לא מזין תוצאת חידוש', 'err:%permission denied%',
    pg_temp.as_user(uA, format('select public.hdm_billing_apply_morning_renewal(%L::jsonb)::text',
      jsonb_build_object('chargeId', gen_random_uuid(), 'transactionId', 'x', 'outcome', 'approved', 'amountAgorot', 1))));

  -- ---- פרטי ניסיון התשלום לשרת ----
  q := substr(pg_temp.as_service(format('select public.hdm_billing_checkout_lookup(%L)::text', ck)), 4)::jsonb;
  perform pg_temp.chk('lookup', 'סכום בסיסי', '2990', q->>'amountAgorot');
  perform pg_temp.chk('lookup', 'סוג: הצטרפות', 'initial', q->>'kind');
  perform pg_temp.chk('lookup', 'מייל באותיות קטנות', pfx || '_a@example.invalid', q->>'email');
  perform pg_temp.chk('lookup', 'שייך למשתמש', uA::text, q->>'userId');
  perform pg_temp.chk('lookup', 'עוד אין כרטיס שמור', '∅', coalesce(q->>'token', '∅'));
  perform pg_temp.chk('תפיסה', 'משתמש לא תופס ניסיון', 'err:%permission denied%',
    pg_temp.as_user(uA, format('select public.hdm_billing_claim_checkout(%L, ''x'')::text', ck)));
  perform pg_temp.chk('תפיסה', 'תפיסה ראשונה מצליחה', 'ok:true', pg_temp.as_service(format('select public.hdm_billing_claim_checkout(%L, ''morning-form:1'')::text', ck)));
  perform pg_temp.chk('תפיסה', 'תפיסה שנייה נכשלת (לחיצה כפולה)', 'ok:false', pg_temp.as_service(format('select public.hdm_billing_claim_checkout(%L, ''morning-form:2'')::text', ck)));
  perform pg_temp.chk('lookup', 'ניסיון לא קיים → ריק', 'ok:', pg_temp.as_service(format('select public.hdm_billing_checkout_lookup(%L)::text', gen_random_uuid())));

  -- ---- תשלום ראשון מאומת (Morning) — בלי מזהה סדרת חיובים ----
  perform pg_temp.chk('הצטרפות', 'תשלום מאושר', 'ok:%"started"%',
    pg_temp.ev(jsonb_build_object('transactionId', 'morning:' || pfx || 'D1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990, 'checkoutId', ck)));
  perform pg_temp.chk('הצטרפות', 'בסיסי פעיל', 'basic', public.hdm_plan_of(pA));
  perform pg_temp.chk('הצטרפות', 'אין סדרת חיובים אצל הספק', '∅', coalesce((select grow_direct_debit_id from public.hdm_subscriptions where profile_id = pA), '∅'));
  perform pg_temp.chk('הצטרפות', 'אותו מסמך שוב — לא נקלט פעמיים', 'ok:%already_processed%',
    pg_temp.ev(jsonb_build_object('transactionId', 'morning:' || pfx || 'D1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990, 'checkoutId', ck)));
  perform pg_temp.as_service(format('select public.hdm_billing_save_token(%L, %L, ''4242'')::text', pA, pfx || 'TOK'));
  perform pg_temp.chk('lookup', 'הכרטיס השמור מופיע', pfx || 'TOK',
    substr(pg_temp.as_service(format('select public.hdm_billing_checkout_lookup(%L)::text', ck)), 4)::jsonb->>'token');

  -- ---- תשלום שלא שייך לאף ניסיון: לא מפעיל, מסומן לבדיקה ----
  perform pg_temp.chk('בטיחות', 'מסמך בלי ניסיון תשלום → unknown + בדיקה', 'ok:%"unknown"%"needsReview": true%',
    pg_temp.ev(jsonb_build_object('transactionId', 'morning:' || pfx || 'X1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990)));
  perform pg_temp.chk('בטיחות', 'B לא קיבל מסלול', 'free', public.hdm_plan_of(pB));

  -- ---- חידוש בכרטיס השמור ----
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pA;
  select period_anchor into pe from public.hdm_subscriptions where profile_id = pA;
  ch := pg_temp.claim_for(pA);
  perform pg_temp.chk('חידוש', 'נתפס חיוב אחד', '2990', ch->>'amountAgorot');
  perform pg_temp.chk('חידוש', 'עם הכרטיס השמור', pfx || 'TOK', ch->>'token');
  perform pg_temp.chk('חידוש', 'הרצה כפולה לא תופסת שוב', '{}', pg_temp.claim_for(pA)::text);
  perform pg_temp.chk('חידוש', 'חיוב מאושר', 'ok:%"renewed"%',
    pg_temp.ren(jsonb_build_object('chargeId', ch->>'chargeId', 'transactionId', 'morning:' || pfx || 'R1', 'outcome', 'approved', 'amountAgorot', 2990)));
  perform pg_temp.chk('חידוש', 'התקופה הוארכה', 'true', ((select current_period_end from public.hdm_subscriptions where profile_id = pA) > now() + interval '20 days')::text);
  perform pg_temp.chk('חידוש', 'החיוב סומן מאושר', 'approved', (select status from public.hdm_renewal_charges where id = (ch->>'chargeId')::uuid));
  perform pg_temp.chk('חידוש', 'אותה עסקה שוב — לא מאריך פעמיים', 'ok:%already_processed%',
    pg_temp.ren(jsonb_build_object('chargeId', ch->>'chargeId', 'transactionId', 'morning:' || pfx || 'R1', 'outcome', 'approved', 'amountAgorot', 2990)));
  perform pg_temp.chk('חידוש', 'אותו תאריך חיוב (עוגן לא השתנה)', pe::text, (select period_anchor::text from public.hdm_subscriptions where profile_id = pA));

  -- ---- חיוב שנכשל (תקופה חדשה; now() קבוע בתוך הטרנזקציה, לכן מועד שונה מהקודם) ----
  update public.hdm_subscriptions set current_period_end = now() - interval '2 minutes' where profile_id = pA;
  select current_period_end into pe2 from public.hdm_subscriptions where profile_id = pA;
  ch2 := pg_temp.claim_for(pA);
  perform pg_temp.chk('כישלון', 'חיוב נכשל', 'ok:%"failed"%',
    pg_temp.ren(jsonb_build_object('chargeId', ch2->>'chargeId', 'transactionId', 'morning-fail:' || (ch2->>'chargeId') || ':1', 'outcome', 'failed', 'amountAgorot', 2990)));
  perform pg_temp.chk('כישלון', 'המנוי לא הוארך', pe2::text, (select current_period_end::text from public.hdm_subscriptions where profile_id = pA));
  perform pg_temp.chk('כישלון', 'מצב: past_due', 'past_due', (select status from public.hdm_subscriptions where profile_id = pA));
  perform pg_temp.chk('כישלון', 'אין ניסיון חוזר לפני 48 שעות', '{}', pg_temp.claim_for(pA)::text);

  -- ---- סכום שגוי ----
  update public.hdm_renewal_charges set closed_at = now() - interval '49 hours' where id = (ch2->>'chargeId')::uuid;
  ch2 := pg_temp.claim_for(pA);
  perform pg_temp.chk('בטיחות', 'ניסיון שני אחרי 48 שעות', '2', ch2->>'attempt');
  perform pg_temp.chk('בטיחות', 'סכום שגוי → לא מאריך, לבדיקה', 'ok:%"amount_mismatch"%',
    pg_temp.ren(jsonb_build_object('chargeId', ch2->>'chargeId', 'transactionId', 'morning:' || pfx || 'R2', 'outcome', 'approved', 'amountAgorot', 2900)));
  perform pg_temp.chk('בטיחות', 'המנוי לא הוארך', pe2::text, (select current_period_end::text from public.hdm_subscriptions where profile_id = pA));

  -- ---- ביטול: מאושר מיד (אין סדרת חיובים אצל הספק), ושום חיוב נוסף ----
  update public.hdm_subscriptions set status = 'active', failed_attempts = 0, current_period_end = now() + interval '10 days' where profile_id = pA;
  perform pg_temp.chk('ביטול', 'ביטול מהאפליקציה', 'ok:%"cancelState": "confirmed"%', pg_temp.as_user(uA, 'select public.hdm_billing_cancel()::text'));
  perform pg_temp.chk('ביטול', 'בלי בקשה בתור לספק', '0', (select count(*)::text from public.hdm_grow_outbox where profile_id = pA));
  perform pg_temp.chk('ביטול', 'עדיין בסיסי עד סוף התקופה', 'basic', public.hdm_plan_of(pA));
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pA;
  perform pg_temp.chk('ביטול', 'בסוף התקופה — לא נתפס חיוב', '{}', pg_temp.claim_for(pA)::text);

  -- ---- חיוב שהגיע אחרי ביטול: לא מאריך, להחזר ----
  perform pg_temp.chk('ביטול', 'חיוב אחרי ביטול → after_cancel + בדיקה', 'ok:%"after_cancel"%"needsReview": true%',
    pg_temp.ren(jsonb_build_object('chargeId', ch->>'chargeId', 'transactionId', 'morning:' || pfx || 'R9', 'outcome', 'approved', 'amountAgorot', 2990)));

  -- ---- שדרוג יחסי שמאושר בחיוב Morning ----
  r := pg_temp.as_user(uB, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt));
  ck := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.ev(jsonb_build_object('transactionId', 'morning:' || pfx || 'B1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990, 'checkoutId', ck));
  perform pg_temp.as_service(format('select public.hdm_billing_save_token(%L, %L, ''1111'')::text', pB, pfx || 'TOKB'));
  update public.hdm_subscriptions set period_anchor = now() - interval '15 days',
         current_period_end = public.hdm_billing_add_months(now() - interval '15 days', 1) where profile_id = pB;
  q := substr(pg_temp.as_user(uB, 'select public.hdm_billing_upgrade_quote(''plus'')::text'), 4)::jsonb;
  r := pg_temp.as_user(uB, format('select public.hdm_billing_start_upgrade(''plus'', %L, true, %s)::text', bt, q->>'chargeNowAgorot'));
  ckU := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  q := substr(pg_temp.as_service(format('select public.hdm_billing_checkout_lookup(%L)::text', ckU)), 4)::jsonb;
  perform pg_temp.chk('שדרוג', 'lookup: סוג שדרוג עם כרטיס שמור', 'upgrade|' || pfx || 'TOKB', (q->>'kind') || '|' || (q->>'token'));
  perform pg_temp.chk('שדרוג', 'חיוב יחסי מאושר → פלוס', 'ok:%"upgraded"%',
    pg_temp.ev(jsonb_build_object('transactionId', 'morning:' || pfx || 'U1', 'kind', 'upgrade', 'outcome', 'approved',
      'amountAgorot', (q->>'amountAgorot')::int, 'checkoutId', ckU)));
  perform pg_temp.chk('שדרוג', 'פלוס פעיל', 'plus', public.hdm_plan_of(pB));
end $$;

select n, area as "תחום", name as "בדיקה", case when ok then '✅' else '❌ צפוי ' || exp || ' התקבל ' || coalesce(got, '∅') end as "תוצאה"
  from t_res order by n;
select 'עברו ' || count(*) filter (where ok) || ' מתוך ' || count(*) as "סיכום" from t_res;

rollback;
