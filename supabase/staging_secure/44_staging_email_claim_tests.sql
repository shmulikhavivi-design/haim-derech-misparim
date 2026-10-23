-- =====================================================================
-- חיים דרך מספרים — מניעת שליחה כפולה של מיילי ביטול (hdm_email_outbox_claim). בלי שליחת מייל. הכול מתבטל בסוף.
-- =====================================================================
begin;
do $$ begin if to_regprocedure('public.hdm_email_outbox_claim(integer)') is null then raise exception 'עצירה: מניעת השליחה הכפולה לא מותקנת.'; end if; end $$;
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
  pfx text := 'cl' || substr(md5(random()::text), 1, 6);
  uA uuid := gen_random_uuid(); uB uuid := gen_random_uuid(); e1 bigint; e2 bigint; r text;
begin
  insert into auth.users (id, email, aud, role, created_at, raw_user_meta_data) values
    (uA, pfx || '_a@example.invalid', 'authenticated', 'authenticated', now(), '{}'), (uB, pfx || '_b@example.invalid', 'authenticated', 'authenticated', now(), '{}');
  -- מנקים זמנית את שאר התור (בתוך העסקה בלבד) כדי שהבדיקה תהיה מבודדת
  update public.hdm_email_outbox set sent_at = coalesce(sent_at, now()) where user_id not in (uA, uB);
  insert into public.hdm_email_outbox (user_id, kind, ref_id, subject, body_text) values (uA, 'cancel_confirmed', gen_random_uuid(), 'א', 'א') returning id into e1;
  insert into public.hdm_email_outbox (user_id, kind, ref_id, subject, body_text) values (uB, 'cancel_confirmed', gen_random_uuid(), 'ב', 'ב') returning id into e2;
  perform pg_temp.chk('תפיסה', 'הרצה ראשונה תופסת את שני המיילים', 'ok:2', pg_temp.as_service('select count(*)::text from public.hdm_email_outbox_claim(20)'));
  perform pg_temp.chk('תפיסה', 'הרצה שנייה מיד אחריה — לא מקבלת אותם שוב (אין שליחה כפולה)', 'ok:0', pg_temp.as_service('select count(*)::text from public.hdm_email_outbox_claim(20)'));
  perform pg_temp.as_service(format('select public.hdm_email_outbox_done(%s, true)::text', e1));
  perform pg_temp.as_service(format('select public.hdm_email_outbox_done(%s, false, ''brevo 503'')::text', e2));
  update public.hdm_email_outbox set claimed_at = now() - interval '11 minutes' where id in (e1, e2);
  r := pg_temp.as_service('select string_agg(id::text, '','') from public.hdm_email_outbox_claim(20)');
  perform pg_temp.chk('תפיסה', 'אחרי 10 דקות: רק המייל שנכשל חוזר; המייל שנשלח לא נשלח שוב לעולם', 'ok:' || e2, r);
  perform pg_temp.chk('תפיסה', 'מוגבל ל-5 ניסיונות', 'ok:0', (select 'ok:' || count(*) from public.hdm_email_outbox where id = e2 and attempts >= 5));
  update public.hdm_email_outbox set attempts = 5, claimed_at = null where id = e2;
  perform pg_temp.chk('תפיסה', 'אחרי 5 ניסיונות — לא נתפס יותר', 'ok:0', pg_temp.as_service('select count(*)::text from public.hdm_email_outbox_claim(20)'));
  perform pg_temp.chk('הרשאות', 'משתמש לא יכול לתפוס מיילים', 'err:%', pg_temp.as_user(uA, 'select count(*)::text from public.hdm_email_outbox_claim(20)'));
  perform pg_temp.chk('נתונים', 'תוכן המייל והנמען לא השתנו', 'א|' || pfx || '_a@example.invalid', (select e.subject || '|' || u.email from public.hdm_email_outbox e join auth.users u on u.id = e.user_id where e.id = e1));
end $$;
select area || ' — ' || name || ': ' || case when ok then '✅' else '❌ (צפוי ' || exp || ', התקבל ' || coalesce(got, '∅') || ')' end as "תוצאה" from t_res order by n;
select 'עברו ' || count(*) filter (where ok) || ' מתוך ' || count(*) as "סיכום" from t_res;
rollback;
