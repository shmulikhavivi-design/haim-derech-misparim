-- =====================================================================
-- חיים דרך מספרים — „המידע שלי”: עיון במידע ובקשת עותק
-- להרצה פעם אחת ב-Supabase: SQL Editor ← New query ← להדביק ← Run
--
-- עיקרון האבטחה: טבלת docs פתוחה לקריאה ולכתיבה עם המפתח הציבורי, ולכן שום דבר שנמצא בה
-- לא משמש להוכחת בעלות על פרופיל. הבעלות נקבעת רק לפי:
--   * hdm_profile_registry — נרשם פעם אחת, לפני שהפרופיל החדש נשמר (מזהה אקראי שאיש עוד לא מכיר),
--                            עם האימייל של הנרשם. אי אפשר לשנות או לדרוס רשומה קיימת.
--   * אימייל מאומת ב-Supabase Auth (נשלח קישור אישור והמשתמש אישר אותו).
--   * hdm_profile_owners   — הקישור הסופי משתמש ↔ פרופיל. רק השרת כותב אליה.
-- פרופילים שנוצרו לפני ההתקנה (כמו שמוליק ונועה) מקשר המנהל ידנית — ראו בסוף הקובץ.
--
-- כל הפונקציות SECURITY DEFINER מוגדרות עם search_path ריק ושמות מלאים (schema.name),
-- כדי שאי אפשר יהיה להחליף טבלה או פונקציה בעותק מזויף.
--
-- מה זה לא עושה: לא מוחק ולא משנה שום נתון קיים בטבלת docs, ולא נוגע בטבלאות קיימות.
-- =====================================================================

create table if not exists public.hdm_profile_registry (
  profile_id    text primary key,
  owner_email   text not null,
  registered_at timestamptz not null default now()
);

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
  email       text not null,                    -- האימייל המאומת של המבקש — לשם נשלח העותק
  status      text not null default 'new' check (status in ('new', 'in_progress', 'done', 'rejected')),
  admin_note  text,                              -- הערה פנימית למנהל; לא מוצגת למשתמש
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- הטבלאות סגורות לגמרי לאפליקציה: RLS פעיל בלי policies, וכל ההרשאות הוסרו
-- (Supabase נותן אוטומטית הרשאות לטבלאות ולרצפים חדשים — מבטלים אותן במפורש).
alter table public.hdm_profile_registry enable row level security;
alter table public.hdm_profile_owners   enable row level security;
alter table public.hdm_data_requests    enable row level security;
revoke all on public.hdm_profile_registry from public, anon, authenticated;
revoke all on public.hdm_profile_owners   from public, anon, authenticated;
revoke all on public.hdm_data_requests    from public, anon, authenticated;
revoke all on sequence public.hdm_data_requests_id_seq from public, anon, authenticated;

create or replace function public.hdm_touch_request() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists hdm_touch_request on public.hdm_data_requests;
create trigger hdm_touch_request before update on public.hdm_data_requests
  for each row execute function public.hdm_touch_request();

-- ---------------------------------------------------------------------
-- רישום פרופיל חדש — האפליקציה קוראת לזה בהרשמה, רגע לפני שהפרופיל נשמר.
-- נכשל בשקט מבחינת ההרשמה: אם זה לא עובד, ההרשמה ממשיכה כרגיל (רק הקישור האוטומטי לא יתאפשר).
-- ---------------------------------------------------------------------
create or replace function public.hdm_register_new_profile(p_profile_id text, p_email text)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if p_profile_id is null or p_profile_id !~ '^reg_[a-z0-9]{8,40}$' then return false; end if;
  if length(v_email) > 254 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' then return false; end if;
  -- רק מזהה שעוד לא קיים: אי אפשר לרשום פרופיל שכבר נשמר או שכבר נרשם
  if exists (select 1 from public.docs where collection = 'profiles' and id = p_profile_id) then return false; end if;
  insert into public.hdm_profile_registry(profile_id, owner_email) values (p_profile_id, v_email)
  on conflict (profile_id) do nothing;
  return found;
end $$;

-- ---------------------------------------------------------------------
-- קישור המשתמש המחובר לפרופיל שלו (פעם אחת).
-- תנאים: אימייל שאושר בפועל דרך קישור אישור; הפרופיל נרשם מראש עם אותו אימייל;
-- הפרופיל עוד לא מקושר למשתמש אחר.
-- ---------------------------------------------------------------------
create or replace function public.hdm_claim_profile(p_profile_id text)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_email text;
  v_conf  timestamptz;
  v_sent  timestamptz;
  v_bound text;
begin
  if v_uid is null then raise exception 'HDM_NOT_AUTHENTICATED' using errcode = 'P0001'; end if;

  select o.profile_id into v_bound from public.hdm_profile_owners o where o.user_id = v_uid;
  if v_bound is not null then
    if v_bound is distinct from p_profile_id then raise exception 'HDM_LINK_MISMATCH' using errcode = 'P0001'; end if;
    return v_bound;
  end if;

  if p_profile_id is null or p_profile_id = '' then raise exception 'HDM_NOT_LINKED' using errcode = 'P0001'; end if;

  select lower(u.email), u.email_confirmed_at, u.confirmation_sent_at
    into v_email, v_conf, v_sent
    from auth.users u where u.id = v_uid;
  -- confirmation_sent_at ריק = האימייל אושר אוטומטית בלי שהמשתמש הוכיח שהוא בעליו; לא מספיק לקישור עצמי
  if v_email is null or v_conf is null or v_sent is null then
    raise exception 'HDM_EMAIL_NOT_CONFIRMED' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.hdm_profile_registry r
                  where r.profile_id = p_profile_id and r.owner_email = v_email) then
    raise exception 'HDM_NOT_LINKED' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.hdm_profile_owners o where o.profile_id = p_profile_id) then
    raise exception 'HDM_LINK_TAKEN' using errcode = 'P0001';
  end if;

  insert into public.hdm_profile_owners(user_id, profile_id, linked_by) values (v_uid, p_profile_id, 'self');
  return p_profile_id;
end $$;

-- ---------------------------------------------------------------------
-- המידע שלי — רק של המשתמש המחובר ורק לפי הקישור המאובטח. אין פרמטרים: אי אפשר לבקש פרופיל אחר.
-- לא מוחזרים פרטים של משתמשים אחרים (רק מספרים מסכמים), ולא סיסמה מגובבת, מלח או רשימת likes.
-- ---------------------------------------------------------------------
create or replace function public.hdm_my_data()
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_pid   text;
  v_email text;
  prof    jsonb;
begin
  if v_uid is null then raise exception 'HDM_NOT_AUTHENTICATED' using errcode = 'P0001'; end if;
  select o.profile_id into v_pid from public.hdm_profile_owners o where o.user_id = v_uid;
  if v_pid is null then raise exception 'HDM_NOT_LINKED' using errcode = 'P0001'; end if;

  select u.email into v_email from auth.users u where u.id = v_uid;
  select d.data into prof from public.docs d where d.collection = 'profiles' and d.id = v_pid;

  return jsonb_build_object(
    'profileId', v_pid,
    'profile',   case when jsonb_typeof(prof) = 'object' then prof - 'likes' else '{}'::jsonb end,
    'account',   jsonb_build_object('email', v_email,
                   'createdAt', (select (extract(epoch from u.created_at) * 1000)::bigint from auth.users u where u.id = v_uid)),
    'activity',  jsonb_build_object(
      'interestsSent', (select count(*) from public.docs d where d.collection = 'interests' and d.data->>'from' = v_pid),
      'matches',       (select count(*) from public.docs d where d.collection = 'matches'
                          and jsonb_typeof(d.data->'users') = 'array' and d.data->'users' ? v_pid),
      'conversations', (select count(*) from public.docs d where d.collection = 'chats' and v_pid = any(string_to_array(d.id, '__'))),
      'messagesSent',  (select count(*) from public.docs d,
                               jsonb_array_elements(case when jsonb_typeof(d.data->'messages') = 'array' then d.data->'messages' else '[]'::jsonb end) m
                         where d.collection = 'chats' and v_pid = any(string_to_array(d.id, '__')) and m->>'senderId' = v_pid),
      'blocksMade',    (select count(*) from public.docs d where d.collection = 'blocks' and d.data->>'by' = v_pid),
      'reportsSent',   (select count(*) from public.docs d where d.collection = 'reports' and d.data->>'by' = v_pid)
    ),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status,
                                                              'createdAt', r.created_at, 'updatedAt', r.updated_at)
                                           order by r.created_at desc), '[]'::jsonb)
                   from public.hdm_data_requests r where r.user_id = v_uid)
  );
end $$;

-- ---------------------------------------------------------------------
-- בקשת עותק. נשמרת עם האימייל המאומת של המבקש. בקשה פתוחה מוחזרת במקום כפילות; עד 3 ב-30 יום.
-- ---------------------------------------------------------------------
create or replace function public.hdm_request_data_copy()
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_pid   text;
  v_email text;
  r       public.hdm_data_requests%rowtype;
begin
  if v_uid is null then raise exception 'HDM_NOT_AUTHENTICATED' using errcode = 'P0001'; end if;
  select o.profile_id into v_pid from public.hdm_profile_owners o where o.user_id = v_uid;
  if v_pid is null then raise exception 'HDM_NOT_LINKED' using errcode = 'P0001'; end if;
  select u.email into v_email from auth.users u where u.id = v_uid and u.email_confirmed_at is not null;
  if v_email is null then raise exception 'HDM_EMAIL_NOT_CONFIRMED' using errcode = 'P0001'; end if;

  -- נעילה לפי משתמש, כדי ששתי לחיצות באותו רגע לא ייצרו שתי בקשות
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text, 0));

  select * into r from public.hdm_data_requests q
   where q.user_id = v_uid and q.status in ('new', 'in_progress') order by q.created_at desc limit 1;
  if found then
    return jsonb_build_object('id', r.id, 'status', r.status, 'createdAt', r.created_at, 'existing', true);
  end if;
  if (select count(*) from public.hdm_data_requests q where q.user_id = v_uid and q.created_at > now() - interval '30 days') >= 3 then
    raise exception 'HDM_TOO_MANY_REQUESTS' using errcode = 'P0001';
  end if;

  insert into public.hdm_data_requests(user_id, profile_id, email) values (v_uid, v_pid, v_email) returning * into r;
  return jsonb_build_object('id', r.id, 'status', r.status, 'createdAt', r.created_at, 'existing', false);
end $$;

-- ---------------------------------------------------------------------
-- למנהל בלבד (SQL Editor): עותק מלא לפי מספר בקשה. האימייל נלקח מהבקשה (אימייל מאומת),
-- לא מטבלת docs. כולל רק הודעות שהמשתמש עצמו כתב; פרטי הצד השני בשיחה לא נכללים.
-- ---------------------------------------------------------------------
create or replace function public.hdm_admin_export(p_request_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  q public.hdm_data_requests%rowtype;
begin
  select * into q from public.hdm_data_requests where id = p_request_id;
  if not found then raise exception 'HDM_REQUEST_NOT_FOUND' using errcode = 'P0001'; end if;
  return jsonb_build_object(
    'requestId', q.id, 'sendTo', q.email, 'exportedAt', now(),
    'profile', (select case when jsonb_typeof(d.data) = 'object' then d.data - 'likes' end
                  from public.docs d where d.collection = 'profiles' and d.id = q.profile_id),
    'interestsSent', (select count(*) from public.docs d where d.collection = 'interests' and d.data->>'from' = q.profile_id),
    'matches', (select count(*) from public.docs d where d.collection = 'matches'
                  and jsonb_typeof(d.data->'users') = 'array' and d.data->'users' ? q.profile_id),
    'myMessages', (select coalesce(jsonb_agg(jsonb_build_object('conversation', c.conv, 'text', m->'text', 'ts', m->'ts')
                                             order by c.conv, (m->>'ts')), '[]'::jsonb)
                     from (select dense_rank() over (order by d.id) as conv, d.data from public.docs d
                            where d.collection = 'chats' and q.profile_id = any(string_to_array(d.id, '__'))) c,
                          jsonb_array_elements(case when jsonb_typeof(c.data->'messages') = 'array' then c.data->'messages' else '[]'::jsonb end) m
                    where m->>'senderId' = q.profile_id),
    'blocksMade', (select count(*) from public.docs d where d.collection = 'blocks' and d.data->>'by' = q.profile_id),
    'reportsSent', (select coalesce(jsonb_agg(jsonb_build_object('reason', d.data->'reason', 'details', d.data->'details', 'ts', d.data->'ts')), '[]'::jsonb)
                      from public.docs d where d.collection = 'reports' and d.data->>'by' = q.profile_id)
  );
end $$;

-- הרשאות. Supabase נותן אוטומטית EXECUTE לכל פונקציה חדשה — מבטלים הכל ונותנים רק מה שצריך.
revoke all on function public.hdm_touch_request()                    from public, anon, authenticated;
revoke all on function public.hdm_register_new_profile(text, text)   from public, anon, authenticated;
revoke all on function public.hdm_claim_profile(text)                from public, anon, authenticated;
revoke all on function public.hdm_my_data()                          from public, anon, authenticated;
revoke all on function public.hdm_request_data_copy()                from public, anon, authenticated;
revoke all on function public.hdm_admin_export(bigint)               from public, anon, authenticated;
grant execute on function public.hdm_register_new_profile(text, text) to anon, authenticated;  -- בהרשמה עוד אין חיבור
grant execute on function public.hdm_claim_profile(text)              to authenticated;
grant execute on function public.hdm_my_data()                        to authenticated;
grant execute on function public.hdm_request_data_copy()              to authenticated;

-- =====================================================================
-- למנהל: קישור משתמשים ותיקים (שמוליק ונועה) — פעם אחת, ידנית
-- ⚠️ טבלת docs ניתנת לשינוי על ידי כל אחד, ולכן אין לסמוך על השאילתה למטה לבדה:
--    לקשר רק אימייל שאת/ה יודע/ת בוודאות שהוא של האדם, ורק אם email_confirmed_at מלא.
-- 1) הצגה בלבד:
-- select id as user_id, email, email_confirmed_at, confirmation_sent_at from auth.users order by created_at;
-- select id as profile_id, data->>'currentName' as name from public.docs where collection = 'profiles';
--
-- 2) קישור (להחליף את הערכים אחרי בדיקה):
-- insert into public.hdm_profile_owners(user_id, profile_id, linked_by)
-- values ('<user_id>', '<profile_id>', 'admin');
--
-- טיפול בבקשות עותק:
-- select id, email, status, created_at from public.hdm_data_requests order by created_at desc;
-- select public.hdm_admin_export(<id>);   -- לשלוח רק לכתובת שבשדה sendTo
-- update public.hdm_data_requests set status = 'done', admin_note = 'נשלח באימייל' where id = <id>;
--
-- ביטול:
-- drop function if exists public.hdm_admin_export(bigint), public.hdm_request_data_copy(), public.hdm_my_data(),
--   public.hdm_claim_profile(text), public.hdm_register_new_profile(text, text);
-- drop table if exists public.hdm_data_requests, public.hdm_profile_owners, public.hdm_profile_registry;
-- drop function if exists public.hdm_touch_request();
-- =====================================================================
