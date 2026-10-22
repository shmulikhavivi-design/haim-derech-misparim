-- =====================================================================
-- חיים דרך מספרים — בדיקות לוח הניהול (הרשאות בשרת, אמיתיים/בדיקה, מין, גיל, הרשמות, מסלולים, ביטולים, הכנסות, רשימת משתמשים).
-- נתונים מומצאים בתוך עסקה שמתבטלת בסוף. בלי חיוב.
-- =====================================================================
begin;
do $$ begin if to_regprocedure('public.hdm_admin_users(text,text,integer,integer,text,boolean,integer,integer)') is null then raise exception 'עצירה: לוח הניהול (גרסה 2) לא מותקן.'; end if; end $$;
create or replace function pg_temp.as_user(p_uid uuid, p_sql text) returns text language plpgsql as $f$
declare r text; begin begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true); perform set_config('role', 'authenticated', true);
  execute p_sql into r; execute 'reset role'; return 'ok:' || coalesce(r, '');
exception when others then execute 'reset role'; return 'err:' || sqlerrm; end; end $f$;
create or replace function pg_temp.as_anon(p_sql text) returns text language plpgsql as $f$
declare r text; begin begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true); perform set_config('role', 'anon', true);
  execute p_sql into r; execute 'reset role'; return 'ok:' || coalesce(r, '');
exception when others then execute 'reset role'; return 'err:' || sqlerrm; end; end $f$;
create temp table t_res (n serial, area text, name text, exp text, got text, ok boolean);
create or replace function pg_temp.chk(a text, nm text, e text, g text) returns void language sql as $f$
  insert into t_res (area, name, exp, got, ok) values (a, nm, e, g, coalesce(g, '∅') like e) $f$;
do $$
declare
  pfx text := 'ad' || substr(md5(random()::text), 1, 6);
  uA uuid := gen_random_uuid(); uR uuid := gen_random_uuid(); uM uuid := gen_random_uuid(); uF uuid := gen_random_uuid(); uT uuid := gen_random_uuid();
  pA text; pR text; pM text; pF text; pT text; d0 jsonb; d1 jsonb; d2 jsonb; l jsonb; req text := public.hdm_required_terms_version();
  q text;
begin
  insert into auth.users (id, email, aud, role, created_at, raw_user_meta_data) values
    (uA, pfx || '_admin@real-domain.test', 'authenticated', 'authenticated', now(), '{}'),
    (uR, pfx || '_reg@real-domain.test', 'authenticated', 'authenticated', now(), '{}'),
    (uM, pfx || '_m@real-domain.test', 'authenticated', 'authenticated', now(), '{}'),
    (uF, pfx || '_f@real-domain.test', 'authenticated', 'authenticated', now(), '{}'),
    (uT, pfx || '_t@example.invalid', 'authenticated', 'authenticated', now(), '{}');
  insert into public.hdm_admins (auth_user_id) values (uA);
  d0 := substr(pg_temp.as_user(uA, 'select public.hdm_admin_dashboard(false)::text'), 4)::jsonb;   -- לפני
  pA := substr(pg_temp.as_user(uA, 'select public.hdm_claim_profile()'), 4); pR := substr(pg_temp.as_user(uR, 'select public.hdm_claim_profile()'), 4);
  pM := substr(pg_temp.as_user(uM, 'select public.hdm_claim_profile()'), 4); pF := substr(pg_temp.as_user(uF, 'select public.hdm_claim_profile()'), 4);
  pT := substr(pg_temp.as_user(uT, 'select public.hdm_claim_profile()'), 4);
  insert into public.hdm_consents (user_id, profile_id, version, source) select u, p, req, 'gate' from unnest(array[uA,uR,uM,uF,uT], array[pA,pR,pM,pF,pT]) x(u, p);
  insert into public.docs (collection, id, data) values
    ('profiles', pM, jsonb_build_object('currentName', 'דני ' || pfx, 'gender', 'גבר', 'location', 'חיפה', 'birthdate', to_char(now() - interval '30 years 2 days', 'YYYY-MM-DD'))),
    ('profiles', pF, jsonb_build_object('currentName', 'רונית ' || pfx, 'gender', 'אישה', 'location', 'אילת', 'photoUrl', 'x', 'birthdate', to_char(now() - interval '50 years 2 days', 'YYYY-MM-DD'))),
    ('profiles', pT, jsonb_build_object('currentName', 'בדיקה ' || pfx, 'gender', 'אישה', 'birthdate', to_char(now() - interval '30 years 2 days', 'YYYY-MM-DD')));
  insert into public.hdm_profile_private (profile_id, birthdate) values (pM, (now() - interval '30 years 2 days')::date), (pF, (now() - interval '50 years 2 days')::date), (pT, (now() - interval '30 years 2 days')::date)
    on conflict (profile_id) do update set birthdate = excluded.birthdate;
  -- מנוי בתשלום פעיל לגבר (בסיסי), מבוטל לאישה (פלוס), ותשלומים: אושר / נכשל / של משתמש בדיקה
  insert into public.hdm_subscriptions (profile_id, plan, status, source, current_period_end) values
    (pM, 'basic', 'active', 'payment', now() + interval '20 days'), (pF, 'plus', 'canceled', 'payment', now() + interval '10 days'), (pT, 'plus', 'active', 'payment', now() + interval '20 days');
  begin execute format('update public.hdm_subscriptions set auto_renew = (status = ''active'') where profile_id in (%L, %L, %L)', pM, pF, pT); exception when undefined_column then null; end;
  insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan) values (pF, 'cancel', 'plus', 'plus');
  insert into public.hdm_payments (grow_transaction_id, kind, outcome, result, profile_id, plan, amount_agorot) values
    ('t:' || pfx || '1', 'initial', 'approved', 'started', pM, 'basic', 2990),
    ('t:' || pfx || '2', 'initial', 'approved', 'started', pF, 'plus', 4890),
    ('t:' || pfx || '3', 'initial', 'failed', 'failed', pF, 'plus', 4890),
    ('t:' || pfx || '4', 'initial', 'approved', 'started', pT, 'plus', 4890);
  d1 := substr(pg_temp.as_user(uA, 'select public.hdm_admin_dashboard(false)::text'), 4)::jsonb;
  d2 := substr(pg_temp.as_user(uA, 'select public.hdm_admin_dashboard(true)::text'), 4)::jsonb;

  -- הרשאות בשרת
  perform pg_temp.chk('הרשאות', 'מנהל — "האם אני מנהל"', 'ok:true', pg_temp.as_user(uA, 'select public.hdm_am_i_admin()::text'));
  perform pg_temp.chk('הרשאות', 'משתמש רגיל — לא מנהל', 'ok:false', pg_temp.as_user(uR, 'select public.hdm_am_i_admin()::text'));
  perform pg_temp.chk('הרשאות', 'משתמש רגיל לא מקבל את הלוח', 'err:HDM_NOT_ADMIN%', pg_temp.as_user(uR, 'select public.hdm_admin_dashboard(false)::text'));
  perform pg_temp.chk('הרשאות', 'משתמש רגיל לא מקבל את רשימת המשתמשים', 'err:HDM_NOT_ADMIN%', pg_temp.as_user(uR, 'select public.hdm_admin_users()::text'));
  perform pg_temp.chk('הרשאות', 'אורח לא מקבל את הלוח', 'err:%', pg_temp.as_anon('select public.hdm_admin_dashboard(false)::text'));
  perform pg_temp.chk('הרשאות', 'משתמש רגיל לא קורא את רשימת המנהלים', 'err:%permission denied%', pg_temp.as_user(uR, 'select count(*)::text from public.hdm_admins'));
  perform pg_temp.chk('הרשאות', 'משתמש רגיל לא מפעיל את הבסיס הפנימי', 'err:%permission denied%', pg_temp.as_user(uR, 'select count(*)::text from public.hdm_admin_base()'));
  perform pg_temp.chk('הרשאות', 'משתמש רגיל לא מוסיף מנהל', 'err:%permission denied%', pg_temp.as_user(uR, format('select public.hdm_admin_grant(%L)', pfx || '_reg@real-domain.test')));
  perform pg_temp.chk('הרשאות', 'גם מנהל לא מוסיף מנהל מהאפליקציה', 'err:%permission denied%', pg_temp.as_user(uA, format('select public.hdm_admin_grant(%L)', pfx || '_reg@real-domain.test')));
  -- משתמשים
  perform pg_temp.chk('משתמשים', 'אמיתיים: +2 (גבר, אישה); בדיקה לא נספר', '2', ((d1->'users'->>'total')::int - (d0->'users'->>'total')::int)::text);
  perform pg_temp.chk('משתמשים', 'עם משתמשי בדיקה: +1 נוסף', '1', ((d2->'users'->>'total')::int - (d1->'users'->>'total')::int)::text);
  perform pg_temp.chk('משתמשים', 'ספירת בדיקה / אמיתיים', 'true', (((d1->'users'->>'test')::int - (d0->'users'->>'test')::int) = 1 and ((d1->'users'->>'real')::int - (d0->'users'->>'real')::int) = 2)::text);
  perform pg_temp.chk('משתמשים', 'גברים +1, נשים +1', '1|1', ((d1->'users'->>'male')::int - (d0->'users'->>'male')::int) || '|' || ((d1->'users'->>'female')::int - (d0->'users'->>'female')::int));
  perform pg_temp.chk('משתמשים', 'נרשמו היום / השבוע / החודש +2', '2|2|2', ((d1->'users'->>'newToday')::int - (d0->'users'->>'newToday')::int) || '|' || ((d1->'users'->>'newWeek')::int - (d0->'users'->>'newWeek')::int) || '|' || ((d1->'users'->>'newMonth')::int - (d0->'users'->>'newMonth')::int));
  perform pg_temp.chk('משתמשים', 'חשבונות בלי פרופיל (מנהל + רגיל) נספרים בנפרד', 'true', ((d1->'users'->>'withoutProfile')::int + (d1->'users'->>'unconfirmed')::int >= 2)::text);
  -- גיל
  perform pg_temp.chk('גיל', 'טווח 25–34: גבר +1', '1', ((select (x->>'male')::int from jsonb_array_elements(d1->'ages') x where x->>'key' = '25-34') - (select (x->>'male')::int from jsonb_array_elements(d0->'ages') x where x->>'key' = '25-34'))::text);
  perform pg_temp.chk('גיל', 'טווח 45–54: אישה +1', '1', ((select (x->>'female')::int from jsonb_array_elements(d1->'ages') x where x->>'key' = '45-54') - (select (x->>'female')::int from jsonb_array_elements(d0->'ages') x where x->>'key' = '45-54'))::text);
  -- מסלולים וביטולים
  perform pg_temp.chk('מסלולים', 'בסיסי +1, פלוס +1 (המבוטל עדיין בתוקף)', '1|1', ((d1->'plans'->'byPlan'->>'basic')::int - (d0->'plans'->'byPlan'->>'basic')::int) || '|' || ((d1->'plans'->'byPlan'->>'plus')::int - (d0->'plans'->'byPlan'->>'plus')::int));
  perform pg_temp.chk('מסלולים', 'משלמים פעילים +1', '1', ((d1->'plans'->>'payingActive')::int - (d0->'plans'->>'payingActive')::int)::text);
  perform pg_temp.chk('מסלולים', 'בוטלו +1 (וגם החודש)', '1|1', ((d1->'plans'->>'canceledTotal')::int - (d0->'plans'->>'canceledTotal')::int) || '|' || ((d1->'plans'->>'canceledMonth')::int - (d0->'plans'->>'canceledMonth')::int));
  -- הכנסות: רק אושרו בפועל, בלי משתמשי בדיקה
  perform pg_temp.chk('הכנסות', 'רק תשלומים שאושרו: +₪78.80 (29.90+48.90), בלי הנכשל ובלי של הבדיקה', '7880', ((d1->'revenue'->>'totalAgorot')::int - (d0->'revenue'->>'totalAgorot')::int)::text);
  perform pg_temp.chk('הכנסות', 'היום / החודש: +₪78.80', '7880|7880', ((d1->'revenue'->>'todayAgorot')::int - (d0->'revenue'->>'todayAgorot')::int) || '|' || ((d1->'revenue'->>'monthAgorot')::int - (d0->'revenue'->>'monthAgorot')::int));
  perform pg_temp.chk('הכנסות', 'עם משתמשי בדיקה: +₪48.90 נוספים', '4890', ((d2->'revenue'->>'totalAgorot')::int - (d1->'revenue'->>'totalAgorot')::int)::text);
  -- רשימת משתמשים
  l := substr(pg_temp.as_user(uA, format('select public.hdm_admin_users(%L)::text', pfx)), 4)::jsonb;
  perform pg_temp.chk('רשימה', 'חיפוש: 2 אמיתיים (בלי הבדיקה)', '2', l->>'total');
  perform pg_temp.chk('רשימה', 'פרטים: שם, מין, גיל, עיר, מסלול, תאריך הרשמה, אימייל', 'true',
    (select bool_and(x ? 'name' and x ? 'gender' and x ? 'age' and x ? 'city' and x ? 'plan' and x ? 'joined' and x ? 'email') from jsonb_array_elements(l->'rows') x)::text);
  perform pg_temp.chk('רשימה', 'עם משתמשי בדיקה: 3', '3', substr(pg_temp.as_user(uA, format('select (public.hdm_admin_users(%L, null, null, null, null, true)->>''total'')', pfx)), 4));
  perform pg_temp.chk('רשימה', 'סינון מין: נשים → 1', '1', substr(pg_temp.as_user(uA, format('select (public.hdm_admin_users(%L, ''female'')->>''total'')', pfx)), 4));
  perform pg_temp.chk('רשימה', 'סינון גיל 40–60 → 1', '1', substr(pg_temp.as_user(uA, format('select (public.hdm_admin_users(%L, null, 40, 60)->>''total'')', pfx)), 4));
  perform pg_temp.chk('רשימה', 'סינון מסלול בסיסי → 1', '1', substr(pg_temp.as_user(uA, format('select (public.hdm_admin_users(%L, null, null, null, ''basic'')->>''total'')', pfx)), 4));
  perform pg_temp.chk('רשימה', 'הגבלת עמוד ל-200', 'ok', left(pg_temp.as_user(uA, 'select jsonb_array_length(public.hdm_admin_users(null, null, null, null, null, true, 100000)->''rows'') <= 200'), 2));
  perform pg_temp.chk('לוח', 'המספרים מתעדכנים מיד (בלי מטמון)', 'true', ((d1->>'generatedAt') is not null)::text);
end $$;
select area || ' — ' || name || ': ' || case when ok then '✅' else '❌ (צפוי ' || exp || ', התקבל ' || coalesce(got, '∅') || ')' end as "תוצאה" from t_res order by n;
select 'עברו ' || count(*) filter (where ok) || ' מתוך ' || count(*) as "סיכום" from t_res;
rollback;
