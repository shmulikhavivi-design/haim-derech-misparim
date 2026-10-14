-- =====================================================================
-- חיים דרך מספרים — Staging בלבד: בדיקות ל"רשומים ומחוברים כרגע" (10)
-- הכול רץ בתוך טרנזקציה ומתבטל בסוף — לא נשמר כלום. השוואה "לפני / אחרי".
-- =====================================================================
do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא הורץ.';
  end if;
  if not exists (select 1 from public.hdm_staging_marker where version = 'staging_admin_live_v1') then
    raise exception 'עצירה: צריך להתקין קודם את 10_staging_admin_live.sql. שום דבר לא הורץ.';
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

create or replace function pg_temp.hdm_live_tests()
returns table(n int, "תחום" text, "בדיקה" text, "צפוי" text, "התקבל" text, "עבר" text)
language plpgsql as $$
declare
  t_area text[] := '{}'; t_name text[] := '{}'; t_exp text[] := '{}'; t_got text[] := '{}';
  pfx text := 'l' || substr(md5(random()::text), 1, 5);
  -- adm: session עכשיו · now1: נכנס לפני 5 דק' · ref: נכנס אתמול, רענון לפני 20 דק' (שתי סשנים, נספר פעם אחת)
  -- old: פעילות לפני 3 שעות · none: בלי session (התנתק) · exp: session שפג תוקפו
  ks text[] := array['adm','now1','ref','old','none','exp'];
  u uuid[] := '{}'; pid text[] := '{}'; i int; jb jsonb; ja jsonb; r text; has_na boolean;
begin
  has_na := exists (select 1 from information_schema.columns where table_schema='auth' and table_name='sessions' and column_name='not_after');
  begin
    for i in 1 .. array_length(ks, 1) loop
      u := u || gen_random_uuid();
      insert into auth.users (id, email, aud, role, created_at) values (u[i], pfx || '_' || ks[i] || '@example.invalid', 'authenticated', 'authenticated', now());
    end loop;
    insert into public.hdm_admins (auth_user_id, note) values (u[1], 'בדיקה');
    r := pg_temp.as_user(u[1], $q$ select public.hdm_admin_live()::text $q$);
    if r not like 'ok:%' then raise exception 'הנתונים לא נטענו למנהל: %', r; end if;
    jb := substr(r, 4)::jsonb;

    for i in 1 .. array_length(ks, 1) loop
      pid := pid || substr(pg_temp.as_user(u[i], $q$ select public.hdm_claim_profile() $q$), 4);
      r := pg_temp.as_user(u[i], format($q$ insert into public.docs values ('profiles', %L, jsonb_build_object('currentName','בדיקה','gender','גבר','lookingFor','נשים','birthdate','1990-01-01','birthFirstName','א','birthLastName','ב')) returning id $q$, pid[i]));
      if r not like 'ok:%' then raise exception 'יצירת פרופיל נכשלה: %', r; end if;
    end loop;
    insert into auth.sessions (id, user_id, created_at, updated_at) values
      (gen_random_uuid(), u[1], now(), now()),
      (gen_random_uuid(), u[2], now() - interval '5 minutes', now() - interval '5 minutes'),
      (gen_random_uuid(), u[3], now() - interval '1 day', now() - interval '20 minutes'),
      (gen_random_uuid(), u[3], now() - interval '2 days', now() - interval '10 minutes'),
      (gen_random_uuid(), u[4], now() - interval '1 day', now() - interval '3 hours'),
      (gen_random_uuid(), u[6], now() - interval '10 minutes', now() - interval '10 minutes');
    if has_na then
      execute format('update auth.sessions set not_after = now() - interval ''1 minute'' where user_id = %L', u[6]);
    end if;

    r := pg_temp.as_user(u[1], $q$ select public.hdm_admin_live()::text $q$);
    ja := substr(r, 4)::jsonb;

    r := pg_temp.as_user(null, $q$ select public.hdm_admin_live()::text $q$);
    t_area := t_area || text 'הרשאות'; t_name := t_name || text 'אורח לא מחובר נחסם';
    t_exp := t_exp || text 'נחסם'; t_got := t_got || (case when r like 'err:%' then 'נחסם' else left(r, 40) end)::text;
    r := pg_temp.as_user(u[2], $q$ select public.hdm_admin_live()::text $q$);
    t_area := t_area || text 'הרשאות'; t_name := t_name || text 'משתמש רגיל מחובר נחסם בשרת';
    t_exp := t_exp || text 'err:HDM_NOT_ADMIN'; t_got := t_got || left(r, 40);

    t_area := t_area || text 'פרטיות'; t_name := t_name || text 'התוצאה: מספרים בלבד (בלי מזהים, אימיילים או שמות)';
    t_exp := t_exp || text 'ok';
    t_got := t_got || (case when ja::text ~ ('@|בדיקה|' || pid[2]) then 'יש פרטים' else 'ok' end)::text;

    t_area := t_area || text 'ספירה'; t_name := t_name || text 'רשומים +6';
    t_exp := t_exp || text '6'; t_got := t_got || (((ja->>'registered')::int - (jb->>'registered')::int)::text)::text;
    t_area := t_area || text 'ספירה';
    t_name := t_name || (case when has_na then 'מחוברים כרגע +3 (מנהלת, נכנס עכשיו, רענון לפני 20 דק'' — שתי סשנים נספרות פעם אחת; לא: לפני 3 שעות, התנתק, פג תוקף)'
                              else 'מחוברים כרגע +4 (במסד המקומי אין not_after)' end)::text;
    t_exp := t_exp || (case when has_na then '3' else '4' end)::text;
    t_got := t_got || (((ja->>'onlineNow')::int - (jb->>'onlineNow')::int)::text)::text;
    t_area := t_area || text 'ספירה'; t_name := t_name || text 'רשומים זהה ללוח הקיים (hdm_admin_dashboard)';
    t_exp := t_exp || text 'ok';
    r := pg_temp.as_user(u[1], $q$ select public.hdm_admin_dashboard()::text $q$);
    t_got := t_got || (case when (substr(r, 4)::jsonb #>> '{users,total}') = (ja->>'registered') then 'ok' else r end)::text;

    delete from public.hdm_admins where auth_user_id = u[1];
    r := pg_temp.as_user(u[1], $q$ select public.hdm_admin_live()::text $q$);
    t_area := t_area || text 'הרשאות'; t_name := t_name || text 'אחרי הסרת ההרשאה: נחסם מיד';
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

select * from pg_temp.hdm_live_tests();
