-- =====================================================================
-- חיים דרך מספרים — בדיקות אכיפת האישור (14) בשרת. הכול מתבטל בסוף — לא נשמר כלום.
-- רץ על Staging (אחרי 14) ועל המסד המקומי של בדיקת המעבר (אחרי 01_production_migration).
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_consents') is null then
    raise exception 'עצירה: מנגנון האישור (14) לא מותקן. שום דבר לא הורץ.';
  end if;
end $$;

create or replace function pg_temp.as_user(p_uid uuid, p_sql text)
returns text language plpgsql as $$
declare r text;
begin
  begin
    perform set_config('request.jwt.claims',
      case when p_uid is null then '{"role":"anon"}'
           else json_build_object('sub', p_uid, 'role', 'authenticated')::text end, true);
    perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
    perform set_config('role', case when p_uid is null then 'anon' else 'authenticated' end, true);
    execute p_sql into r;
    execute 'reset role';
    return 'ok:' || coalesce(r, '');
  exception when others then
    execute 'reset role';
    return 'err:' || sqlerrm;
  end;
end $$;

create temp table t_res (n serial, area text, name text, exp text, got text, ok boolean);
create or replace function pg_temp.chk(a text, nm text, e text, g text) returns void language sql as $$
  insert into t_res (area, name, exp, got, ok) values (a, nm, e, g, coalesce(g, '∅') like e)
$$;

do $$
declare
  pfx text := 'c' || substr(md5(random()::text), 1, 6);
  uOld uuid := gen_random_uuid();   -- משתמש קיים שעוד לא אישר
  uNew uuid := gen_random_uuid();   -- משתמש חדש שאישר בהרשמה (לפני שנוצר פרופיל)
  uOth uuid := gen_random_uuid();   -- משתמש אחר שאישר
  pOld text; pNew text; pOth text; r text; req text := public.hdm_required_terms_version();
begin
  insert into auth.users (id, email, aud, role, created_at, raw_user_meta_data)
  select u, pfx || '_' || k || '@example.invalid', 'authenticated', 'authenticated', now(), m::jsonb
    from unnest(array[uOld, uNew, uOth], array['old', 'new', 'oth'],
                array['{}', json_build_object('hdm_terms', public.hdm_required_terms_version())::text, '{}']) as x(u, k, m);

  -- משתמש קיים: יש חשבון ופרופיל, אין אישור
  pOld := substr(pg_temp.as_user(uOld, 'select public.hdm_claim_profile()'), 4);
  insert into public.docs (collection, id, data) values ('profiles', pOld, jsonb_build_object('currentName', 'ותיק', 'gender', 'גבר', 'birthdate', '1980-05-05', 'birthFirstName', 'דוד', 'birthLastName', 'לוי'));
  -- משתמש אחר שאישר ויש לו פרופיל
  pOth := substr(pg_temp.as_user(uOth, 'select public.hdm_claim_profile()'), 4);
  insert into public.hdm_consents (user_id, profile_id, version, source) values (uOth, pOth, req, 'gate');
  insert into public.docs (collection, id, data) values ('profiles', pOth, jsonb_build_object('currentName', 'אחרת', 'gender', 'אישה', 'birthdate', '1985-06-06', 'birthFirstName', 'רות', 'birthLastName', 'כהן'));

  perform pg_temp.chk('גרסה', 'יש גרסה נדרשת', '2026-10-16', req);

  -- ---- משתמש קיים בלי אישור: חסום בשרת ----
  perform pg_temp.chk('בלי אישור', 'סטטוס: לא אישר', 'ok:false', pg_temp.as_user(uOld, 'select (public.hdm_terms_status()->>''accepted'')'));
  perform pg_temp.chk('בלי אישור', 'hdm_me ריק', 'ok:', pg_temp.as_user(uOld, 'select public.hdm_me()'));
  perform pg_temp.chk('בלי אישור', 'לא רואה פרופילים (גם לא את שלו)', 'ok:0', pg_temp.as_user(uOld, 'select count(*)::text from public.docs where collection = ''profiles'''));
  perform pg_temp.chk('בלי אישור', 'לא יכול לעדכן את הפרופיל', 'ok:0', pg_temp.as_user(uOld, format('with u as (update public.docs set data = data || ''{"city":"x"}'' where collection = ''profiles'' and id = %L returning 1) select count(*)::text from u', pOld)));
  perform pg_temp.chk('בלי אישור', '🎯 נחסם: HDM_TERMS_REQUIRED', 'err:HDM_TERMS_REQUIRED%', pg_temp.as_user(uOld, format('select public.hdm_send_target(%L)::text', pOth)));
  perform pg_temp.chk('בלי אישור', 'זכאויות נחסמות', 'err:HDM_TERMS_REQUIRED%', pg_temp.as_user(uOld, 'select public.hdm_my_entitlements()::text'));
  perform pg_temp.chk('בלי אישור', 'דיווח נחסם', 'err:%', pg_temp.as_user(uOld, format('insert into public.docs values (''reports'', %L, ''{"target":"x"}'') returning id', pfx || 'r1')));
  perform pg_temp.chk('בלי אישור', 'הפרופיל שלו לא נמחק ולא השתנה', 'ותיק|∅', (select (data->>'currentName') || '|' || coalesce(data->>'city', '∅') from public.docs where collection = 'profiles' and id = pOld));

  -- ---- אי אפשר לעקוף ----
  perform pg_temp.chk('עקיפה', 'אין כתיבה ישירה לטבלת האישורים', 'err:%', pg_temp.as_user(uOld, format('insert into public.hdm_consents (user_id, version, source) values (%L, %L, ''gate'') returning 1', uOld, req)));
  perform pg_temp.chk('עקיפה', 'אין קריאה של אישורים של אחרים', 'err:%', pg_temp.as_user(uOld, 'select count(*)::text from public.hdm_consents'));
  perform pg_temp.chk('עקיפה', 'גרסה שגויה נדחית', 'err:HDM_TERMS_VERSION%', pg_temp.as_user(uOld, 'select public.hdm_accept_terms(''2020-01-01'')::text'));
  perform pg_temp.chk('עקיפה', 'מקור לא חוקי נדחה', 'err:HDM_INVALID_INPUT%', pg_temp.as_user(uOld, format('select public.hdm_accept_terms(%L, ''admin'')::text', req)));
  perform pg_temp.chk('עקיפה', '"הרשמה" בלי סימון בהרשמה נדחה', 'err:HDM_TERMS_SIGNUP%', pg_temp.as_user(uOld, format('select public.hdm_accept_terms(%L, ''signup'')::text', req)));
  perform pg_temp.chk('עקיפה', 'אורח לא יכול לאשר', 'err:%', pg_temp.as_user(null, format('select public.hdm_accept_terms(%L)::text', req)));
  perform pg_temp.chk('עקיפה', 'האפליקציה לא יכולה לפרסם גרסה', 'err:%', pg_temp.as_user(uOth, 'select public.hdm_admin_publish_terms(''2030-01-01'', false)'));
  perform pg_temp.chk('עקיפה', 'עדיין לא נשמר אישור', '0', (select count(*)::text from public.hdm_consents where user_id = uOld));

  -- ---- מסך אישור: המשתמש הקיים מאשר ----
  r := pg_temp.as_user(uOld, format('select public.hdm_accept_terms(%L, ''gate'')::text', req));
  perform pg_temp.chk('אישור', 'האישור התקבל', 'ok:%"accepted": true%', r);
  perform pg_temp.chk('אישור', 'נשמר: משתמש, פרופיל, גרסה, מקור, מסמכים', '1', (select count(*)::text from public.hdm_consents where user_id = uOld and profile_id = pOld and version = req and source = 'gate' and documents = array['terms','privacy','conduct'] and accepted_at > now() - interval '1 minute'));
  perform pg_temp.chk('אישור', 'אישור כפול לא יוצר כפילות', '1', (select count(*)::text from public.hdm_consents where user_id = uOld and substr(pg_temp.as_user(uOld, format('select public.hdm_accept_terms(%L)::text', req)), 1, 3) = 'ok:'));
  perform pg_temp.chk('אישור', 'אחרי אישור: hdm_me מחזיר את הפרופיל', 'ok:' || pOld, pg_temp.as_user(uOld, 'select public.hdm_me()'));
  perform pg_temp.chk('אישור', 'אחרי אישור: רואה פרופילים', 'ok:2', pg_temp.as_user(uOld, format('select count(*)::text from public.docs where collection = ''profiles'' and id in (%L, %L)', pOld, pOth)));
  perform pg_temp.chk('אישור', 'אחרי אישור: זכאויות נטענות', 'ok:%', pg_temp.as_user(uOld, 'select public.hdm_my_entitlements()::text'));
  perform pg_temp.chk('אישור', 'אחרי אישור: יכול לעדכן את הפרופיל', 'ok:1', pg_temp.as_user(uOld, format('with u as (update public.docs set data = data || ''{"city":"חיפה"}'' where collection = ''profiles'' and id = %L returning 1) select count(*)::text from u', pOld)));

  -- ---- הרשמה חדשה: אישור לפני יצירת הפרופיל ----
  perform pg_temp.chk('הרשמה', 'בלי פרופיל עדיין: אישור נשמר', 'ok:%"accepted": true%', pg_temp.as_user(uNew, format('select public.hdm_accept_terms(%L, ''signup'')::text', req)));
  pNew := substr(pg_temp.as_user(uNew, 'select public.hdm_claim_profile()'), 4);
  perform pg_temp.chk('הרשמה', 'אחרי יצירת החשבון מזהה הפרופיל נרשם באישור', pNew, (select profile_id from public.hdm_consents where user_id = uNew));
  perform pg_temp.chk('הרשמה', 'מקור האישור: הרשמה', 'signup', (select source from public.hdm_consents where user_id = uNew));
  perform pg_temp.chk('הרשמה', 'משתמש חדש יכול ליצור פרופיל', 'ok:' || pNew, pg_temp.as_user(uNew, format('insert into public.docs values (''profiles'', %L, ''{"currentName":"חדשה","gender":"אישה","birthdate":"1992-07-07","birthFirstName":"נוי","birthLastName":"גל"}'') returning id', pNew)));

  -- ---- שינוי מהותי: אישור מחדש ----
  perform public.hdm_admin_publish_terms('2099-01-01', true, 'בדיקה: שינוי מהותי');
  perform pg_temp.chk('אישור מחדש', 'הגרסה הנדרשת התעדכנה', '2099-01-01', public.hdm_required_terms_version());
  perform pg_temp.chk('אישור מחדש', 'משתמש שאישר קודם — חסום שוב', 'ok:', pg_temp.as_user(uOld, 'select public.hdm_me()'));
  perform pg_temp.chk('אישור מחדש', 'הסטטוס מסמן אישור מחדש', 'ok:true', pg_temp.as_user(uOld, 'select (public.hdm_terms_status()->>''reconsent'')'));
  perform pg_temp.chk('אישור מחדש', 'אישור לגרסה הישנה נדחה', 'err:HDM_TERMS_VERSION%', pg_temp.as_user(uOld, format('select public.hdm_accept_terms(%L)::text', req)));
  perform pg_temp.chk('אישור מחדש', 'אישור הגרסה החדשה', 'ok:%"accepted": true%', pg_temp.as_user(uOld, 'select public.hdm_accept_terms(''2099-01-01'')::text'));
  perform pg_temp.chk('אישור מחדש', 'ההיסטוריה נשמרת (שתי גרסאות)', '2', (select count(*)::text from public.hdm_consents where user_id = uOld));
  perform public.hdm_admin_publish_terms('2099-02-01', false, 'בדיקה: תיקון לא מהותי');
  perform pg_temp.chk('אישור מחדש', 'שינוי לא מהותי לא מחייב אישור', 'ok:' || pOld, pg_temp.as_user(uOld, 'select public.hdm_me()'));

  -- ---- מחיקת חשבון: אפשרית גם בלי אישור, ומוחקת את האישורים ----
  perform pg_temp.chk('מחיקה', 'משתמש בלי אישור יכול למחוק חשבון', 'ok:%', pg_temp.as_user(uNew, 'select public.hdm_delete_my_data()::text'));
  perform pg_temp.chk('מחיקה', 'רשומות האישור נמחקו', '0', (select count(*)::text from public.hdm_consents where user_id = uNew));

  -- ---- משתמשים אחרים לא הושפעו ----
  perform pg_temp.chk('אחרים', 'הפרופיל של המשתמש האחר שלם', '1', (select count(*)::text from public.docs where collection = 'profiles' and id = pOth));
end $$;

select n, area as "תחום", name as "בדיקה", case when ok then '✅' else '❌ צפוי ' || exp || ' התקבל ' || coalesce(got, '∅') end as "תוצאה"
  from t_res order by n;
select 'עברו ' || count(*) filter (where ok) || ' מתוך ' || count(*) as "סיכום" from t_res;

rollback;
