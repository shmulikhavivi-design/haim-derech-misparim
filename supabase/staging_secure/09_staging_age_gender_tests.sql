-- =====================================================================
-- חיים דרך מספרים — Staging בלבד: בדיקות לפילוח הגיל והמין בלוח הניהול (08)
-- הכול רץ בתוך טרנזקציה ומתבטל בסוף — לא נשמר כלום.
-- בודק: הרשאות (אורח / משתמש רגיל / מנהל), שאין בתוצאה פרטים אישיים, גבולות גיל ביום ההולדת,
-- ושכל תא (טווח × מין) זז בדיוק בכמות שנוצרה בבדיקה (השוואה "לפני / אחרי").
-- =====================================================================
do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא הורץ.';
  end if;
  if not exists (select 1 from public.hdm_staging_marker where version = 'staging_admin_age_gender_v1') then
    raise exception 'עצירה: צריך להתקין קודם את 08_staging_admin_age_gender.sql. שום דבר לא הורץ.';
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

create or replace function pg_temp.hdm_age_tests()
returns table(n int, "תחום" text, "בדיקה" text, "צפוי" text, "התקבל" text, "עבר" text)
language plpgsql as $$
declare
  t_area text[] := '{}'; t_name text[] := '{}'; t_exp text[] := '{}'; t_got text[] := '{}';
  pfx text := 'g' || substr(md5(random()::text), 1, 5);
  today date := (now() at time zone 'Asia/Jerusalem')::date;
  -- (מפתח, מין, תאריך לידה). המנהלת עצמה נספרת גם היא (אישה, 40).
  ppl text[][] := array[
    ['adm', 'אישה', to_char(today - interval '40 years' - interval '10 days', 'YYYY-MM-DD')],   -- 35-44 נשים
    ['m20', 'גבר',  to_char(today - interval '20 years' - interval '10 days', 'YYYY-MM-DD')],   -- 18-24 גברים
    ['f20', 'אישה', to_char(today - interval '20 years' - interval '10 days', 'YYYY-MM-DD')],   -- 18-24 נשים
    ['m25', 'גבר',  to_char(today - interval '25 years' + interval '1 day',   'YYYY-MM-DD')],   -- בן 25 מחר → עדיין 18-24
    ['f25', 'אישה', to_char(today - interval '25 years',                      'YYYY-MM-DD')],   -- בת 25 היום → 25-34
    ['m47', 'זכר',  to_char(today - interval '47 years' - interval '10 days', 'YYYY-MM-DD')],   -- 45-54 גברים (כתיב "זכר")
    ['o60', 'אחר',  to_char(today - interval '60 years' - interval '10 days', 'YYYY-MM-DD')],   -- 55-64 אחר
    ['f65', 'אישה', to_char(today - interval '65 years',                      'YYYY-MM-DD')],   -- בת 65 היום → 65+
    ['m70', 'גבר',  to_char(today - interval '70 years' - interval '10 days', 'YYYY-MM-DD')]];  -- 65+ גברים
  uids uuid[] := '{}'; pids text[] := '{}';
  i int; jb jsonb; ja jsonb; r text; cell text; uA uuid; uU uuid;
  -- הפרש לפני/אחרי לתא אחד
  exp_cells text := '18-24:2/1/0/3 25-34:0/1/0/1 35-44:0/1/0/1 45-54:1/0/0/1 55-64:0/0/1/1 65+:1/1/0/2';
begin
  begin
    for i in 1 .. array_length(ppl, 1) loop
      uids := uids || gen_random_uuid();
      insert into auth.users (id, email, aud, role, created_at)
      values (uids[i], pfx || '_' || ppl[i][1] || '@example.invalid', 'authenticated', 'authenticated', now());
    end loop;
    uA := uids[1]; uU := uids[2];
    insert into public.hdm_admins (auth_user_id, note) values (uA, 'בדיקה');

    r := pg_temp.as_user(uA, $q$ select public.hdm_admin_age_gender()::text $q$);
    if r not like 'ok:%' then raise exception 'הפילוח לא נטען למנהל: %', r; end if;
    jb := substr(r, 4)::jsonb;

    for i in 1 .. array_length(ppl, 1) loop
      pids := pids || substr(pg_temp.as_user(uids[i], $q$ select public.hdm_claim_profile() $q$), 4);
      r := pg_temp.as_user(uids[i], format($q$ insert into public.docs values ('profiles', %L,
             jsonb_build_object('currentName', %L, 'gender', %L, 'lookingFor', 'כולם', 'birthdate', %L,
                                'birthFirstName', 'שם', 'birthLastName', 'משפחה')) returning id $q$,
             pids[i], 'בדיקה ' || ppl[i][1], ppl[i][2], ppl[i][3]));
      if r not like 'ok:%' then raise exception 'יצירת פרופיל % נכשלה: %', ppl[i][1], r; end if;
    end loop;

    r := pg_temp.as_user(uA, $q$ select public.hdm_admin_age_gender()::text $q$);
    ja := substr(r, 4)::jsonb;

    -- ================= הרשאות =================
    r := pg_temp.as_user(null, $q$ select public.hdm_admin_age_gender()::text $q$);
    t_area := t_area || text 'הרשאות'; t_name := t_name || text 'אורח לא מחובר לא מקבל את הפילוח';
    t_exp := t_exp || text 'נחסם'; t_got := t_got || (case when r like 'err:%' then 'נחסם' else left(r, 40) end)::text;

    r := pg_temp.as_user(uU, $q$ select public.hdm_admin_age_gender()::text $q$);
    t_area := t_area || text 'הרשאות'; t_name := t_name || text 'משתמש רגיל מחובר נחסם בשרת';
    t_exp := t_exp || text 'err:HDM_NOT_ADMIN'; t_got := t_got || left(r, 40);

    -- ================= פרטיות =================
    t_area := t_area || text 'פרטיות'; t_name := t_name || text 'אין בתוצאה אימיילים, שמות, מזהי פרופיל או תאריכי לידה';
    t_exp := t_exp || text 'אין';
    t_got := t_got || (case when ja::text ~ ('@|בדיקה|birthdate|currentName|' || pids[2] || '|' || pids[3] || '|' || ppl[2][3] || '|' || ppl[5][3]) then 'יש' else 'אין' end)::text;
    t_area := t_area || text 'פרטיות'; t_name := t_name || text 'התוצאה מכילה רק מספרים ושמות טווחים';
    t_exp := t_exp || text 'ok';
    t_got := t_got || (case when (select bool_and(jsonb_typeof(v) = 'number' or k = 'key')
                                    from jsonb_array_elements(ja->'buckets') e, jsonb_each(e) x(k, v)) then 'ok' else 'יש שדה לא מספרי' end)::text;

    -- ================= מבנה =================
    t_area := t_area || text 'מבנה'; t_name := t_name || text 'שישה טווחים בסדר הנכון';
    t_exp := t_exp || text '18-24,25-34,35-44,45-54,55-64,65+';
    t_got := t_got || ((select string_agg(e->>'key', ',' order by o) from jsonb_array_elements(ja->'buckets') with ordinality q(e, o)))::text;
    t_area := t_area || text 'מבנה'; t_name := t_name || text 'בכל טווח: גברים + נשים + אחר = סך הכול';
    t_exp := t_exp || text 'ok';
    t_got := t_got || (case when (select bool_and((e->>'male')::int + (e->>'female')::int + (e->>'other')::int = (e->>'total')::int)
                                    from jsonb_array_elements(ja->'buckets') e) then 'ok' else 'סכום שגוי' end)::text;
    t_area := t_area || text 'מבנה'; t_name := t_name || text 'סכום הטווחים + מתחת ל-18 + בלי תאריך לידה = כל הפרופילים';
    t_exp := t_exp || text 'ok';
    t_got := t_got || (case when (select sum((e->>'total')::int) from jsonb_array_elements(ja->'buckets') e)
                                 + (ja#>>'{outside,under18}')::int + (ja#>>'{outside,noBirthdate}')::int
                                 = (ja->>'totalProfiles')::int then 'ok' else 'סכום שגוי' end)::text;
    t_area := t_area || text 'מבנה'; t_name := t_name || text 'התאמה ללוח הקיים: סך הפרופילים זהה ל-hdm_admin_dashboard';
    t_exp := t_exp || text 'ok';
    r := pg_temp.as_user(uA, $q$ select public.hdm_admin_dashboard()::text $q$);
    t_got := t_got || (case when (substr(r, 4)::jsonb #>> '{users,total}') = (ja->>'totalProfiles') then 'ok' else r end)::text;

    -- ================= ספירות (הפרש לפני/אחרי) — גברים/נשים/אחר/סך =================
    foreach cell in array string_to_array(exp_cells, ' ') loop
      t_area := t_area || text 'ספירה';
      t_name := t_name || ('טווח ' || split_part(cell, ':', 1) || ' — גברים/נשים/אחר/סך')::text;
      t_exp := t_exp || split_part(cell, ':', 2);
      t_got := t_got || ((select string_agg(((a.e->>f)::int - (b.e->>f)::int)::text, '/' order by fo)
                            from jsonb_array_elements(ja->'buckets') a(e), jsonb_array_elements(jb->'buckets') b(e),
                                 unnest(array['male','female','other','total']) with ordinality ff(f, fo)
                           where a.e->>'key' = split_part(cell, ':', 1) and b.e->>'key' = split_part(cell, ':', 1)))::text;
    end loop;
    t_area := t_area || text 'ספירה'; t_name := t_name || text 'סך הפרופילים +9';
    t_exp := t_exp || text '9'; t_got := t_got || (((ja->>'totalProfiles')::int - (jb->>'totalProfiles')::int)::text)::text;

    -- הסרת הרשאת מנהל חוסמת מיד
    delete from public.hdm_admins where auth_user_id = uA;
    r := pg_temp.as_user(uA, $q$ select public.hdm_admin_age_gender()::text $q$);
    t_area := t_area || text 'הרשאות'; t_name := t_name || text 'אחרי הסרת ההרשאה: המנהלת לשעבר נחסמת מיד';
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

select * from pg_temp.hdm_age_tests();
