-- =====================================================================
-- חיים דרך מספרים — בדיקות hdm_billing_pending_card_checkouts (אחרי 47). משתמשים מומצאים, בלי חיובים. הכול מתבטל בסוף.
-- =====================================================================
begin;
do $$ begin if to_regclass('public.hdm_staging_marker') is null then raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא הורץ.'; end if; end $$;
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
  pfx text := 'cs' || substr(md5(random()::text), 1, 6);
  u uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  k text[] := array['due','fresh','nocust','token','claimed','expired'];
  p text[] := '{}'; ck uuid[] := '{}'; r text; j jsonb; ids text; i int;
  req text := public.hdm_required_terms_version(); bt text := public.hdm_billing_current_terms();
begin
  insert into auth.users (id, email, aud, role, created_at, raw_user_meta_data)
  select x.u, pfx || '_' || x.k || '@example.invalid', 'authenticated', 'authenticated', now(), '{}'::jsonb from unnest(u, k) as x(u, k);
  for i in 1 .. 6 loop
    p := p || substr(pg_temp.as_user(u[i], 'select public.hdm_claim_profile()'), 4);
    insert into public.hdm_consents (user_id, profile_id, version, source) values (u[i], p[i], req, 'gate');
    insert into public.docs (collection, id, data) values ('profiles', p[i], '{"currentName":"בדיקה","gender":"אישה","birthdate":"1990-01-01"}'::jsonb);
    r := pg_temp.as_user(u[i], format('select public.hdm_billing_start_checkout(''plus'', %L, true)::text', bt));
    ck := ck || (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  end loop;
  perform pg_temp.chk('הכנה', 'נפתחו 6 ניסיונות הצטרפות', '6', (select count(*)::text from public.hdm_checkouts where id = any(ck) and status = 'pending'));
  -- מצבים: due = ממתין לשמירת כרטיס (צריך להופיע); כל השאר — אסור
  update public.hdm_checkouts set created_at = now() - interval '3 minutes' where id = any(ck) and id <> ck[2];
  insert into public.hdm_billing_customers (profile_id, morning_client_id) select p[g], pfx || '-cl-' || g from generate_series(1, 6) g where g <> 3;
  insert into public.hdm_billing_tokens (profile_id, grow_token, card_last4) values (p[4], pfx || '-tok', '4580');
  update public.hdm_checkouts set grow_process_id = 'morning-charge:' || id where id = ck[5];
  update public.hdm_checkouts set expires_at = now() - interval '1 second' where id = ck[6];

  r := pg_temp.as_service('select public.hdm_billing_pending_card_checkouts(50)::text');
  perform pg_temp.chk('שרת', 'service_role יכול להריץ', 'ok:%', left(r, 4));
  j := substr(r, 4)::jsonb;
  ids := (select string_agg(e->>'id', ',') from jsonb_array_elements(j) e where (e->>'id')::uuid = any(ck));
  perform pg_temp.chk('בחירה', 'רק הניסיון שממתין לכרטיס (due) מוחזר', ck[1]::text, ids);
  perform pg_temp.chk('בחירה', 'נפתח לפני פחות מדקה — לא', 'false', (ids like '%' || ck[2] || '%')::text);
  perform pg_temp.chk('בחירה', 'בלי לקוח Morning — לא', 'false', (ids like '%' || ck[3] || '%')::text);
  perform pg_temp.chk('בחירה', 'כבר יש כרטיס שמור — לא', 'false', (ids like '%' || ck[4] || '%')::text);
  perform pg_temp.chk('בחירה', 'כבר נתפס לחיוב — לא', 'false', (ids like '%' || ck[5] || '%')::text);
  perform pg_temp.chk('בחירה', 'פג תוקף — לא', 'false', (ids like '%' || ck[6] || '%')::text);
  perform pg_temp.chk('מבנה', 'אותו מבנה כמו hdm_billing_checkout_lookup', 'plus|4890|pending|false',
    (select (e->>'plan') || '|' || (e->>'amountAgorot') || '|' || (e->>'status') || '|' || (e->>'expired') from jsonb_array_elements(j) e where e->>'id' = ck[1]::text));
  perform pg_temp.chk('הרשאות', 'משתמש באפליקציה לא יכול להריץ', 'err:%permission denied%', pg_temp.as_user(u[1], 'select public.hdm_billing_pending_card_checkouts(50)::text'));
  perform pg_temp.chk('הרשאות', 'anon לא יכול להריץ', 'false', has_function_privilege('anon', 'public.hdm_billing_pending_card_checkouts(int)', 'execute')::text);
  perform pg_temp.chk('קריאה בלבד', 'הפונקציה לא שינתה אף ניסיון', '1|1|1|1|1|1',
    (select string_agg(cnt::text, '|') from (select count(*) cnt from public.hdm_checkouts where id = any(ck) group by id order by id) x));
  perform pg_temp.chk('תפיסה', 'אחרי תפיסה אטומית — לא מוחזר שוב (אין חיוב כפול מהמשימה)', 'ok:true',
    pg_temp.as_service(format('select public.hdm_billing_claim_checkout(%L, %L)::text', ck[1], 'morning-charge:' || ck[1])));
  perform pg_temp.chk('תפיסה', 'תפיסה שנייה נכשלת', 'ok:false', pg_temp.as_service(format('select public.hdm_billing_claim_checkout(%L, %L)::text', ck[1], 'morning-charge:' || ck[1])));
  r := pg_temp.as_service('select public.hdm_billing_pending_card_checkouts(50)::text');
  perform pg_temp.chk('תפיסה', 'הניסיון שנתפס כבר לא ברשימה', 'false', (r like '%' || ck[1] || '%')::text);
  perform pg_temp.chk('מנוי', 'אף מנוי לא הופעל בבדיקה', '0', (select count(*)::text from public.hdm_subscriptions where profile_id = any(p) and plan <> 'free'));
end $$;
select n, area as "תחום", name as "בדיקה", exp as "צפוי", got as "התקבל", case when ok then '✅' else '❌' end as "עבר" from t_res order by n;
select 'סיכום: עברו ' || count(*) filter (where ok) || ' מתוך ' || count(*) as "סיכום" from t_res;
rollback;
