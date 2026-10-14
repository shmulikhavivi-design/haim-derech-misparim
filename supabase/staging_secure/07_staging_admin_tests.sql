-- =====================================================================
-- חיים דרך מספרים — Staging בלבד: בדיקות ללוח הניהול (06)
-- הכול רץ בתוך טרנזקציה ומתבטל בסוף — לא נשמר כלום.
-- בודק: הרשאות (אורח / משתמש רגיל / מנהל), שאין בתוצאה פרטים אישיים, ושכל מונה זז בדיוק
-- בכמות שנוצרה בבדיקה (השוואה "לפני / אחרי", כך שנתונים קיימים במסד לא משפיעים).
-- =====================================================================
do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא הורץ.';
  end if;
  if not exists (select 1 from public.hdm_staging_marker where version = 'staging_admin_dashboard_v1') then
    raise exception 'עצירה: צריך להתקין קודם את 06_staging_admin_dashboard.sql. שום דבר לא הורץ.';
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

create or replace function pg_temp.hdm_admin_tests()
returns table(n int, "תחום" text, "בדיקה" text, "צפוי" text, "התקבל" text, "עבר" text)
language plpgsql as $$
declare
  t_area text[] := '{}'; t_name text[] := '{}'; t_exp text[] := '{}'; t_got text[] := '{}';
  pfx text := 'a' || substr(md5(random()::text), 1, 5);
  uA uuid := gen_random_uuid(); uM1 uuid := gen_random_uuid(); uM2 uuid := gen_random_uuid();
  uF1 uuid := gen_random_uuid(); uF2 uuid := gen_random_uuid();
  A text; M1 text; M2 text; F1 text; F2 text;
  jb jsonb; ja jsonb; r text;
  bd constant text := 'select to_char(current_date - make_interval(years => %s, days => 10), ''YYYY-MM-DD'')';
  y20 text; y30 text; y40 text; y50 text; y62 text;
begin
  execute format(bd, 20) into y20; execute format(bd, 30) into y30; execute format(bd, 40) into y40;
  execute format(bd, 50) into y50; execute format(bd, 62) into y62;
  begin
    insert into auth.users (id, email, aud, role, created_at, last_sign_in_at)
    select u, pfx || '_' || k || '@example.invalid', 'authenticated', 'authenticated', now(), ls
      from unnest(array[uA, uM1, uM2, uF1, uF2], array['adm','m1','m2','f1','f2'],
                  array[now(), now() - interval '2 hours', now() - interval '10 days', null, null]::timestamptz[]) as x(u, k, ls);
    insert into public.hdm_admins (auth_user_id, note) values (uA, 'בדיקה');

    -- תמונת מצב לפני
    r := pg_temp.as_user(uA, $q$ select public.hdm_admin_dashboard()::text $q$);
    if r not like 'ok:%' then raise exception 'הלוח לא נטען למנהל: %', r; end if;
    jb := substr(r, 4)::jsonb;

    A  := substr(pg_temp.as_user(uA,  $q$ select public.hdm_claim_profile() $q$), 4);
    M1 := substr(pg_temp.as_user(uM1, $q$ select public.hdm_claim_profile() $q$), 4);
    M2 := substr(pg_temp.as_user(uM2, $q$ select public.hdm_claim_profile() $q$), 4);
    F1 := substr(pg_temp.as_user(uF1, $q$ select public.hdm_claim_profile() $q$), 4);
    F2 := substr(pg_temp.as_user(uF2, $q$ select public.hdm_claim_profile() $q$), 4);
    perform pg_temp.as_user(uA,  format($q$ insert into public.docs values ('profiles', %L, jsonb_build_object('currentName','מנהלת בדיקה','gender','אישה','lookingFor','גברים','birthdate',%L,'birthFirstName','רות','birthLastName','כהן')) returning id $q$, A, y40));
    perform pg_temp.as_user(uM1, format($q$ insert into public.docs values ('profiles', %L, jsonb_build_object('currentName','גבר בדיקה','gender','גבר','lookingFor','נשים','birthdate',%L,'birthFirstName','דן','birthLastName','לוי')) returning id $q$, M1, y30));
    perform pg_temp.as_user(uM2, format($q$ insert into public.docs values ('profiles', %L, jsonb_build_object('currentName','גבר ב','gender','גבר','lookingFor','נשים','birthdate',%L,'birthFirstName','משה','birthLastName','בר')) returning id $q$, M2, y62));
    perform pg_temp.as_user(uF1, format($q$ insert into public.docs values ('profiles', %L, jsonb_build_object('currentName','אישה בדיקה','gender','אישה','lookingFor','גברים','birthdate',%L,'birthFirstName','נוי','birthLastName','גל')) returning id $q$, F1, y20));
    perform pg_temp.as_user(uF2, format($q$ insert into public.docs values ('profiles', %L, jsonb_build_object('currentName','אישה ב','gender','אישה','lookingFor','גברים','birthdate',%L,'birthFirstName','טל','birthLastName','אור')) returning id $q$, F2, y50));

    perform public.hdm_admin_set_plan(M1, 'basic');
    perform public.hdm_admin_set_plan(F1, 'vip');
    perform public.hdm_admin_set_plan(F2, 'plus');
    perform public.hdm_admin_cancel(F2);

    -- 🎯 הדדי (פותח שיחה), דיווח וחסימה — כמו האפליקציה
    r := pg_temp.as_user(uM1, format($q$ select public.hdm_send_target(%L)::text $q$, F1));
    r := pg_temp.as_user(uF1, format($q$ select public.hdm_send_target(%L)::text $q$, M1));
    perform pg_temp.as_user(uM1, format($q$ insert into public.docs (collection, id, data) values ('reports', %L, jsonb_build_object('by', %L, 'target', %L, 'reason', 'בדיקה')) returning id $q$, pfx || '_r', M1, M2));
    perform pg_temp.as_user(uF2, format($q$ insert into public.docs values ('blocks', %L, '{}') returning id $q$, F2 || '__' || M2));

    r := pg_temp.as_user(uA, $q$ select public.hdm_admin_dashboard()::text $q$);
    ja := substr(r, 4)::jsonb;

    -- ================= הרשאות =================
    r := pg_temp.as_user(null, $q$ select public.hdm_admin_dashboard()::text $q$);
    t_area := t_area || text 'הרשאות'; t_name := t_name || text 'אורח לא מחובר לא מקבל נתוני ניהול';
    t_exp := t_exp || text 'נחסם'; t_got := t_got || (case when r like 'err:%' then 'נחסם' else left(r, 40) end)::text;

    r := pg_temp.as_user(uM1, $q$ select public.hdm_admin_dashboard()::text $q$);
    t_area := t_area || text 'הרשאות'; t_name := t_name || text 'משתמש רגיל מחובר לא מקבל נתוני ניהול (בדיקה בשרת)';
    t_exp := t_exp || text 'err:HDM_NOT_ADMIN'; t_got := t_got || left(r, 40);

    r := pg_temp.as_user(uM1, $q$ select public.hdm_am_i_admin()::text $q$);
    t_area := t_area || text 'הרשאות'; t_name := t_name || text 'משתמש רגיל: "האם אני מנהל" = לא';
    t_exp := t_exp || text 'ok:false'; t_got := t_got || r;

    r := pg_temp.as_user(uA, $q$ select public.hdm_am_i_admin()::text $q$);
    t_area := t_area || text 'הרשאות'; t_name := t_name || text 'מנהל: "האם אני מנהל" = כן';
    t_exp := t_exp || text 'ok:true'; t_got := t_got || r;

    r := pg_temp.as_user(uM1, $q$ select count(*)::text from public.hdm_admins $q$);
    t_area := t_area || text 'הרשאות'; t_name := t_name || text 'משתמש רגיל לא יכול לקרוא את רשימת המנהלים';
    t_exp := t_exp || text 'נחסם'; t_got := t_got || (case when r like 'err:%' or r = 'ok:0' then 'נחסם' else r end)::text;

    r := pg_temp.as_user(uM1, format($q$ insert into public.hdm_admins (auth_user_id) values (%L) returning 'x' $q$, uM1));
    t_area := t_area || text 'הרשאות'; t_name := t_name || text 'משתמש רגיל לא יכול להוסיף את עצמו כמנהל (טבלה)';
    t_exp := t_exp || text 'נחסם'; t_got := t_got || (case when r like 'err:%' then 'נחסם' else r end)::text;

    r := pg_temp.as_user(uM1, format($q$ select public.hdm_admin_grant(%L) $q$, pfx || '_m1@example.invalid'));
    t_area := t_area || text 'הרשאות'; t_name := t_name || text 'משתמש רגיל לא יכול להוסיף את עצמו כמנהל (פונקציה)';
    t_exp := t_exp || text 'נחסם'; t_got := t_got || (case when r like 'err:%' then 'נחסם' else r end)::text;

    r := pg_temp.as_user(uA, format($q$ select public.hdm_admin_grant(%L) $q$, pfx || '_m1@example.invalid'));
    t_area := t_area || text 'הרשאות'; t_name := t_name || text 'גם מנהל לא יכול להוסיף מנהלים דרך ה-API (רק SQL Editor)';
    t_exp := t_exp || text 'נחסם'; t_got := t_got || (case when r like 'err:%' then 'נחסם' else r end)::text;

    r := pg_temp.as_user(uA, $q$ select public.hdm_admin_set_plan('x', 'vip') $q$);
    t_area := t_area || text 'הרשאות'; t_name := t_name || text 'הלוח לקריאה בלבד: מנהל לא משנה מנויים דרך ה-API';
    t_exp := t_exp || text 'נחסם'; t_got := t_got || (case when r like 'err:%' then 'נחסם' else r end)::text;

    -- ================= פרטיות =================
    t_area := t_area || text 'פרטיות'; t_name := t_name || text 'אין בתוצאה אימיילים';
    t_exp := t_exp || text 'אין'; t_got := t_got || (case when ja::text like '%@%' then 'יש' else 'אין' end)::text;
    t_area := t_area || text 'פרטיות'; t_name := t_name || text 'אין בתוצאה שמות, מזהי פרופיל או תאריכי לידה';
    t_exp := t_exp || text 'אין';
    t_got := t_got || (case when ja::text ~ ('בדיקה|' || M1 || '|' || F1 || '|' || y30 || '|currentName|birthdate') then 'יש' else 'אין' end)::text;

    -- ================= משתמשים (הפרש לפני/אחרי) =================
    t_area := t_area || text 'משתמשים'; t_name := t_name || text 'סך המשתמשים +5';
    t_exp := t_exp || text '5'; t_got := t_got || (((ja#>>'{users,total}')::int - (jb#>>'{users,total}')::int)::text)::text;
    t_area := t_area || text 'משתמשים'; t_name := t_name || text 'גברים +2, נשים +3';
    t_exp := t_exp || text '2/3';
    t_got := t_got || (((ja#>>'{users,male}')::int - (jb#>>'{users,male}')::int)::text || '/' || ((ja#>>'{users,female}')::int - (jb#>>'{users,female}')::int)::text)::text;
    t_area := t_area || text 'משתמשים'; t_name := t_name || text 'אחוזי גברים + נשים + אחר + לא ידוע = 100% (בדיוק סכום הספירות)';
    t_exp := t_exp || text 'ok';
    t_got := t_got || (case when (ja#>>'{users,male}')::int + (ja#>>'{users,female}')::int + (ja#>>'{users,other}')::int + (ja#>>'{users,genderUnknown}')::int
                                = (ja#>>'{users,total}')::int then 'ok' else 'סכום שגוי' end)::text;
    t_area := t_area || text 'משתמשים'; t_name := t_name || text 'חדשים היום / השבוע / החודש: +5 בכל אחד';
    t_exp := t_exp || text '5/5/5';
    t_got := t_got || (((ja#>>'{users,newToday}')::int - (jb#>>'{users,newToday}')::int)::text || '/' ||
                      ((ja#>>'{users,newWeek}')::int  - (jb#>>'{users,newWeek}')::int)::text  || '/' ||
                      ((ja#>>'{users,newMonth}')::int - (jb#>>'{users,newMonth}')::int)::text)::text;
    t_area := t_area || text 'משתמשים'; t_name := t_name || text 'פעילים ב-24 שעות +2, ב-30 יום +3 (לפי כניסה בפועל)';
    t_exp := t_exp || text '2/3';
    t_got := t_got || (((ja#>>'{users,active24h}')::int - (jb#>>'{users,active24h}')::int)::text || '/' ||
                      ((ja#>>'{users,active30d}')::int - (jb#>>'{users,active30d}')::int)::text)::text;
    t_area := t_area || text 'גיל'; t_name := t_name || text 'קבוצות גיל: 18-24, 25-34, 35-44, 45-54, 55-64 — כל אחת +1';
    t_exp := t_exp || text '1/1/1/1/1';
    t_got := t_got || ((select string_agg((coalesce((ja->'ages'->>g)::int,0) - coalesce((jb->'ages'->>g)::int,0))::text, '/' order by g)
                         from unnest(array['18-24','25-34','35-44','45-54','55-64']) g))::text;

    -- ================= מנויים =================
    t_area := t_area || text 'מנויים'; t_name := t_name || text 'לפי מסלול: חינם +2 (מנהלת, משה), בסיסי +1, פלוס +1 (בוטל, עדיין בתוקף), VIP +1';
    t_exp := t_exp || text '2/1/1/1';
    t_got := t_got || (((ja#>>'{subscriptions,byPlan,free}')::int  - (jb#>>'{subscriptions,byPlan,free}')::int)::text  || '/' ||
                      ((ja#>>'{subscriptions,byPlan,basic}')::int - (jb#>>'{subscriptions,byPlan,basic}')::int)::text || '/' ||
                      ((ja#>>'{subscriptions,byPlan,plus}')::int  - (jb#>>'{subscriptions,byPlan,plus}')::int)::text  || '/' ||
                      ((ja#>>'{subscriptions,byPlan,vip}')::int   - (jb#>>'{subscriptions,byPlan,vip}')::int)::text)::text;
    t_area := t_area || text 'מנויים'; t_name := t_name || text 'מנויים ידניים/בדיקה לא נספרים כמשלמים ולא כהכנסה';
    t_exp := t_exp || text 'משלמים +0, ידניים +3, MRR +0';
    t_got := t_got || ('משלמים +' || ((ja#>>'{subscriptions,payingActive}')::int - (jb#>>'{subscriptions,payingActive}')::int)
                   || ', ידניים +' || ((ja#>>'{subscriptions,manualActive}')::int - (jb#>>'{subscriptions,manualActive}')::int)
                   || ', MRR +' || ((ja#>>'{subscriptions,mrrAgorot}')::int - (jb#>>'{subscriptions,mrrAgorot}')::int))::text;
    t_area := t_area || text 'מנויים'; t_name := t_name || text 'ביטולים: +1 בוטל ועדיין בתוקף, +1 ביטול ב-30 יום';
    t_exp := t_exp || text '1/1';
    t_got := t_got || (((ja#>>'{subscriptions,canceledStillValid}')::int - (jb#>>'{subscriptions,canceledStillValid}')::int)::text || '/' ||
                      ((ja#>>'{subscriptions,canceled30d}')::int - (jb#>>'{subscriptions,canceled30d}')::int)::text)::text;
    t_area := t_area || text 'הכנסות'; t_name := t_name || text 'בלי מערכת תשלום: הכנסה לא מוצגת כמספר (לא מומצאת)';
    t_exp := t_exp || text 'connected=false, revenue=null';
    t_got := t_got || ('connected=' || (ja#>>'{subscriptions,payments,connected}') || ', revenue=' || coalesce(ja#>>'{subscriptions,payments,revenueAgorot}', 'null'))::text;

    -- ================= פעילות =================
    t_area := t_area || text 'פעילות'; t_name := t_name || text '🎯 +2, התאמות הדדיות +1, שיחות +1';
    t_exp := t_exp || text '2/1/1';
    t_got := t_got || (((ja#>>'{activity,targets}')::int - (jb#>>'{activity,targets}')::int)::text || '/' ||
                      ((ja#>>'{activity,mutual}')::int  - (jb#>>'{activity,mutual}')::int)::text  || '/' ||
                      ((ja#>>'{activity,chats}')::int   - (jb#>>'{activity,chats}')::int)::text)::text;
    t_area := t_area || text 'פעילות'; t_name := t_name || text 'דיווחים +1, חסימות +1';
    t_exp := t_exp || text '1/1';
    t_got := t_got || (((ja#>>'{activity,reports}')::int - (jb#>>'{activity,reports}')::int)::text || '/' ||
                      ((ja#>>'{activity,blocks}')::int  - (jb#>>'{activity,blocks}')::int)::text)::text;

    -- הסרת הרשאת מנהל חוסמת מיד
    perform public.hdm_admin_revoke(pfx || '_adm@example.invalid');
    r := pg_temp.as_user(uA, $q$ select public.hdm_admin_dashboard()::text $q$);
    t_area := t_area || text 'הרשאות'; t_name := t_name || text 'אחרי הסרת ההרשאה: המנהל לשעבר נחסם מיד';
    t_exp := t_exp || text 'err:HDM_NOT_ADMIN'; t_got := t_got || left(r, 40);

    raise exception 'HDM_TEST_ROLLBACK';
  exception when others then
    if sqlerrm <> 'HDM_TEST_ROLLBACK' then
      t_area := t_area || text 'שגיאה'; t_name := t_name || text 'שגיאה כללית בהרצת הבדיקה';
      t_exp := t_exp || text '—'; t_got := t_got || (sqlerrm)::text;
    end if;
  end;
  execute 'reset role';

  return query
    select s.i::int, t_area[s.i], t_name[s.i], t_exp[s.i], t_got[s.i],
           case when t_got[s.i] = t_exp[s.i] then '✅' else '❌' end
      from generate_subscripts(t_name, 1) s(i)
    union all
    select 999, 'סיכום', 'עברו ' || count(*) filter (where t_got[s.i] = t_exp[s.i]) || ' מתוך ' || count(*), '', '',
           case when bool_and(t_got[s.i] = t_exp[s.i]) then '✅' else '❌' end
      from generate_subscripts(t_name, 1) s(i)
    order by 1;
end $$;

select * from pg_temp.hdm_admin_tests();
