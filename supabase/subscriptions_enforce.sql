-- =====================================================================
-- חיים דרך מספרים — מערכת מנויים, שלב 3 מתוך 3: אכיפה בשרת
-- להרצה רק אחרי subscriptions.sql ו-subscriptions_test_accounts.sql.
--
-- מרגע ההרצה, כל כתיבה לטבלת docs נבדקת במסד עצמו — גם אם מישהו עוקף את האפליקציה
-- ופונה ישירות ל-API:
--   * 🎯 חדש (interests, או הוספה לרשימת likes בפרופיל) — נדחה אם המסלול של השולח הוא free.
--   * שיחה חדשה (matches / chats) — נדחית אם אחד הצדדים במסלול free, או שהוא במסלול basic
--     וכבר פתח 5 שיחות חדשות בחודש החיוב הנוכחי. כל צד במסלול basic מנצל שיחה אחת.
--   * הודעה חדשה בשיחה — נדחית אם לשולח אין מנוי פעיל (free).
--
-- שיחות והתאמות שקיימות לפני ההרצה נרשמות כ"קיימות" ולא נספרות במכסה.
--
-- מה זה לא עושה:
--   * לא מוחק ולא משנה שום נתון קיים. הודעות קיימות לא נוגעות.
--   * לא נוגע בחסימות, דיווחים, סימוני קריאה, פרופילים (מלבד בדיקת likes חדשים) או בהתחברות.
--
-- מגבלה ידועה (תיסגר בשלב אבטחת docs): הבדיקה מתבססת על מזהה הפרופיל שרשום בנתונים.
-- מי שמתחזה לפרופיל אחר דרך ה-API עדיין לא נחסם כאן — זה הפער הקיים בטבלת docs.
-- =====================================================================

-- ---------------------------------------------------------------------
-- שיחות והתאמות שכבר קיימות: נרשמות פעם אחת, בלי מכסה (period_start = NULL).
-- אפשר להריץ שוב בלי נזק.
-- ---------------------------------------------------------------------
insert into public.hdm_chat_openings (profile_id, pair_id, period_start)
select p.profile_id, d.id, null
  from public.docs d
  cross join lateral unnest(array[split_part(d.id, '__', 1), split_part(d.id, '__', 2)]) as p(profile_id)
 where d.collection in ('matches', 'chats')
   and d.id like '%\_\_%'
   and split_part(d.id, '__', 1) <> ''
   and split_part(d.id, '__', 2) <> ''
   and split_part(d.id, '__', 3) = ''
on conflict (profile_id, pair_id) do nothing;

-- ---------------------------------------------------------------------
-- פתיחת שיחה חדשה בין שני משתמשים: בדיקת מסלול ומכסה לכל צד, ורישום ביומן.
-- ---------------------------------------------------------------------
create or replace function public.hdm_open_pair(p_pair text, p_users text[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  u      text;
  v_plan text;
  v_lim  int;
  v_ps   timestamptz;
begin
  foreach u in array p_users loop
    continue when u is null or u = '';
    -- נעילה קצרה לכל משתמש, כדי ששתי שיחות במקביל לא יעברו יחד את המכסה
    perform pg_advisory_xact_lock(hashtext('hdm_open_pair:' || u));
    -- שיחה שכבר נרשמה למשתמש הזה (כולל שיחות שהיו קיימות) — לא נספרת שוב
    continue when exists (select 1 from public.hdm_chat_openings o where o.profile_id = u and o.pair_id = p_pair);

    v_plan := public.hdm_plan_of(u);
    if v_plan = 'free' then
      raise exception 'HDM_PLAN_REQUIRED' using errcode = 'P0001',
        hint = 'פתיחת שיחות זמינה מהמסלול הבסיסי ומעלה.';
    end if;

    v_lim := public.hdm_chat_limit(v_plan);
    if v_lim is not null and public.hdm_chats_used(u) >= v_lim then
      raise exception 'HDM_CHAT_LIMIT' using errcode = 'P0001',
        hint = 'נוצלו כל השיחות החדשות לחודש החיוב הנוכחי.';
    end if;

    select public.hdm_period_start(s.period_anchor) into v_ps
      from public.hdm_subscriptions s where s.profile_id = u;
    insert into public.hdm_chat_openings (profile_id, pair_id, period_start)
    values (u, p_pair, coalesce(v_ps, now()))
    on conflict (profile_id, pair_id) do nothing;
  end loop;
end;
$$;
revoke all on function public.hdm_open_pair(text, text[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- הטריגר על טבלת docs
-- ---------------------------------------------------------------------
create or replace function public.hdm_docs_subscription_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_data jsonb;
  v_sender text;
  v_users  text[];
begin
  -- הנתונים הקודמים של אותו מסמך (גם ב-upsert: טריגר ה-INSERT רץ לפני שמתברר שהשורה קיימת)
  if tg_op = 'UPDATE' then
    old_data := old.data;
  else
    select t.data into old_data from public.docs t
     where t.collection = new.collection and t.id = new.id;
  end if;

  -- ---- 🎯 חדש ----
  if new.collection = 'interests' then
    if old_data is null then
      v_sender := coalesce(nullif(new.data->>'from', ''), split_part(new.id, '__', 1));
      if public.hdm_plan_of(v_sender) = 'free' then
        raise exception 'HDM_PLAN_REQUIRED' using errcode = 'P0001',
          hint = 'שליחת 🎯 זמינה מהמסלול הבסיסי ומעלה.';
      end if;
    end if;
    return new;
  end if;

  -- ---- 🎯 דרך רשימת likes בפרופיל: רק הוספה של שמות חדשים נבדקת ----
  if new.collection = 'profiles' then
    if jsonb_typeof(new.data->'likes') = 'array'
       and exists (
         select 1 from jsonb_array_elements(new.data->'likes') n(v)
          where not (case when jsonb_typeof(old_data->'likes') = 'array'
                          then (old_data->'likes') @> jsonb_build_array(n.v) else false end)
       )
       and public.hdm_plan_of(new.id) = 'free' then
      raise exception 'HDM_PLAN_REQUIRED' using errcode = 'P0001',
        hint = 'שליחת 🎯 זמינה מהמסלול הבסיסי ומעלה.';
    end if;
    return new;
  end if;

  -- ---- שיחה חדשה / התאמה חדשה ----
  if new.collection in ('matches', 'chats') and old_data is null then
    if new.id like '%\_\_%' and split_part(new.id, '__', 3) = '' then
      v_users := array[split_part(new.id, '__', 1), split_part(new.id, '__', 2)];
      perform public.hdm_open_pair(new.id, v_users);
    end if;
  end if;

  -- ---- הודעות חדשות: כל שולח חייב מנוי פעיל ----
  if new.collection = 'chats' and jsonb_typeof(new.data->'messages') = 'array' then
    for v_sender in
      select distinct coalesce(n.v->>'senderId', '')
        from jsonb_array_elements(new.data->'messages') n(v)
       where not (case when jsonb_typeof(old_data->'messages') = 'array'
                       then exists (select 1 from jsonb_array_elements(old_data->'messages') o(v) where o.v = n.v)
                       else false end)
    loop
      if v_sender = '' or public.hdm_plan_of(v_sender) = 'free' then
        raise exception 'HDM_PLAN_INACTIVE' using errcode = 'P0001',
          hint = 'שליחת הודעות זמינה למנויים פעילים. השיחה שמורה.';
      end if;
    end loop;
  end if;

  return new;
end;
$$;
revoke all on function public.hdm_docs_subscription_guard() from public, anon, authenticated;

drop trigger if exists hdm_docs_subscription_guard on public.docs;
create trigger hdm_docs_subscription_guard
  before insert or update on public.docs
  for each row
  when (new.collection in ('interests', 'profiles', 'matches', 'chats'))
  execute function public.hdm_docs_subscription_guard();
