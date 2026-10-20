-- =====================================================================
-- חיים דרך מספרים — בדיקות תור החשבוניות (30). הכול מתבטל בסוף — לא נשמר כלום. בלי פנייה ל-Morning.
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_invoice_queue') is null then
    raise exception 'עצירה: תור החשבוניות (30) לא מותקן. שום דבר לא הורץ.';
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
create or replace function pg_temp.ev(j jsonb) returns text language sql as $$
  select pg_temp.as_service(format('select public.hdm_billing_apply_grow_event(%L::jsonb)::text', j))
$$;
create or replace function pg_temp.claim() returns jsonb language sql as $$
  select substr(pg_temp.as_service('select public.hdm_invoice_claim(10)::text'), 4)::jsonb
$$;
create temp table t_res (n serial, area text, name text, exp text, got text, ok boolean);
create or replace function pg_temp.chk(a text, nm text, e text, g text) returns void language sql as $$
  insert into t_res (area, name, exp, got, ok) values (a, nm, e, g, coalesce(g, '∅') like e)
$$;

do $$
declare
  pfx text := 'iv' || substr(md5(random()::text), 1, 6);
  uA uuid := gen_random_uuid(); uB uuid := gen_random_uuid();
  pA text; pB text; r text; ck uuid; q jsonb; c jsonb; id1 bigint; ch jsonb;
  bt text := public.hdm_billing_current_terms();
begin
  delete from public.hdm_invoice_queue;     -- בתוך הטרנזקציה בלבד (מתבטל בסוף)
  insert into auth.users (id, email, aud, role, created_at, raw_user_meta_data)
  select u, pfx || '_' || k || '@Example.invalid', 'authenticated', 'authenticated', now(), '{}'::jsonb
    from unnest(array[uA, uB], array['a', 'b']) as x(u, k);
  pA := substr(pg_temp.as_user(uA, 'select public.hdm_claim_profile()'), 4);
  pB := substr(pg_temp.as_user(uB, 'select public.hdm_claim_profile()'), 4);
  insert into public.hdm_consents (user_id, profile_id, version, source)
  select u, p, public.hdm_required_terms_version(), 'gate' from unnest(array[uA, uB], array[pA, pB]) as x(u, p);
  insert into public.docs (collection, id, data)
  select 'profiles', p, '{"currentName":"בדיקה","gender":"אישה","birthdate":"1990-01-01"}'::jsonb from unnest(array[pA, pB]) as p;

  perform pg_temp.chk('הרשאות', 'משתמש לא תופס חשבוניות', 'err:%permission denied%', pg_temp.as_user(uA, 'select public.hdm_invoice_claim(1)::text'));
  perform pg_temp.chk('הרשאות', 'משתמש לא קורא את התור', 'err:%permission denied%', pg_temp.as_user(uA, 'select count(*)::text from public.hdm_invoice_queue'));

  -- ---- הצטרפות מוצלחת → בקשת מסמך אחת ----
  r := pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt));
  ck := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.ev(jsonb_build_object('transactionId', 'grow:' || pfx || 'T1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990, 'checkoutId', ck,
                                        'raw', jsonb_build_object('transactionId', pfx || 'T1')));
  perform pg_temp.chk('הצטרפות', 'נכנסה בקשת מסמך אחת', '1', (select count(*)::text from public.hdm_invoice_queue where profile_id = pA));
  perform pg_temp.chk('הצטרפות', 'סכום, מסלול, מייל, מזהה עסקה', '2990|basic|initial|' || pfx || '_a@example.invalid|' || pfx || 'T1',
    (select concat_ws('|', amount_agorot, plan, kind, email, provider_ref) from public.hdm_invoice_queue where profile_id = pA));
  perform pg_temp.ev(jsonb_build_object('transactionId', 'grow:' || pfx || 'T1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990, 'checkoutId', ck));
  perform pg_temp.chk('הצטרפות', 'אותה עסקה שוב — אין מסמך נוסף', '1', (select count(*)::text from public.hdm_invoice_queue where profile_id = pA));

  -- ---- תשלומים שלא מקבלים מסמך אוטומטי ----
  r := pg_temp.as_user(uB, format('select public.hdm_billing_start_checkout(''vip'', %L, true)::text', bt));
  ck := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.ev(jsonb_build_object('transactionId', 'grow:' || pfx || 'B0', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 100, 'checkoutId', ck));
  perform pg_temp.chk('בלי מסמך', 'סכום שגוי (לבדיקה) — אין מסמך', '0', (select count(*)::text from public.hdm_invoice_queue where profile_id = pB));
  perform pg_temp.ev(jsonb_build_object('transactionId', 'grow:' || pfx || 'B1', 'kind', 'initial', 'outcome', 'failed', 'amountAgorot', 7990, 'checkoutId', ck));
  perform pg_temp.chk('בלי מסמך', 'תשלום שנדחה — אין מסמך', '0', (select count(*)::text from public.hdm_invoice_queue where profile_id = pB));
  perform pg_temp.ev(jsonb_build_object('transactionId', 'grow:' || pfx || 'X', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990));
  perform pg_temp.chk('בלי מסמך', 'תשלום בלי ניסיון (לבדיקה) — אין מסמך', '0', (select count(*)::text from public.hdm_invoice_queue q join public.hdm_payments p on p.id = q.payment_id where p.grow_transaction_id = 'grow:' || pfx || 'X'));

  -- ---- חידוש בכרטיס שמור → מסמך ----
  perform pg_temp.as_service(format('select public.hdm_billing_save_grow_card(%L, ''CT'', ''4580'', ''נועה כהן'', ''0500000000'', ''1230'')::text', pA));
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pA;
  ch := (select e from jsonb_array_elements(substr(pg_temp.as_service('select public.hdm_billing_claim_due_renewals()::text'), 4)::jsonb) e where e->>'profileId' = pA);
  perform pg_temp.as_service(format('select public.hdm_billing_apply_card_renewal(%L::jsonb)::text',
    jsonb_build_object('chargeId', ch->>'chargeId', 'transactionId', 'grow:' || pfx || 'R1', 'outcome', 'approved', 'amountAgorot', 2990)));
  perform pg_temp.chk('חידוש', 'מסמך לחידוש', 'renewal|2990', (select kind || '|' || amount_agorot from public.hdm_invoice_queue where profile_id = pA and kind = 'renewal'));

  -- ---- שדרוג יחסי → מסמך בסכום היחסי ----
  update public.hdm_subscriptions set period_anchor = now() - interval '15 days',
         current_period_end = public.hdm_billing_add_months(now() - interval '15 days', 1) where profile_id = pA;
  q := substr(pg_temp.as_user(uA, 'select public.hdm_billing_upgrade_quote(''plus'')::text'), 4)::jsonb;
  r := pg_temp.as_user(uA, format('select public.hdm_billing_start_upgrade(''plus'', %L, true, %s)::text', bt, q->>'chargeNowAgorot'));
  perform pg_temp.ev(jsonb_build_object('transactionId', 'grow:' || pfx || 'U1', 'kind', 'upgrade', 'outcome', 'approved',
                                        'amountAgorot', (q->>'chargeNowAgorot')::int, 'checkoutId', substr(r, 4)::jsonb->>'checkoutId'));
  perform pg_temp.chk('שדרוג', 'מסמך בסכום היחסי, מסלול פלוס', 'upgrade|' || (q->>'chargeNowAgorot') || '|plus',
    (select kind || '|' || amount_agorot || '|' || plan from public.hdm_invoice_queue where profile_id = pA and kind = 'upgrade'));

  -- ---- תפיסה והפקה ----
  c := pg_temp.claim();
  perform pg_temp.chk('הפקה', 'נתפסו 3 בקשות', '3', jsonb_array_length(c)::text);
  perform pg_temp.chk('הפקה', 'עם שם המשלם ו-4 ספרות', 'נועה כהן|4580', (select (e->>'name') || '|' || (e->>'last4') from jsonb_array_elements(c) e where e->>'kind' = 'renewal'));
  perform pg_temp.chk('הפקה', 'תפיסה שנייה — כלום (אין שליחה כפולה)', '0', jsonb_array_length(pg_temp.claim())::text);
  id1 := (c->0->>'id')::bigint;
  perform pg_temp.as_service(format('select public.hdm_invoice_done(%s, true, ''doc-1'', ''30001'')::text', id1));
  perform pg_temp.chk('הפקה', 'סומן הופק עם מספר', 'issued|30001', (select status || '|' || doc_number from public.hdm_invoice_queue where id = id1));
  perform pg_temp.as_service(format('select public.hdm_invoice_done(%s, false, null, null, ''x'')::text', id1));
  perform pg_temp.chk('הפקה', 'מסמך שהופק לא "נכשל" בדיעבד', 'issued', (select status from public.hdm_invoice_queue where id = id1));

  -- ---- כישלון וניסיון חוזר ----
  id1 := (c->1->>'id')::bigint;
  perform pg_temp.as_service(format('select public.hdm_invoice_done(%s, false, null, null, ''Morning 400'')::text', id1));
  perform pg_temp.chk('כישלון', 'נכשל', 'failed', (select status from public.hdm_invoice_queue where id = id1));
  perform pg_temp.chk('כישלון', 'לא נוסה שוב לפני 30 דקות', '0', jsonb_array_length(pg_temp.claim())::text);
  update public.hdm_invoice_queue set claimed_at = now() - interval '31 minutes' where id = id1;
  perform pg_temp.chk('כישלון', 'ניסיון חוזר אחרי 30 דקות', '1', jsonb_array_length(pg_temp.claim())::text);
  update public.hdm_invoice_queue set attempts = 5 where id = id1;
  perform pg_temp.as_service(format('select public.hdm_invoice_done(%s, false, null, null, ''again'')::text', id1));
  perform pg_temp.chk('כישלון', 'אחרי 5 ניסיונות — לבדיקה', 'review', (select status from public.hdm_invoice_queue where id = id1));

  -- ---- נשלח בלי תשובה ----
  id1 := (c->2->>'id')::bigint;
  update public.hdm_invoice_queue set claimed_at = now() - interval '2 hours' where id = id1;
  perform pg_temp.claim();
  perform pg_temp.chk('בלי תשובה', 'לא נשלח שוב — לבדיקה', 'review', (select status from public.hdm_invoice_queue where id = id1));
  perform pg_temp.chk('בלי תשובה', 'מופיע ברשימת התקלות למנהל', '2', (select count(*)::text from public.hdm_invoice_issues()) );

  -- ---- מחיקת חשבון: המסמכים נשמרים ----
  perform pg_temp.as_user(uA, 'select public.hdm_delete_my_data()::text');
  perform pg_temp.chk('מחיקה', 'הרשומות נשמרות (חובת תיעוד)', '3', (select count(*)::text from public.hdm_invoice_queue where profile_id = pA));
  perform pg_temp.chk('מחיקה', 'המייל נמחק ממסמך שהופק', '∅', coalesce((select email from public.hdm_invoice_queue where profile_id = pA and status = 'issued'), '∅'));
end $$;

select n, area as "תחום", name as "בדיקה", case when ok then '✅' else '❌ צפוי ' || exp || ' התקבל ' || coalesce(got, '∅') end as "תוצאה"
  from t_res order by n;
select 'עברו ' || count(*) filter (where ok) || ' מתוך ' || count(*) as "סיכום" from t_res;

rollback;
