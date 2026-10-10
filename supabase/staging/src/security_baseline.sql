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
