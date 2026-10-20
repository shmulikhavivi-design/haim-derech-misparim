-- =====================================================================
-- חיים דרך מספרים — בדיקות התיקון (28): חידוש ראשון בכרטיס שמור, לפני שיש מזהה סדרה של Grow.
-- הכול מתבטל בסוף — לא נשמר כלום. תשובות Grow מדומות, בלי חיוב.
-- =====================================================================
begin;

do $$
begin
  if to_regprocedure('public.hdm_billing_apply_card_renewal(jsonb)') is null then
    raise exception 'עצירה: התיקון (28) לא מותקן. שום דבר לא הורץ.';
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
    execute p_sql into r; execute 'reset role'; return 'ok:' || coalesce(r, '');
  exception when others then execute 'reset role'; return 'err:' || sqlerrm;
  end;
end $$;
create or replace function pg_temp.as_service(p_sql text)
returns text language plpgsql as $$
declare r text;
begin
  begin
    perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
    perform set_config('role', 'service_role', true);
    execute p_sql into r; execute 'reset role'; return 'ok:' || coalesce(r, '');
  exception when others then execute 'reset role'; return 'err:' || sqlerrm;
  end;
end $$;
create or replace function pg_temp.ren(j jsonb) returns text language sql as $$
  select pg_temp.as_service(format('select public.hdm_billing_apply_card_renewal(%L::jsonb)::text', j))
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
  pfx text := 'cr' || substr(md5(random()::text), 1, 6);
  uA uuid := gen_random_uuid(); uB uuid := gen_random_uuid();
  pA text; pB text; r text; ch jsonb; pe timestamptz;
  bt text := public.hdm_billing_current_terms();
begin
  insert into auth.users (id, email, aud, role, created_at, raw_user_meta_data)
  select u, pfx || '_' || k || '@example.invalid', 'authenticated', 'authenticated', now(), '{}'::jsonb
    from unnest(array[uA, uB], array['a', 'b']) as x(u, k);
  pA := substr(pg_temp.as_user(uA, 'select public.hdm_claim_profile()'), 4);
  pB := substr(pg_temp.as_user(uB, 'select public.hdm_claim_profile()'), 4);
  insert into public.hdm_consents (user_id, profile_id, version, source)
  select u, p, public.hdm_required_terms_version(), 'gate' from unnest(array[uA, uB], array[pA, pB]) as x(u, p);
  insert into public.docs (collection, id, data)
  select 'profiles', p, '{"currentName":"בדיקה","gender":"אישה","birthdate":"1990-01-01"}'::jsonb from unnest(array[pA, pB]) as p;

  perform pg_temp.chk('הרשאות', 'משתמש לא מזין תוצאת חידוש', 'err:%permission denied%',
    pg_temp.as_user(uA, format('select public.hdm_billing_apply_card_renewal(%L::jsonb)::text', jsonb_build_object('chargeId', gen_random_uuid(), 'transactionId', 'x', 'outcome', 'approved', 'amountAgorot', 1))));

  -- A: פלוס בתשלום, בלי מזהה סדרה של Grow (כמו אחרי ההצטרפות)
  r := pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''plus'', %L, true)::text', bt));
  perform pg_temp.as_service(format('select public.hdm_billing_apply_grow_event(%L::jsonb)::text',
    jsonb_build_object('transactionId', 'grow:' || pfx || 'A1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 4890, 'checkoutId', substr(r, 4)::jsonb->>'checkoutId')));
  perform pg_temp.as_service(format('select public.hdm_billing_save_grow_card(%L, ''CT'', ''4580'', ''נועה כהן'', ''0500000000'', ''1230'')::text', pA));
  perform pg_temp.chk('הכנה', 'אין מזהה סדרה', '∅', coalesce((select grow_direct_debit_id from public.hdm_subscriptions where profile_id = pA), '∅'));

  -- חידוש ראשון נדחה — לפני התיקון נרשם unknown
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pA;
  select current_period_end into pe from public.hdm_subscriptions where profile_id = pA;
  ch := pg_temp.claim_for(pA);
  perform pg_temp.chk('נדחה', 'נרשם כישלון (לא unknown)', 'ok:%"failed"%',
    pg_temp.ren(jsonb_build_object('chargeId', ch->>'chargeId', 'transactionId', 'grow-fail:' || (ch->>'chargeId') || ':1', 'outcome', 'failed', 'amountAgorot', 4890)));
  perform pg_temp.chk('נדחה', 'מצב past_due', 'past_due', (select status from public.hdm_subscriptions where profile_id = pA));
  perform pg_temp.chk('נדחה', 'לא הוארך', pe::text, (select current_period_end::text from public.hdm_subscriptions where profile_id = pA));
  perform pg_temp.chk('נדחה', 'החיוב סומן failed (ייתכן ניסיון חוזר)', 'failed', (select status from public.hdm_renewal_charges where id = (ch->>'chargeId')::uuid));
  update public.hdm_renewal_charges set closed_at = now() - interval '49 hours' where id = (ch->>'chargeId')::uuid;
  ch := pg_temp.claim_for(pA);
  perform pg_temp.chk('ניסיון חוזר', 'נתפס ניסיון 2 אחרי 48 שעות', '2', ch->>'attempt');
  perform pg_temp.chk('ניסיון חוזר', 'מאושר → הוארך (בלי מזהה סדרה)', 'ok:%"renewed"%',
    pg_temp.ren(jsonb_build_object('chargeId', ch->>'chargeId', 'transactionId', 'grow:' || pfx || 'A2', 'outcome', 'approved', 'amountAgorot', 4890)));
  perform pg_temp.chk('ניסיון חוזר', 'פעיל שוב', 'active', (select status from public.hdm_subscriptions where profile_id = pA));

  -- B: חידוש ראשון מאושר, Grow לא החזירה מזהה סדרה — לפני התיקון לא הוארך
  r := pg_temp.as_user(uB, format('select public.hdm_billing_start_checkout(''vip'', %L, true)::text', bt));
  perform pg_temp.as_service(format('select public.hdm_billing_apply_grow_event(%L::jsonb)::text',
    jsonb_build_object('transactionId', 'grow:' || pfx || 'B1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 7990, 'checkoutId', substr(r, 4)::jsonb->>'checkoutId')));
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pB;
  perform pg_temp.as_service(format('select public.hdm_billing_save_grow_card(%L, ''CTB'', ''1111'', ''דני לוי'', ''0520000000'', ''0128'')::text', pB));
  ch := pg_temp.claim_for(pB);
  perform pg_temp.chk('מאושר בלי מזהה', 'הוארך', 'ok:%"renewed"%',
    pg_temp.ren(jsonb_build_object('chargeId', ch->>'chargeId', 'transactionId', 'grow:' || pfx || 'B2', 'outcome', 'approved', 'amountAgorot', 7990)));
  perform pg_temp.chk('מאושר בלי מזהה', 'נגבה מחיר VIP', '7990', (select amount_agorot::text from public.hdm_payments where grow_transaction_id = 'grow:' || pfx || 'B2'));
  perform pg_temp.chk('מאושר בלי מזהה', 'החיוב סומן approved', 'approved', (select status from public.hdm_renewal_charges where id = (ch->>'chargeId')::uuid));
end $$;

select n, area as "תחום", name as "בדיקה", case when ok then '✅' else '❌ צפוי ' || exp || ' התקבל ' || coalesce(got, '∅') end as "תוצאה"
  from t_res order by n;
select 'עברו ' || count(*) filter (where ok) || ' מתוך ' || count(*) as "סיכום" from t_res;

rollback;
