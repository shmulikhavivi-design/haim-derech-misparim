-- =====================================================================
-- חיים דרך מספרים — בדיקות פרופיל מוסתר (חשבון מנהל בלבד). הכול מתבטל בסוף.
-- =====================================================================
begin;
do $$ begin if to_regclass('public.hdm_hidden_profiles') is null then raise exception 'עצירה: 40 לא מותקן.'; end if; end $$;
create or replace function pg_temp.as_user(p_uid uuid, p_sql text) returns text language plpgsql as $f$
declare r text; begin begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true); perform set_config('role', 'authenticated', true);
  execute p_sql into r; execute 'reset role'; return 'ok:' || coalesce(r, '');
exception when others then execute 'reset role'; return 'err:' || sqlerrm; end; end $f$;
create temp table t_res (n serial, area text, name text, exp text, got text, ok boolean);
create or replace function pg_temp.chk(a text, nm text, e text, g text) returns void language sql as $f$
  insert into t_res (area, name, exp, got, ok) values (a, nm, e, g, coalesce(g, '∅') like e) $f$;
do $$
declare
  pfx text := 'hd' || substr(md5(random()::text), 1, 6);
  uO uuid := gen_random_uuid(); uX uuid := gen_random_uuid(); pO text; pX text; req text := public.hdm_required_terms_version(); d0 jsonb; d1 jsonb;
begin
  insert into auth.users (id, email, aud, role, created_at, raw_user_meta_data) values
    (uO, pfx || '_owner@real-domain.test', 'authenticated', 'authenticated', now(), '{}'), (uX, pfx || '_x@real-domain.test', 'authenticated', 'authenticated', now(), '{}');
  pO := substr(pg_temp.as_user(uO, 'select public.hdm_claim_profile()'), 4); pX := substr(pg_temp.as_user(uX, 'select public.hdm_claim_profile()'), 4);
  insert into public.hdm_consents (user_id, profile_id, version, source) values (uO, pO, req, 'gate'), (uX, pX, req, 'gate');
  insert into public.docs (collection, id, data) values
    ('profiles', pO, jsonb_build_object('currentName', 'בעלים ' || pfx, 'gender', 'גבר', 'birthdate', '1976-01-01')),
    ('profiles', pX, jsonb_build_object('currentName', 'לקוחה ' || pfx, 'gender', 'אישה', 'birthdate', '1985-01-01'));
  insert into public.hdm_admins (auth_user_id) values (uO);
  perform pg_temp.chk('לפני', 'לקוחה רואה את פרופיל הבעלים', '1', substr(pg_temp.as_user(uX, format('select count(*)::text from public.docs where collection = ''profiles'' and id = %L', pO)), 4));
  d0 := substr(pg_temp.as_user(uO, 'select public.hdm_admin_dashboard(false)::text'), 4)::jsonb;
  insert into public.hdm_hidden_profiles (profile_id) values (pO);
  d1 := substr(pg_temp.as_user(uO, 'select public.hdm_admin_dashboard(false)::text'), 4)::jsonb;
  perform pg_temp.chk('הסתרה', 'לקוחה לא רואה את פרופיל הבעלים', '0', substr(pg_temp.as_user(uX, format('select count(*)::text from public.docs where collection = ''profiles'' and id = %L', pO)), 4));
  perform pg_temp.chk('הסתרה', 'הבעלים עדיין רואה את הפרופיל של עצמו', '1', substr(pg_temp.as_user(uO, format('select count(*)::text from public.docs where collection = ''profiles'' and id = %L', pO)), 4));
  perform pg_temp.chk('הסתרה', 'הבעלים עדיין רואה פרופילים אחרים', '1', substr(pg_temp.as_user(uO, format('select count(*)::text from public.docs where collection = ''profiles'' and id = %L', pX)), 4));
  perform pg_temp.chk('הסתרה', 'לקוחה ממשיכה לראות פרופילים רגילים', '1', substr(pg_temp.as_user(uX, format('select count(*)::text from public.docs where collection = ''profiles'' and id = %L', pX)), 4));
  begin
    insert into public.docs (collection, id, data) values ('interests', pX || '__' || pO, '{}'::jsonb);
    perform pg_temp.chk('הסתרה', 'אי אפשר לסמן 🎯 לבעלים', 'err:%HDM_TARGET_UNAVAILABLE%', 'ok:נשמר');
  exception when others then
    perform pg_temp.chk('הסתרה', 'אי אפשר לסמן 🎯 לבעלים', 'err:%HDM_TARGET_UNAVAILABLE%', 'err:' || sqlerrm);
  end;
  begin
    insert into public.docs (collection, id, data) values ('interests', pO || '__' || pX, '{}'::jsonb);
    perform pg_temp.chk('הסתרה', '🎯 לפרופיל רגיל עדיין נשמר', 'ok', 'ok');
  exception when others then
    perform pg_temp.chk('הסתרה', '🎯 לפרופיל רגיל עדיין נשמר', 'ok', 'err:' || sqlerrm);
  end;
  perform pg_temp.chk('הסתרה', 'משתמש לא קורא את רשימת המוסתרים', 'err:%permission denied%', pg_temp.as_user(uX, 'select count(*)::text from public.hdm_hidden_profiles'));
  perform pg_temp.chk('לוח', 'הבעלים לא נספר כמשתמש אמיתי (מנהל)', 'true', ((d1->'users'->>'real')::int = (d0->'users'->>'real')::int)::text);
  perform pg_temp.chk('לא נמחק', 'הפרופיל, החשבון וההסכמה נשארו', '1|1|1', (select count(*)::text from public.docs where collection = 'profiles' and id = pO) || '|' || (select count(*)::text from public.hdm_accounts where profile_id = pO) || '|' || (select count(*)::text from public.hdm_consents where profile_id = pO));
  delete from public.hdm_hidden_profiles where profile_id = pO;
  perform pg_temp.chk('החזרה', 'ביטול ההסתרה מחזיר את הפרופיל ללקוחה', '1', substr(pg_temp.as_user(uX, format('select count(*)::text from public.docs where collection = ''profiles'' and id = %L', pO)), 4));
end $$;
select area || ' — ' || name || ': ' || case when ok then '✅' else '❌ (צפוי ' || exp || ', התקבל ' || coalesce(got, '∅') || ')' end as "תוצאה" from t_res order by n;
select 'עברו ' || count(*) filter (where ok) || ' מתוך ' || count(*) as "סיכום" from t_res;
rollback;
