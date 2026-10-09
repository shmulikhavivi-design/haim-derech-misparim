-- =====================================================================
-- חיים דרך מספרים — „המידע שלי”: עיון במידע ובקשת עותק
-- להרצה פעם אחת ב-Supabase: SQL Editor ← New query ← להדביק ← Run
--
-- מה זה יוצר:
--   * hdm_profile_owners   — קישור מאובטח בין משתמש Supabase Auth לפרופיל שלו.
--                            רק השרת כותב אליה; האפליקציה לא יכולה לקרוא או לשנות אותה ישירות.
--   * hdm_data_requests    — בקשות „עותק מהמידע שלי”. רק מנהל (בלוח הבקרה של Supabase) רואה ומטפל.
--   * hdm_claim_profile()  — מקשר את המשתמש המחובר לפרופיל שלו (פעם אחת, לפי הכללים למטה).
--   * hdm_my_data()        — מחזיר למשתמש המחובר את המידע שלו בלבד.
--   * hdm_request_data_copy() — פותח בקשת עותק.
--   * hdm_admin_export()   — למנהל בלבד (SQL Editor): עותק מלא של המידע של משתמש אחד.
--
-- מה זה לא עושה: לא מוחק ולא משנה שום נתון קיים בטבלת docs.
-- =====================================================================

create table if not exists public.hdm_profile_owners (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  profile_id text not null unique,
  linked_by  text not null default 'self',     -- 'self' או 'admin'
  linked_at  timestamptz not null default now()
);

create table if not exists public.hdm_data_requests (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  profile_id  text not null,
  email       text,
  status      text not null default 'new' check (status in ('new', 'in_progress', 'done', 'rejected')),
  admin_note  text,                              -- הערה פנימית למנהל; לא מוצגת למשתמש
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- הטבלאות סגורות לגמרי לאפליקציה: אין policies, ולכן anon ו-authenticated לא יכולים לגשת ישירות.
alter table public.hdm_profile_owners enable row level security;
alter table public.hdm_data_requests  enable row level security;
revoke all on public.hdm_profile_owners from anon, authenticated;
revoke all on public.hdm_data_requests  from anon, authenticated;

create or replace function public.hdm_touch_request() returns trigger
language plpgsql set search_path = public as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists hdm_touch_request on public.hdm_data_requests;
create trigger hdm_touch_request before update on public.hdm_data_requests
  for each row execute function public.hdm_touch_request();

-- ---------------------------------------------------------------------
-- קישור המשתמש המחובר לפרופיל שלו
-- כללים: אימייל מאומת ב-Supabase Auth; רשומת חשבון באפליקציה עם אותו אימייל שמצביעה על הפרופיל;
-- הפרופיל לא מקושר למשתמש אחר; והפרופיל נוצר ב-7 הימים האחרונים (משתמש חדש).
-- פרופילים ותיקים (כמו שמוליק ונועה) מקשר המנהל — ראו בסוף הקובץ.
-- ---------------------------------------------------------------------
create or replace function public.hdm_claim_profile(p_profile_id text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := auth.uid();
  v_email   text;
  v_conf    timestamptz;
  v_bound   text;
  v_created text;
begin
  if v_uid is null then raise exception 'HDM_NOT_AUTHENTICATED' using errcode = 'P0001'; end if;

  select profile_id into v_bound from hdm_profile_owners where user_id = v_uid;
  if v_bound is not null then
    if v_bound <> p_profile_id then raise exception 'HDM_LINK_MISMATCH' using errcode = 'P0001'; end if;
    return v_bound;
  end if;

  if p_profile_id is null or p_profile_id = '' then raise exception 'HDM_NOT_LINKED' using errcode = 'P0001'; end if;
  if exists (select 1 from hdm_profile_owners where profile_id = p_profile_id) then
    raise exception 'HDM_LINK_TAKEN' using errcode = 'P0001';
  end if;

  select email, email_confirmed_at into v_email, v_conf from auth.users where id = v_uid;
  if v_email is null or v_conf is null then raise exception 'HDM_EMAIL_NOT_CONFIRMED' using errcode = 'P0001'; end if;

  if not exists (select 1 from docs
                  where collection like 'data/users/%'
                    and lower(data->>'email') = lower(v_email)
                    and data->>'profileId' = p_profile_id) then
    raise exception 'HDM_NOT_LINKED' using errcode = 'P0001';
  end if;

  select data->>'createdAt' into v_created from docs where collection = 'profiles' and id = p_profile_id;
  if v_created is null or v_created !~ '^\d{10,16}$'
     or v_created::bigint < (extract(epoch from now() - interval '7 days') * 1000)::bigint then
    raise exception 'HDM_NOT_LINKED' using errcode = 'P0001';   -- פרופיל ותיק: קישור על ידי המנהל
  end if;

  insert into hdm_profile_owners(user_id, profile_id, linked_by) values (v_uid, p_profile_id, 'self');
  return p_profile_id;
end $$;

-- פרופיל המשתמש המחובר בלבד (לפי הקישור המאובטח)
create or replace function public.hdm_my_profile_id() returns text
language sql stable security definer set search_path = public as $$
  select profile_id from hdm_profile_owners where user_id = auth.uid()
$$;

-- ---------------------------------------------------------------------
-- המידע שלי — רק של המשתמש המחובר. לא מוחזרים פרטים של משתמשים אחרים
-- (רק מספרים מסכמים), ולא נתונים פנימיים כמו סיסמה מגובבת או מלח.
-- ---------------------------------------------------------------------
create or replace function public.hdm_my_data()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_uid   uuid := auth.uid();
  v_pid   text;
  v_email text;
  prof    jsonb;
  acct    jsonb;
begin
  if v_uid is null then raise exception 'HDM_NOT_AUTHENTICATED' using errcode = 'P0001'; end if;
  v_pid := hdm_my_profile_id();
  if v_pid is null then raise exception 'HDM_NOT_LINKED' using errcode = 'P0001'; end if;

  select email into v_email from auth.users where id = v_uid;
  select data into prof from docs where collection = 'profiles' and id = v_pid;
  select data into acct from docs
   where collection like 'data/users/%' and lower(data->>'email') = lower(v_email) and data->>'profileId' = v_pid
   order by updated_at desc nulls last limit 1;

  return jsonb_build_object(
    'profileId', v_pid,
    'profile',   coalesce(prof, '{}'::jsonb) - 'likes',      -- likes מכיל מזהים של משתמשים אחרים
    'account',   jsonb_build_object('email', v_email, 'createdAt', acct->'createdAt'),
    'activity',  jsonb_build_object(
      'interestsSent', (select count(*) from docs where collection = 'interests' and data->>'from' = v_pid),
      'matches',       (select count(*) from docs where collection = 'matches' and coalesce(data->'users', '[]'::jsonb) ? v_pid),
      'conversations', (select count(*) from docs where collection = 'chats' and v_pid = any(string_to_array(id, '__'))),
      'messagesSent',  (select count(*) from docs d,
                               jsonb_array_elements(case when jsonb_typeof(d.data->'messages') = 'array' then d.data->'messages' else '[]'::jsonb end) m
                         where d.collection = 'chats' and v_pid = any(string_to_array(d.id, '__')) and m->>'senderId' = v_pid),
      'blocksMade',    (select count(*) from docs where collection = 'blocks' and data->>'by' = v_pid),
      'reportsSent',   (select count(*) from docs where collection = 'reports' and data->>'by' = v_pid)
    ),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status,
                                                              'createdAt', r.created_at, 'updatedAt', r.updated_at)
                                           order by r.created_at desc), '[]'::jsonb)
                   from hdm_data_requests r where r.user_id = v_uid)
  );
end $$;

-- ---------------------------------------------------------------------
-- בקשת עותק. בקשה פתוחה קיימת מוחזרת במקום ליצור כפילות; עד 3 בקשות ב-30 יום.
-- ---------------------------------------------------------------------
create or replace function public.hdm_request_data_copy()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid   uuid := auth.uid();
  v_pid   text;
  v_email text;
  r       hdm_data_requests%rowtype;
begin
  if v_uid is null then raise exception 'HDM_NOT_AUTHENTICATED' using errcode = 'P0001'; end if;
  v_pid := hdm_my_profile_id();
  if v_pid is null then raise exception 'HDM_NOT_LINKED' using errcode = 'P0001'; end if;

  select * into r from hdm_data_requests
   where user_id = v_uid and status in ('new', 'in_progress') order by created_at desc limit 1;
  if found then
    return jsonb_build_object('id', r.id, 'status', r.status, 'createdAt', r.created_at, 'existing', true);
  end if;
  if (select count(*) from hdm_data_requests where user_id = v_uid and created_at > now() - interval '30 days') >= 3 then
    raise exception 'HDM_TOO_MANY_REQUESTS' using errcode = 'P0001';
  end if;

  select email into v_email from auth.users where id = v_uid;
  insert into hdm_data_requests(user_id, profile_id, email) values (v_uid, v_pid, v_email) returning * into r;
  return jsonb_build_object('id', r.id, 'status', r.status, 'createdAt', r.created_at, 'existing', false);
end $$;

-- ---------------------------------------------------------------------
-- למנהל בלבד: עותק מלא של המידע של פרופיל אחד (להרצה ב-SQL Editor).
-- כולל רק הודעות שהמשתמש עצמו כתב; פרטי הצד השני בשיחה לא נכללים.
-- ---------------------------------------------------------------------
create or replace function public.hdm_admin_export(p_profile_id text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'exportedAt', now(),
    'profile', (select data - 'likes' from docs where collection = 'profiles' and id = p_profile_id),
    'account', (select jsonb_build_object('email', data->'email', 'createdAt', data->'createdAt')
                  from docs where collection like 'data/users/%' and data->>'profileId' = p_profile_id
                 order by updated_at desc nulls last limit 1),
    'interestsSent', (select count(*) from docs where collection = 'interests' and data->>'from' = p_profile_id),
    'matches', (select count(*) from docs where collection = 'matches' and coalesce(data->'users', '[]'::jsonb) ? p_profile_id),
    'myMessages', (select coalesce(jsonb_agg(jsonb_build_object('conversation', d.id_rank, 'text', m->'text', 'ts', m->'ts')
                                             order by d.id_rank, (m->>'ts')), '[]'::jsonb)
                     from (select dense_rank() over (order by id) as id_rank, data from docs
                            where collection = 'chats' and p_profile_id = any(string_to_array(id, '__'))) d,
                          jsonb_array_elements(case when jsonb_typeof(d.data->'messages') = 'array' then d.data->'messages' else '[]'::jsonb end) m
                    where m->>'senderId' = p_profile_id),
    'blocksMade', (select count(*) from docs where collection = 'blocks' and data->>'by' = p_profile_id),
    'reportsSent', (select coalesce(jsonb_agg(jsonb_build_object('reason', data->'reason', 'details', data->'details', 'ts', data->'ts')), '[]'::jsonb)
                      from docs where collection = 'reports' and data->>'by' = p_profile_id)
  )
$$;

-- הרשאות: רק משתמש מחובר (authenticated) יכול להפעיל את פונקציות המשתמש; פונקציית המנהל — אף אחד מהאפליקציה.
revoke all on function public.hdm_claim_profile(text)    from public, anon;
revoke all on function public.hdm_my_profile_id()        from public, anon, authenticated;
revoke all on function public.hdm_my_data()              from public, anon;
revoke all on function public.hdm_request_data_copy()    from public, anon;
revoke all on function public.hdm_admin_export(text)     from public, anon, authenticated;
grant execute on function public.hdm_claim_profile(text) to authenticated;
grant execute on function public.hdm_my_data()           to authenticated;
grant execute on function public.hdm_request_data_copy() to authenticated;

-- =====================================================================
-- למנהל: קישור משתמשים ותיקים (למשל שמוליק ונועה) — פעם אחת
-- 1) הצגה בלבד: מי רשום ב-Supabase Auth ולאיזה פרופיל הוא שייך באפליקציה
-- select u.id as user_id, u.email, u.email_confirmed_at, d.data->>'profileId' as profile_id,
--        p.data->>'currentName' as name
--   from auth.users u
--   join docs d on d.collection like 'data/users/%' and lower(d.data->>'email') = lower(u.email)
--   left join docs p on p.collection = 'profiles' and p.id = d.data->>'profileId';
--
-- 2) אחרי שבדקת שהשורה נכונה — קישור (להחליף את הערכים):
-- insert into public.hdm_profile_owners(user_id, profile_id, linked_by)
-- values ('<user_id>', '<profile_id>', 'admin');
--
-- טיפול בבקשות עותק:
-- select * from public.hdm_data_requests order by created_at desc;
-- select public.hdm_admin_export('<profile_id>');        -- העותק לשליחה למשתמש
-- update public.hdm_data_requests set status = 'done', admin_note = 'נשלח באימייל' where id = <id>;
--
-- ביטול:
-- drop function if exists public.hdm_admin_export(text), public.hdm_request_data_copy(),
--   public.hdm_my_data(), public.hdm_my_profile_id(), public.hdm_claim_profile(text), public.hdm_touch_request();
-- drop table if exists public.hdm_data_requests, public.hdm_profile_owners;
-- =====================================================================
