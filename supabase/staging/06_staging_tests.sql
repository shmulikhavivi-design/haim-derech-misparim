-- =====================================================================
-- סביבת בדיקות (Staging) — שלב 6: בדיקות אוטומטיות
-- ⚠️ רק בפרויקט Haim Derech Misparim Staging. בפרויקט האמיתי הקובץ נעצר בשורה הראשונה.
-- הקובץ נוצר אוטומטית מ-scripts/build_staging_sql.py — לא לערוך ידנית.
-- בדיקות המנויים מ-PR #9 ובדיקות הרשאה. הכול מתבטל בסוף — שום דבר לא נשמר.
-- =====================================================================

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט ה-Staging. שום דבר לא הורץ ולא שונה. בדקו בראש המסך שנבחר הפרויקט Haim Derech Misparim Staging.';
  end if;
end $$;

-- =====================================================================
-- חיים דרך מספרים — בדיקה אוטומטית של אכיפת המנויים בשרת
-- להרצה אחרי שלושת שלבי ההתקנה. SQL Editor ← New query ← להדביק ← Run
--
-- הבדיקה יוצרת פרופילי בדיקה זמניים, מנסה פעולות בכל מסלול, ובסוף מבטלת את הכול:
-- שום פרופיל, מנוי, התאמה או שיחה לא נשארים במסד, וגם הפונקציה עצמה זמנית (pg_temp).
-- התוצאה: טבלה עם שורה לכל בדיקה — בעמודה "עבר" צריך להופיע ✅ בכולן.
-- =====================================================================

create or replace function pg_temp.hdm_run_subscription_tests()
returns table(n int, "בדיקה" text, "צפוי" text, "התקבל" text, "עבר" text)
language plpgsql
as $$
declare
  t_name text[] := '{}';
  t_exp  text[] := '{}';
  t_got  text[] := '{}';
  pfx    text := 'hdmtest' || substr(md5(random()::text), 1, 6) || '_';
  f text; b text; p text; v text;
  x text;
  i int;
  res text;
  ent jsonb;
begin
  f := pfx || 'free'; b := pfx || 'basic'; p := pfx || 'plus'; v := pfx || 'vip';

  begin
    -- פרופילי בדיקה זמניים (עם תאריך לידה, בגלל הגבלת הגיל)
    insert into public.docs (collection, id, data, updated_at)
    select 'profiles', u, jsonb_build_object('currentName', u, 'birthdate', '1990-01-01', 'likes', '[]'::jsonb), now()
      from unnest(array[f, b, p, v, pfx||'x1', pfx||'x2', pfx||'x3', pfx||'x4', pfx||'x5', pfx||'x6', pfx||'x7', pfx||'old']) u;

    perform public.hdm_admin_set_plan(b, 'basic', 'test');
    perform public.hdm_admin_set_plan(p, 'plus',  'test');
    perform public.hdm_admin_set_plan(v, 'vip',   'test');
    foreach x in array array[pfx||'x1', pfx||'x2', pfx||'x3', pfx||'x4', pfx||'x5', pfx||'x6', pfx||'x7'] loop
      perform public.hdm_admin_set_plan(x, 'plus', 'test');
    end loop;

    -- ---- חינם ----
    begin
      insert into public.docs (collection, id, data) values ('interests', f||'__'||p, jsonb_build_object('from', f, 'to', p, 'ts', 1));
      res := 'OK';
    exception when others then res := sqlerrm; end;
    t_name := t_name || text 'חינם: שליחת 🎯'; t_exp := t_exp || 'HDM_PLAN_REQUIRED'::text; t_got := t_got || res;

    begin
      update public.docs set data = jsonb_set(data, '{likes}', jsonb_build_array(p)) where collection = 'profiles' and id = f;
      res := 'OK';
    exception when others then res := sqlerrm; end;
    t_name := t_name || text 'חינם: 🎯 דרך רשימת likes'; t_exp := t_exp || 'HDM_PLAN_REQUIRED'::text; t_got := t_got || res;

    begin
      update public.docs set data = jsonb_set(data, '{currentName}', '"שם חדש"') where collection = 'profiles' and id = f;
      res := 'OK';
    exception when others then res := sqlerrm; end;
    t_name := t_name || text 'חינם: עדכון פרופיל רגיל ממשיך לעבוד'; t_exp := t_exp || 'OK'::text; t_got := t_got || res;

    begin
      insert into public.docs (collection, id, data) values ('matches', (select string_agg(z, '__' order by z) from unnest(array[f, p]) z), jsonb_build_object('users', jsonb_build_array(f, p)));
      res := 'OK';
    exception when others then res := sqlerrm; end;
    t_name := t_name || text 'חינם: פתיחת שיחה'; t_exp := t_exp || 'HDM_PLAN_REQUIRED'::text; t_got := t_got || res;

    ent := public.hdm_my_entitlements(f);
    t_name := t_name || text 'חינם: המסלול שהאפליקציה מקבלת'; t_exp := t_exp || 'free'::text; t_got := t_got || (ent->>'plan');

    -- ---- בסיסי ----
    begin
      insert into public.docs (collection, id, data) values ('interests', b||'__'||pfx||'x1', jsonb_build_object('from', b, 'to', pfx||'x1', 'ts', 1));
      res := 'OK';
    exception when others then res := sqlerrm; end;
    t_name := t_name || text 'בסיסי: שליחת 🎯'; t_exp := t_exp || 'OK'::text; t_got := t_got || res;

    for i in 1..5 loop
      x := pfx || 'x' || i;
      begin
        insert into public.docs (collection, id, data) values ('matches', (select string_agg(z, '__' order by z) from unnest(array[b, x]) z), '{}'::jsonb);
        insert into public.docs (collection, id, data) values ('chats', (select string_agg(z, '__' order by z) from unnest(array[b, x]) z), jsonb_build_object('messages', '[]'::jsonb, 'createdBy', b));
        res := 'OK';
      exception when others then res := sqlerrm; end;
      t_name := t_name || ('בסיסי: שיחה חדשה מספר ' || i); t_exp := t_exp || 'OK'::text; t_got := t_got || res;
    end loop;

    ent := public.hdm_my_entitlements(b);
    t_name := t_name || text 'בסיסי: שיחות שנותרו אחרי 5'; t_exp := t_exp || '0'::text; t_got := t_got || (ent->>'chatsLeft');

    begin
      insert into public.docs (collection, id, data) values ('matches', (select string_agg(z, '__' order by z) from unnest(array[b, pfx||'x6']) z), '{}'::jsonb);
      res := 'OK';
    exception when others then res := sqlerrm; end;
    t_name := t_name || text 'בסיסי: שיחה חדשה שישית'; t_exp := t_exp || 'HDM_CHAT_LIMIT'::text; t_got := t_got || res;

    x := (select string_agg(z, '__' order by z) from unnest(array[b, pfx||'x1']) z);
    begin
      update public.docs set data = jsonb_set(data, '{messages}', (data->'messages') || jsonb_build_array(jsonb_build_object('senderId', b, 'text', 'שלום', 'ts', 1)))
       where collection = 'chats' and id = x;
      update public.docs set data = jsonb_set(data, '{messages}', (data->'messages') || jsonb_build_array(jsonb_build_object('senderId', b, 'text', 'עוד הודעה', 'ts', 2)))
       where collection = 'chats' and id = x;
      res := 'OK';
    exception when others then res := sqlerrm; end;
    t_name := t_name || text 'בסיסי: הודעות בשיחה קיימת אחרי ניצול המכסה'; t_exp := t_exp || 'OK'::text; t_got := t_got || res;

    -- שיחה שהייתה קיימת לפני ההתקנה לא נספרת ולא נחסמת
    insert into public.hdm_chat_openings (profile_id, pair_id, period_start)
    select u, (select string_agg(z, '__' order by z) from unnest(array[b, pfx||'old']) z), null
      from unnest(array[b, pfx||'old']) u;
    begin
      insert into public.docs (collection, id, data) values ('chats', (select string_agg(z, '__' order by z) from unnest(array[b, pfx||'old']) z),
        jsonb_build_object('messages', jsonb_build_array(jsonb_build_object('senderId', b, 'text', 'היי', 'ts', 3))));
      res := 'OK';
    exception when others then res := sqlerrm; end;
    t_name := t_name || text 'בסיסי: שיחה שהייתה קיימת לפני ההתקנה'; t_exp := t_exp || 'OK'::text; t_got := t_got || res;

    -- מנוי שפג: ההודעות שמורות, אבל אי אפשר לשלוח חדשות
    update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = b;
    begin
      update public.docs set data = jsonb_set(data, '{messages}', (data->'messages') || jsonb_build_array(jsonb_build_object('senderId', b, 'text', 'אחרי שפג', 'ts', 4)))
       where collection = 'chats' and id = x;
      res := 'OK';
    exception when others then res := sqlerrm; end;
    t_name := t_name || text 'מנוי שפג: שליחת הודעה'; t_exp := t_exp || 'HDM_PLAN_INACTIVE'::text; t_got := t_got || res;

    begin
      update public.docs set data = data || '{"updatedAt": 5}'::jsonb where collection = 'chats' and id = x;
      res := 'OK';
    exception when others then res := sqlerrm; end;
    t_name := t_name || text 'מנוי שפג: ההודעות הקיימות נשמרות ללא שינוי'; t_exp := t_exp || 'OK'::text; t_got := t_got || res;

    -- שדרוג לפלוס פותח שיחות ללא הגבלה
    perform public.hdm_admin_set_plan(b, 'plus', 'test');
    begin
      insert into public.docs (collection, id, data) values ('matches', (select string_agg(z, '__' order by z) from unnest(array[b, pfx||'x6']) z), '{}'::jsonb);
      insert into public.docs (collection, id, data) values ('matches', (select string_agg(z, '__' order by z) from unnest(array[b, pfx||'x7']) z), '{}'::jsonb);
      res := 'OK';
    exception when others then res := sqlerrm; end;
    t_name := t_name || text 'שדרוג מבסיסי לפלוס: שיחה שישית ושביעית'; t_exp := t_exp || 'OK'::text; t_got := t_got || res;

    -- ---- פלוס ----
    begin
      for i in 1..7 loop
        insert into public.docs (collection, id, data) values ('matches', (select string_agg(z, '__' order by z) from unnest(array[p, pfx||'x'||i]) z), '{}'::jsonb);
      end loop;
      res := 'OK';
    exception when others then res := sqlerrm; end;
    t_name := t_name || text 'פלוס: 7 שיחות חדשות בחודש'; t_exp := t_exp || 'OK'::text; t_got := t_got || res;

    ent := public.hdm_my_entitlements(p);
    t_name := t_name || text 'פלוס: ללא מכסת שיחות'; t_exp := t_exp || 'ללא הגבלה'::text;
    t_got := t_got || (case when ent->'chatsLimit' = 'null'::jsonb then 'ללא הגבלה' else ent->>'chatsLimit' end);

    -- ---- VIP ----
    begin
      insert into public.docs (collection, id, data) values ('interests', v||'__'||pfx||'x1', jsonb_build_object('from', v, 'to', pfx||'x1', 'ts', 1));
      insert into public.docs (collection, id, data) values ('matches', (select string_agg(z, '__' order by z) from unnest(array[v, pfx||'x1']) z), '{}'::jsonb);
      res := 'OK';
    exception when others then res := sqlerrm; end;
    t_name := t_name || text 'VIP: 🎯 ושיחה'; t_exp := t_exp || 'OK'::text; t_got := t_got || res;

    ent := public.hdm_my_entitlements(v);
    t_name := t_name || text 'VIP: המסלול שהאפליקציה מקבלת'; t_exp := t_exp || 'vip'::text; t_got := t_got || (ent->>'plan');

    -- ביטול כל מה שנוצר בבדיקה
    raise exception 'HDM_TEST_ROLLBACK';
  exception when others then
    if sqlerrm <> 'HDM_TEST_ROLLBACK' then
      t_name := t_name || text 'שגיאה כללית בבדיקה'; t_exp := t_exp || '—'::text; t_got := t_got || sqlerrm;
    end if;
  end;

  return query
    select s.i::int, t_name[s.i], t_exp[s.i], t_got[s.i],
           case when t_got[s.i] = t_exp[s.i] then '✅' else '❌' end
      from generate_subscripts(t_name, 1) s(i)
     order by s.i;
end;
$$;

-- מקור לקובץ 06 (לא להריץ ישירות). בדיקות הרשאה מנקודת המבט של האפליקציה (תפקיד anon).
-- הכול רץ בתוך בלוק שמתבטל בסופו: שום שינוי לא נשמר.
create or replace function pg_temp.hdm_security_baseline()
returns table(n int, "בדיקה" text, "צפוי" text, "התקבל" text, "עבר" text)
language plpgsql
as $$
declare
  t_name text[] := '{}'; t_exp text[] := '{}'; t_got text[] := '{}'; t_known boolean[] := '{}';
  res text;
  victim text;
begin
  select id into victim from public.docs where collection = 'profiles' and id like 'stg\_%' order by id limit 1;
  begin
    execute 'set local role anon';

    begin perform count(*) from public.docs where collection = 'profiles' and data ? 'birthdate'; res := 'פתוח';
    exception when others then res := 'נחסם'; end;
    t_name := t_name || text 'קריאת תאריכי לידה של אחרים'; t_exp := t_exp || text 'נחסם'; t_got := t_got || res; t_known := t_known || true;

    begin perform count(*) from public.docs where collection like 'data/users/%'; res := 'פתוח';
    exception when others then res := 'נחסם'; end;
    t_name := t_name || text 'קריאת רשומות חשבון (סיסמאות מגובבות)'; t_exp := t_exp || text 'נחסם'; t_got := t_got || res; t_known := t_known || true;

    begin perform count(*) from public.docs where collection = 'chats'; res := 'פתוח';
    exception when others then res := 'נחסם'; end;
    t_name := t_name || text 'קריאת שיחות של אחרים'; t_exp := t_exp || text 'נחסם'; t_got := t_got || res; t_known := t_known || true;

    begin update public.docs set data = data || '{"bio":"x"}'::jsonb where collection = 'profiles' and id = victim; res := 'פתוח';
    exception when others then res := 'נחסם'; end;
    t_name := t_name || text 'עריכת פרופיל של משתמש אחר'; t_exp := t_exp || text 'נחסם'; t_got := t_got || res; t_known := t_known || true;

    begin perform count(*) from public.hdm_subscriptions; res := 'פתוח';
    exception when others then res := 'נחסם'; end;
    t_name := t_name || text 'קריאת טבלת המנויים'; t_exp := t_exp || text 'נחסם'; t_got := t_got || res; t_known := t_known || false;

    begin insert into public.hdm_subscriptions (profile_id, plan) values (victim, 'vip'); res := 'פתוח';
    exception when others then res := 'נחסם'; end;
    t_name := t_name || text 'שינוי מסלול ישירות בטבלה'; t_exp := t_exp || text 'נחסם'; t_got := t_got || res; t_known := t_known || false;

    begin perform public.hdm_admin_set_plan(victim, 'vip'); res := 'פתוח';
    exception when others then res := 'נחסם'; end;
    t_name := t_name || text 'שינוי מסלול דרך פונקציית המנהל'; t_exp := t_exp || text 'נחסם'; t_got := t_got || res; t_known := t_known || false;

    begin perform count(*) from public.hdm_chat_openings; res := 'פתוח';
    exception when others then res := 'נחסם'; end;
    t_name := t_name || text 'קריאת יומן השיחות (מכסה)'; t_exp := t_exp || text 'נחסם'; t_got := t_got || res; t_known := t_known || false;

    begin insert into public.hdm_chat_openings (profile_id, pair_id) values (victim, 'x__y'); res := 'פתוח';
    exception when others then res := 'נחסם'; end;
    t_name := t_name || text 'זיוף יומן השיחות'; t_exp := t_exp || text 'נחסם'; t_got := t_got || res; t_known := t_known || false;

    begin perform public.hdm_my_entitlements(victim); res := 'פתוח';
    exception when others then res := 'נחסם'; end;
    t_name := t_name || text 'קריאת המסלול דרך hdm_my_entitlements (לפי התכנון בשלב הזה)'; t_exp := t_exp || text 'פתוח'; t_got := t_got || res; t_known := t_known || false;

    raise exception 'HDM_TEST_ROLLBACK';
  exception when others then
    if sqlerrm <> 'HDM_TEST_ROLLBACK' then
      t_name := t_name || text 'שגיאה כללית בבדיקה'; t_exp := t_exp || text '—'; t_got := t_got || sqlerrm; t_known := t_known || false;
    end if;
  end;

  return query
    select s.i::int, t_name[s.i], t_exp[s.i], t_got[s.i],
           case when t_got[s.i] = t_exp[s.i] then '✅'
                when t_known[s.i] then '⚠️ פער ידוע — ייסגר בשלבי האבטחה'
                else '❌' end
      from generate_subscripts(t_name, 1) s(i)
     order by s.i;
end;
$$;

select 'מנויים' as "קבוצה", t.* from pg_temp.hdm_run_subscription_tests() t
union all
select 'הרשאות', s.* from pg_temp.hdm_security_baseline() s
order by 1 desc, 2;
