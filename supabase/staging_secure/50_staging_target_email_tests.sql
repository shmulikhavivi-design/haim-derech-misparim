-- =====================================================================
-- חיים דרך מספרים — בדיקות: התראת מייל על חץ 🎯 (אחרי 49_staging_target_email.sql).
-- משתמשים ופרופילים מומצאים בלבד (@example.invalid). שום מייל לא נשלח — בודקים רק את התור בשרת.
-- הכול מתבטל בסוף — שום דבר לא נשמר.
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.hdm_staging_marker') is null then raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא הורץ.'; end if;
  if to_regclass('public.hdm_target_email_outbox') is null then raise exception 'עצירה: קודם 49_staging_target_email.sql.'; end if;
end $$;
create or replace function pg_temp.as_user(p_uid uuid, p_sql text) returns text language plpgsql as $$
declare r text; begin begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true); perform set_config('role', 'authenticated', true);
  execute p_sql into r; execute 'reset role'; return 'ok:' || coalesce(r, '');
exception when others then execute 'reset role'; return 'err:' || sqlerrm; end; end $$;
create or replace function pg_temp.as_anon(p_sql text) returns text language plpgsql as $$
declare r text; begin begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true); perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('role', 'anon', true);
  execute p_sql into r; execute 'reset role'; return 'ok:' || coalesce(r, '');
exception when others then execute 'reset role'; return 'err:' || sqlerrm; end; end $$;
create temp table t_res (n serial, area text, name text, exp text, got text, ok boolean);
create or replace function pg_temp.chk(a text, nm text, e text, g text) returns void language sql as $$
  insert into t_res (area, name, exp, got, ok) values (a, nm, e, g, coalesce(g, '∅') like e) $$;
create or replace function pg_temp.q(p_uid uuid) returns text language sql as $$
  select count(*)::text from public.hdm_target_email_outbox where user_id = p_uid $$;
grant execute on function pg_temp.chk(text, text, text, text) to public;

do $$
declare
  pfx text := 'te' || substr(md5(random()::text), 1, 6);
  k text[] := array['f','b','b2','b3','b4','p','v','r1','r2','r3','r4','r5'];
  uid uuid[] := '{}'; pid text[] := '{}';
  uF uuid; uB uuid; uB2 uuid; uB3 uuid; uB4 uuid; uP uuid; uV uuid; uR1 uuid; uR2 uuid; uR3 uuid; uR4 uuid; uR5 uuid;
  F text; B text; B2 text; B3 text; B4 text; P text; V text; R1 text; R2 text; R3 text; R4 text; R5 text;
  r text; j jsonb; i int; n0 int; c record; ids bigint[];
  req text := public.hdm_required_terms_version();
begin
  for i in 1 .. array_length(k, 1) loop uid := uid || gen_random_uuid(); end loop;
  insert into auth.users (id, email, aud, role, created_at, email_confirmed_at, raw_user_meta_data)
  select u, pfx || '_' || kk || '@example.invalid', 'authenticated', 'authenticated', now(),
         case when kk = 'r4' then null else now() end, '{}'::jsonb      -- r4: אימייל לא מאומת
    from unnest(uid, k) as x(u, kk);
  insert into public.hdm_consents (user_id, version, source) select u, req, 'signup' from unnest(uid) u;
  for i in 1 .. array_length(k, 1) loop
    pid := pid || substr(pg_temp.as_user(uid[i], 'select public.hdm_claim_profile()'), 4);
    perform pg_temp.as_user(uid[i], format($q$ insert into public.docs values ('profiles', %L,
      jsonb_build_object('currentName', %L, 'birthdate', %L, 'birthFirstName', 'שם', 'birthLastName', 'בדיקה')) returning id $q$,
      pid[i], 'שולח-סודי-' || k[i], (date '1984-01-15' + (i * 97))::text));
  end loop;
  uF := uid[1]; uB := uid[2]; uB2 := uid[3]; uB3 := uid[4]; uB4 := uid[5]; uP := uid[6]; uV := uid[7];
  uR1 := uid[8]; uR2 := uid[9]; uR3 := uid[10]; uR4 := uid[11]; uR5 := uid[12];
  F := pid[1]; B := pid[2]; B2 := pid[3]; B3 := pid[4]; B4 := pid[5]; P := pid[6]; V := pid[7];
  R1 := pid[8]; R2 := pid[9]; R3 := pid[10]; R4 := pid[11]; R5 := pid[12];
  perform public.hdm_admin_set_plan(B, 'basic'); perform public.hdm_admin_set_plan(B2, 'basic');
  perform public.hdm_admin_set_plan(B3, 'basic'); perform public.hdm_admin_set_plan(B4, 'basic');
  perform public.hdm_admin_set_plan(P, 'plus');  perform public.hdm_admin_set_plan(V, 'vip');
  perform public.hdm_admin_set_plan(R1, 'basic'); perform public.hdm_admin_set_plan(R2, 'plus');
  perform pg_temp.chk('הכנה', '12 פרופילי בדיקה', '12', (select count(*)::text from public.docs where collection = 'profiles' and id = any(pid)));

  -- ---------- 1. חץ חדש → מייל אחד, רק אחרי שהחץ נשמר ----------
  perform pg_temp.chk('שליחה', 'תור ריק לפני', '0', pg_temp.q(uR1));
  perform pg_temp.chk('שליחה', 'בסיסי שולח 🎯 (פעולה רגילה)', 'ok:%"targeted": true%', pg_temp.as_user(uB, format('select public.hdm_send_target(%L)::text', R1)));
  perform pg_temp.chk('שליחה', 'החץ נשמר בשרת', '1', (select count(*)::text from public.docs where collection = 'interests' and id = B || '__' || R1));
  perform pg_temp.chk('שליחה', 'נוצר מייל אחד למקבל', '1', pg_temp.q(uR1));
  perform pg_temp.chk('שליחה', 'לא נוצר מייל לשולח', '0', pg_temp.q(uB));
  -- חץ שנכשל (השמירה בוטלה) → אין מייל
  begin
    perform pg_temp.as_user(uB, format('select public.hdm_send_target(%L)::text', R3));
    raise exception 'rollback_test';
  exception when raise_exception then null; end;
  perform pg_temp.chk('שליחה', 'שמירת חץ שבוטלה — אין חץ', '0', (select count(*)::text from public.docs where collection = 'interests' and id = B || '__' || R3));
  perform pg_temp.chk('שליחה', 'שמירת חץ שבוטלה — אין מייל', '0', pg_temp.q(uR3));
  -- פעולה שנכשלה בשרת (חינם לא יכול לשלוח) → אין מייל
  perform pg_temp.chk('שליחה', 'חינם לא יכול לשלוח 🎯 (ללא שינוי)', 'err:HDM_PLAN_REQUIRED%', pg_temp.as_user(uF, format('select public.hdm_send_target(%L)::text', R3)));
  perform pg_temp.chk('שליחה', 'חץ שנדחה — אין מייל', '0', pg_temp.q(uR3));

  -- ---------- 2–3. כפילויות והצפה ----------
  perform pg_temp.chk('כפילויות', 'אותו חץ שוב', 'ok:%', pg_temp.as_user(uB, format('select public.hdm_send_target(%L)::text', R1)));
  perform pg_temp.chk('כפילויות', 'עדיין מייל אחד', '1', pg_temp.q(uR1));
  for i in 1 .. 5 loop
    perform pg_temp.as_user(uB, format('select public.hdm_remove_target(%L)::text', R1));
    perform pg_temp.as_user(uB, format('select public.hdm_send_target(%L)::text', R1));
  end loop;
  perform pg_temp.chk('כפילויות', 'ביטול ושליחה ×5 — החץ קיים', '1', (select count(*)::text from public.docs where collection = 'interests' and id = B || '__' || R1));
  perform pg_temp.chk('כפילויות', 'ביטול ושליחה ×5 — עדיין מייל אחד', '1', pg_temp.q(uR1));
  -- אחרי 30 יום — מותר שוב (מדמים)
  update public.hdm_target_email_log set last_queued_at = now() - interval '31 days' where sender_profile = B and recipient_profile = R1;
  update public.hdm_target_email_outbox set created_at = now() - interval '31 days' where user_id = uR1;
  perform pg_temp.as_user(uB, format('select public.hdm_remove_target(%L)::text', R1));
  perform pg_temp.as_user(uB, format('select public.hdm_send_target(%L)::text', R1));
  perform pg_temp.chk('כפילויות', 'אותו זוג אחרי 30 יום — מייל חדש', '2', pg_temp.q(uR1));
  -- מקבל: עד 3 ב-24 שעות משולחים שונים
  perform pg_temp.as_user(uB,  format('select public.hdm_send_target(%L)::text', R5));
  perform pg_temp.as_user(uB2, format('select public.hdm_send_target(%L)::text', R5));
  perform pg_temp.as_user(uB3, format('select public.hdm_send_target(%L)::text', R5));
  perform pg_temp.as_user(uB4, format('select public.hdm_send_target(%L)::text', R5));
  perform pg_temp.chk('הצפה', '4 שולחים שונים — 4 חצים נשמרו', '4', (select count(*)::text from public.docs where collection = 'interests' and data->>'to' = R5));
  perform pg_temp.chk('הצפה', '4 שולחים שונים — עד 3 מיילים ב-24 שעות', '3', pg_temp.q(uR5));

  -- ---------- 4, 8. פרטיות והרשאות ----------
  perform pg_temp.chk('פרטיות', 'בתור אין עמודה עם פרטי שולח', 'attempts,claimed_at,created_at,id,last_error,sent_at,skipped,user_id',
    (select string_agg(column_name, ',' order by column_name) from information_schema.columns where table_schema = 'public' and table_name = 'hdm_target_email_outbox'));
  select * into c from public.hdm_target_email_text();
  perform pg_temp.chk('פרטיות', 'נושא המייל', '❤️ מישהו מתעניין בך!', c.subject);
  perform pg_temp.chk('פרטיות', 'הנוסח כולל את הקישור לאפליקציה', 'כן', case when c.body_text like '%https://haimderechmisparim.com%' then 'כן' else 'לא' end);
  perform pg_temp.chk('פרטיות', 'הנוסח כולל דרך לבטל התראות', 'כן', case when c.body_text like '%הגדרות ← התראות מייל%' then 'כן' else 'לא' end);
  perform pg_temp.chk('פרטיות', 'בנוסח אין שם/מזהה של שולח', 'ok', case when c.body_text like '%שולח-סודי%' or position(B in c.body_text) > 0 or position(B in c.subject) > 0 then 'דליפה' else 'ok' end);
  perform pg_temp.chk('הרשאות', 'משתמש לא קורא את התור', 'err:%permission denied%', pg_temp.as_user(uR1, 'select count(*)::text from public.hdm_target_email_outbox'));
  perform pg_temp.chk('הרשאות', 'משתמש לא קורא את יומן הזוגות', 'err:%permission denied%', pg_temp.as_user(uR1, 'select count(*)::text from public.hdm_target_email_log'));
  perform pg_temp.chk('הרשאות', 'משתמש לא קורא העדפות של אחרים', 'err:%permission denied%', pg_temp.as_user(uR1, 'select count(*)::text from public.hdm_target_email_prefs'));
  perform pg_temp.chk('הרשאות', 'משתמש לא שולף מיילים מהתור', 'err:%permission denied%', pg_temp.as_user(uR1, 'select count(*)::text from public.hdm_target_email_claim(5)'));
  perform pg_temp.chk('הרשאות', 'משתמש לא מסמן "נשלח"', 'err:%permission denied%', pg_temp.as_user(uR1, 'select public.hdm_target_email_done(1, true, null)::text'));
  perform pg_temp.chk('הרשאות', 'אורח לא משנה העדפות', 'err:%permission denied%', pg_temp.as_anon('select public.hdm_set_target_emails(false)::text'));
  perform pg_temp.chk('הרשאות', 'משתמש לא מכניס לתור ישירות', 'err:%permission denied%', pg_temp.as_user(uR1, format('insert into public.hdm_target_email_outbox (user_id) values (%L) returning id::text', uR2)));
  -- מי סימן אותי — לפי המסלול, ללא שינוי
  perform pg_temp.chk('מסלולים', 'בסיסי (מקבל) לא רואה מי סימן', 'err:HDM_PLAN_REQUIRED%', pg_temp.as_user(uR1, 'select public.hdm_who_targeted_me()::text'));
  perform pg_temp.as_user(uP, format('select public.hdm_send_target(%L)::text', R2));
  perform pg_temp.chk('מסלולים', 'פלוס (מקבל) קיבל מייל', '1', pg_temp.q(uR2));
  perform pg_temp.chk('מסלולים', 'פלוס (מקבל) רואה מי סימן — באפליקציה בלבד', ('ok:%' || P || '%'), pg_temp.as_user(uR2, 'select public.hdm_who_targeted_me()::text'));
  perform pg_temp.as_user(uV, format('select public.hdm_send_target(%L)::text', R3));
  perform pg_temp.chk('מסלולים', 'VIP שולח — המקבל (חינם) מקבל מייל', '1', pg_temp.q(uR3));
  perform pg_temp.chk('מסלולים', 'חינם (מקבל) לא רואה מי סימן', 'err:HDM_PLAN_REQUIRED%', pg_temp.as_user(uR3, 'select public.hdm_who_targeted_me()::text'));
  -- אימייל לא מאומת → אין מייל
  perform pg_temp.as_user(uB, format('select public.hdm_send_target(%L)::text', R4));
  perform pg_temp.chk('פרטיות', 'אימייל לא מאומת — החץ נשמר', '1', (select count(*)::text from public.docs where collection = 'interests' and id = B || '__' || R4));
  perform pg_temp.chk('פרטיות', 'אימייל לא מאומת — אין מייל', '0', pg_temp.q(uR4));
  -- חסימה → אין חץ ואין מייל
  perform pg_temp.as_user(uR2, format($q$ insert into public.docs values ('blocks', %L, '{}') returning id $q$, R2 || '__' || B2));
  perform pg_temp.chk('פרטיות', 'חסום לא יכול לסמן (ללא שינוי)', 'err:HDM_NOT_AVAILABLE%', pg_temp.as_user(uB2, format('select public.hdm_send_target(%L)::text', R2)));
  perform pg_temp.chk('פרטיות', 'חסימה — אין מייל נוסף', '1', pg_temp.q(uR2));

  -- ---------- 5. ביטול התראות ----------
  perform pg_temp.chk('ביטול התראות', 'ברירת מחדל: פעיל', 'ok:{"targetEmails": true}', pg_temp.as_user(uR3, 'select public.hdm_my_email_prefs()::text'));
  perform pg_temp.chk('ביטול התראות', 'כיבוי', 'ok:{"targetEmails": false}', pg_temp.as_user(uR3, 'select public.hdm_set_target_emails(false)::text'));
  perform pg_temp.chk('ביטול התראות', 'נשמר', 'ok:{"targetEmails": false}', pg_temp.as_user(uR3, 'select public.hdm_my_email_prefs()::text'));
  perform pg_temp.as_user(uP, format('select public.hdm_send_target(%L)::text', R3));
  perform pg_temp.chk('ביטול התראות', 'אחרי כיבוי — החץ נשמר', '1', (select count(*)::text from public.docs where collection = 'interests' and id = P || '__' || R3));
  perform pg_temp.chk('ביטול התראות', 'אחרי כיבוי — אין מייל חדש', '1', pg_temp.q(uR3));
  perform pg_temp.chk('ביטול התראות', 'משתמש אחר לא הושפע', 'ok:{"targetEmails": true}', pg_temp.as_user(uR2, 'select public.hdm_my_email_prefs()::text'));
  perform pg_temp.chk('ביטול התראות', 'הדלקה מחדש', 'ok:{"targetEmails": true}', pg_temp.as_user(uR3, 'select public.hdm_set_target_emails(true)::text'));

  -- ---------- 7. תקלה בהתראה לא מבטלת את החץ ----------
  alter table public.hdm_target_email_outbox add constraint t_force_fail check (user_id is null) not valid;
  perform pg_temp.chk('כשל', 'תקלה בתור — 🎯 עדיין מצליח', 'ok:%"targeted": true%', pg_temp.as_user(uV, format('select public.hdm_send_target(%L)::text', R4)));
  perform pg_temp.chk('כשל', 'תקלה בתור — החץ נשמר', '1', (select count(*)::text from public.docs where collection = 'interests' and id = V || '__' || R4));
  alter table public.hdm_target_email_outbox drop constraint t_force_fail;
  -- הדדי: הצ'אט נפתח כרגיל, והמייל לא מפריע
  perform pg_temp.chk('הדדי', 'R1 מחזיר 🎯 ל-B — צ''אט נפתח (ללא שינוי)', 'ok:%"chat": "opened"%"mutual": true%', pg_temp.as_user(uR1, format('select public.hdm_send_target(%L)::text', B)));
  perform pg_temp.chk('הדדי', 'B קיבל מייל אחד', '1', pg_temp.q(uB));

  -- ---------- שליחה מהתור: פעם אחת בלבד, כשל חוזר לתור ----------
  update public.hdm_target_email_outbox set created_at = now() where user_id = uR1;   -- (הוזז אחורה בבדיקת 30 הימים)
  n0 := (select count(*) from public.hdm_target_email_outbox where sent_at is null and skipped is null);
  -- מי שכיבה אחרי שנכנס לתור — לא יישלח
  perform pg_temp.as_user(uR5, 'select public.hdm_set_target_emails(false)::text');
  select array_agg(x.id) into ids from public.hdm_target_email_claim(50) x;
  perform pg_temp.chk('שליחה מהתור', 'נשלפו כל הממתינים חוץ ממי שכיבה (3)', (n0 - 3)::text, coalesce(array_length(ids, 1), 0)::text);
  perform pg_temp.chk('שליחה מהתור', 'מי שכיבה אחרי ההכנסה — סומן כדילוג', '3', (select count(*)::text from public.hdm_target_email_outbox where user_id = uR5 and skipped is not null));
  perform pg_temp.chk('שליחה מהתור', 'שליפה שנייה מיד — כלום (אין כפילות)', '0', (select count(*)::text from public.hdm_target_email_claim(50)));
  perform public.hdm_target_email_done(ids[1], true, null);
  perform public.hdm_target_email_done(ids[2], false, 'brevo 500');
  perform pg_temp.chk('שליחה מהתור', 'נשלח — מסומן', '1', (select count(*)::text from public.hdm_target_email_outbox where id = ids[1] and sent_at is not null));
  perform public.hdm_target_email_done(ids[1], true, null);
  perform pg_temp.chk('שליחה מהתור', 'סימון כפול לא משנה (ניסיון 1)', '1', (select attempts::text from public.hdm_target_email_outbox where id = ids[1]));
  perform pg_temp.chk('שליחה מהתור', 'כשל — לא נשלף מיד שוב (מניעת כפילות בהרצה מקבילה)', '0', (select count(*)::text from public.hdm_target_email_claim(50)));
  update public.hdm_target_email_outbox set claimed_at = now() - interval '11 minutes' where id = ids[2];
  r := (select string_agg(x.id::text, ',') from public.hdm_target_email_claim(50) x);
  perform pg_temp.chk('שליחה מהתור', 'כשל — חוזר לתור אחרי 10 דקות ונשלף שוב', ids[2]::text, r);
  perform pg_temp.chk('שליחה מהתור', 'נשלח לא נשלף שוב', 'ok', case when position(ids[1]::text in coalesce(r, '')) = 0 then 'ok' else 'נשלף שוב' end);
  perform pg_temp.chk('שליחה מהתור', 'כתובת היעד = המקבל', pfx || '_b@example.invalid',
    (select u.email from public.hdm_target_email_outbox o join auth.users u on u.id = o.user_id where o.user_id = uB limit 1));

  -- ---------- מחיקת חשבון מוחקת גם את נתוני ההתראות ----------
  perform pg_temp.chk('מחיקה', 'מחיקת החשבון של R2', 'ok:%', pg_temp.as_user(uR2, 'select public.hdm_delete_my_data()::text'));
  perform pg_temp.chk('מחיקה', 'אחרי מחיקה: אין מייל ממתין ל-R2, אין יומן ואין העדפות', '0',
    ((select count(*) from public.hdm_target_email_claim(50) x where x.to_email like pfx || '_r2@%')
     + (select count(*) from public.hdm_target_email_outbox where user_id = uR2 and sent_at is null and skipped is null)
     + (select count(*) from public.hdm_target_email_log where recipient_profile = R2 or sender_profile = R2)
     + (select count(*) from public.hdm_target_email_prefs where user_id = uR2))::text);

  -- ---------- לא השתנו: התאמה הדדית / צ'אט / מי סימן / ביטול חץ ----------
  perform pg_temp.chk('ללא שינוי', 'טבלת המסלולים: 4 מסלולים', '4', (select count(*)::text from public.hdm_plans));
  perform pg_temp.chk('ללא שינוי', 'תור מיילי הביטול לא נגע', '0', (select count(*)::text from public.hdm_email_outbox where user_id = any(uid)));
end $$;
select n, area as "תחום", name as "בדיקה", exp as "צפוי", got as "התקבל", case when ok then '✅' else '❌' end as "עבר" from t_res order by n;
select 'סיכום: עברו ' || count(*) filter (where ok) || ' מתוך ' || count(*) as "סיכום" from t_res;
rollback;
