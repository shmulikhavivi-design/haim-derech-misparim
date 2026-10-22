-- =====================================================================
-- חיים דרך מספרים — בדיקות VIP "בקרוב": אי אפשר להצטרף/לשדרג ל-VIP; בסיסי ופלוס פתוחים; התשתית נשמרת ואפשר לפתוח שוב. הכול מתבטל בסוף.
-- =====================================================================
begin;
do $$ begin if to_regclass('public.hdm_plan_sale') is null then raise exception 'עצירה: VIP בקרוב לא מותקן. שום דבר לא הורץ.'; end if; end $$;
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
do $$
declare
  pfx text := 'vs' || substr(md5(random()::text), 1, 6);
  uA uuid := gen_random_uuid(); uB uuid := gen_random_uuid(); uC uuid := gen_random_uuid(); uD uuid := gen_random_uuid();
  pA text; pB text; pC text; pD text; r text; ck uuid;
  req text := public.hdm_required_terms_version(); bt text := public.hdm_billing_current_terms();
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

  perform pg_temp.chk('מצב', 'VIP סגור לרכישה', 'false', public.hdm_billing_plan_on_sale('vip')::text);
  perform pg_temp.chk('מצב', 'בסיסי ופלוס פתוחים', 'true|true', public.hdm_billing_plan_on_sale('basic')::text || '|' || public.hdm_billing_plan_on_sale('plus')::text);
  perform pg_temp.chk('מצב', 'מחיר ה-VIP והטבותיו נשמרו', '7990|30', (select price_agorot || '|' || limor_discount_pct from public.hdm_plans where plan = 'vip'));
  perform pg_temp.chk('הרשאות', 'משתמש לא משנה את רשימת המסלולים הפתוחים', 'err:%permission denied%',
    pg_temp.as_user(uA, 'update public.hdm_plan_sale set on_sale = true where plan = ''vip'' returning plan'));
  -- הצטרפות
  perform pg_temp.chk('הצטרפות', 'VIP נחסם בשרת עם הודעת "בקרוב"', 'err:HDM_BILLING_PLAN_SOON%',
    pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''vip'', %L, true)::text', bt)));
  perform pg_temp.chk('הצטרפות', 'לא נוצר ניסיון תשלום ל-VIP', '0', (select count(*)::text from public.hdm_checkouts where profile_id = pA));
  perform pg_temp.chk('הצטרפות', 'בסיסי פתוח', 'ok:%checkoutId%', pg_temp.as_user(uB, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt)));
  perform pg_temp.chk('הצטרפות', 'פלוס פתוח', 'ok:%checkoutId%', pg_temp.as_user(uC, format('select public.hdm_billing_start_checkout(''plus'', %L, true)::text', bt)));
  -- שדרוג: מנוי בסיסי בתשלום (תשלום ראשון מדומה)
  r := pg_temp.as_user(uD, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', bt));
  ck := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  perform pg_temp.as_service(format('select public.hdm_billing_apply_grow_event(%L::jsonb)::text',
    jsonb_build_object('transactionId', pfx || 'I1', 'kind', 'initial', 'outcome', 'approved', 'amountAgorot', 2990, 'checkoutId', ck)));
  perform pg_temp.as_service(format('select public.hdm_billing_save_token(%L, %L, ''4242'')::text', pD, pfx || 'TOKEN'));
  perform pg_temp.chk('שדרוג', 'הכנה: בסיסי פעיל', 'basic', public.hdm_plan_of(pD));
  perform pg_temp.chk('שדרוג', 'שדרוג ל-VIP נחסם בשרת', 'err:HDM_BILLING_PLAN_SOON%',
    pg_temp.as_user(uD, format('select public.hdm_billing_start_upgrade(''vip'', %L, true, %s)::text', bt,
      coalesce((substr(pg_temp.as_user(uD, 'select public.hdm_billing_upgrade_quote(''vip'')::text'), 4)::jsonb->>'chargeNowAgorot'), '0'))));
  perform pg_temp.chk('שדרוג', 'המנוי נשאר בסיסי', 'basic', public.hdm_plan_of(pD));
  perform pg_temp.chk('שדרוג', 'שדרוג לפלוס פתוח', 'ok:%',
    pg_temp.as_user(uD, format('select public.hdm_billing_start_upgrade(''plus'', %L, true, %s)::text', bt,
      (substr(pg_temp.as_user(uD, 'select public.hdm_billing_upgrade_quote(''plus'')::text'), 4)::jsonb->>'chargeNowAgorot'))));
  -- התשתית נשמרת: פתיחה מחדש עובדת
  update public.hdm_plan_sale set on_sale = true where plan = 'vip';
  perform pg_temp.chk('עתיד', 'אחרי פתיחה — אפשר להצטרף ל-VIP', 'ok:%checkoutId%', pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''vip'', %L, true)::text', bt)));
end $$;
select area || ' — ' || name || ': ' || case when ok then '✅' else '❌ (צפוי ' || exp || ', התקבל ' || coalesce(got, '∅') || ')' end as "תוצאה" from t_res order by n;
select 'עברו ' || count(*) filter (where ok) || ' מתוך ' || count(*) as "סיכום" from t_res;
rollback;
