-- =====================================================================
-- חיים דרך מספרים — התראת מייל על קבלת חץ 🎯. בקשת הבעלים 27.10.2026.
-- אותו קובץ בדיוק רץ ב-Staging ואחר כך ב-Production (רק באישור מפורש).
--
-- איך זה עובד:
--   * טריגר AFTER INSERT על public.docs רק כש-collection = 'interests' (חץ חדש שנשמר).
--     הוא רץ באותה טרנזקציה של שמירת החץ: אם השמירה נכשלת — גם ההתראה לא נוצרת (דרישה 1).
--     חץ שכבר קיים (on conflict do nothing) לא מפעיל את הטריגר.
--   * הטריגר רק מכניס שורה לתור hdm_target_email_outbox. המייל עצמו נשלח אחר כך, אחרי ה-commit,
--     ע"י הפונקציה hdm-target-mailer (Brevo, אותו מפתח ושולח כמו מיילי הביטול). אין שינוי בהגדרות SMTP.
--   * כל תקלה בטריגר נתפסת בתוכו (תת-טרנזקציה) — החץ נשמר תמיד (דרישה 7).
--   * מניעת כפילויות והצפה (דרישות 2–3):
--       - זוג שולח→מקבל: מייל אחד לכל 30 יום, גם אם החץ בוטל ונשלח שוב (hdm_target_email_log).
--       - מקבל: עד 3 מיילים על חצים ב-24 שעות.
--       - שליחה: כל מייל "נתפס" בשרת לפני השליחה ונשלח פעם אחת בלבד; כשל חוזר לתור רק אחרי 10 דקות (עד 5 ניסיונות).
--   * פרטיות (דרישות 4, 8): במייל ובתור אין שם, מזהה או פרט כלשהו של שולח החץ. מי שלח —
--     רק באפליקציה, לפי המסלול (hdm_who_targeted_me, ללא שינוי). התור והיומן סגורים לגמרי לאפליקציה.
--   * ביטול התראות (דרישה 5): hdm_set_target_emails(false) מהמסך "הגדרות ← התראות מייל".
--     נבדק גם בזמן הכנסה לתור וגם רגע לפני השליחה.
--   * נשלח רק לחשבון עם אימייל מאומת, לא חסום, ולא אם יש חסימה בין השניים.
--
-- לא משנה: hdm_send_target / hdm_remove_target / התאמה הדדית / צ'אט / מסלולים / מנויים / סליקה / מיילי הביטול.
-- "הכול או כלום"; הרצה חוזרת נעצרת בלי לשנות.
-- ביטול מלא: drop trigger hdm_target_email_on_interest on public.docs; (ושאר האובייקטים — ראו בסוף הקובץ)
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.docs') is null or to_regclass('public.hdm_accounts') is null
     or (to_regclass('public.hdm_release_marker') is null and to_regclass('public.hdm_staging_marker') is null) then
    raise exception 'עצירה: זה לא מסד מאובטח של האפליקציה. שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_target_email_outbox') is not null then raise exception 'עצירה: כבר מותקן. שום דבר לא שונה.'; end if;
  if to_regprocedure('public.hdm_blocked_between(text,text)') is null then raise exception 'עצירה: חסרה hdm_blocked_between.'; end if;
end $$;
create temp table hdm_pre on commit drop as
  select (select count(*) from public.docs) d, (select count(*) from auth.users) u, (select md5(string_agg(to_jsonb(p)::text, '|' order by plan)) from public.hdm_plans p) pl;

-- 1. העדפת המשתמש (ברירת מחדל: מופעל). נמחק עם החשבון.
create table public.hdm_target_email_prefs (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  target_emails  boolean not null default true,
  updated_at     timestamptz not null default now()
);

-- 2. יומן זוגות (למניעת כפילויות/הצפה). שרת בלבד. נמחק עם החשבון של כל אחד מהצדדים.
create table public.hdm_target_email_log (
  sender_profile     text not null references public.hdm_accounts(profile_id) on delete cascade,
  recipient_profile  text not null references public.hdm_accounts(profile_id) on delete cascade,
  last_queued_at     timestamptz not null default now(),
  primary key (sender_profile, recipient_profile)
);
create index hdm_target_email_log_recipient on public.hdm_target_email_log (recipient_profile);

-- 3. תור המיילים. בלי פרטי השולח. הכתובת נלקחת מהחשבון רק בזמן השליחה.
create table public.hdm_target_email_outbox (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  claimed_at  timestamptz,
  attempts    int not null default 0,
  last_error  text,
  sent_at     timestamptz,
  skipped     text                          -- לא נשלח בכוונה (למשל ביטול התראות אחרי ההכנסה לתור)
);
create index hdm_target_email_outbox_pending on public.hdm_target_email_outbox (id) where sent_at is null and skipped is null;
create index hdm_target_email_outbox_user on public.hdm_target_email_outbox (user_id, created_at);

alter table public.hdm_target_email_prefs   enable row level security;
alter table public.hdm_target_email_log     enable row level security;
alter table public.hdm_target_email_outbox  enable row level security;
revoke all on public.hdm_target_email_prefs, public.hdm_target_email_log, public.hdm_target_email_outbox from public, anon, authenticated;

-- נוסח המייל — מקום אחד בלבד (נוסח הבעלים + שורת ביטול התראות)
create function public.hdm_target_email_text()
returns table (subject text, body_text text) language sql immutable set search_path = '' as $$
  select '❤️ מישהו מתעניין בך!'::text,
         E'יש לנו חדשות משמחות בשבילך!\n\n'
      || E'מישהו ראה את הפרופיל שלך ושלח לך חץ 🎯.\n\n'
      || E'אולי זאת תחילתה של אהבה חדשה?\n\n'
      || E'היכנסו לאפליקציה וגלו מי מתעניין בכם, בהתאם למסלול המנוי שלכם.\n\n'
      || E'https://haimderechmisparim.com\n\n'
      || E'חיים דרך מספרים – אהבה היא לא מקרית!\n\n'
      || E'לא רוצים לקבל מיילים על חצים? אפשר לבטל בכל עת באפליקציה: הגדרות ← התראות מייל.\nhttps://haimderechmisparim.com/#notify'::text
$$;

-- 4. הטריגר: חץ חדש → שורה בתור (או כלום). לעולם לא מכשיל את שמירת החץ.
create function public.hdm_target_email_on_interest()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  s text := new.data->>'from';
  r text := new.data->>'to';
  ruid uuid;
  ok boolean;
begin
  begin
    if s is null or r is null or s = r then return null; end if;
    select a.auth_user_id into ruid
      from public.hdm_accounts a join auth.users u on u.id = a.auth_user_id
     where a.profile_id = r
       and u.email is not null and u.email_confirmed_at is not null
       and (u.banned_until is null or u.banned_until < now())
       and u.deleted_at is null;
    if ruid is null then return null; end if;                                         -- אין חשבון/אימייל מאומת
    if not exists (select 1 from public.hdm_accounts where profile_id = s) then return null; end if;
    if exists (select 1 from public.hdm_target_email_prefs where user_id = ruid and not target_emails) then return null; end if;
    if public.hdm_blocked_between(s, r) then return null; end if;
    -- מקבל: עד 3 ב-24 שעות
    if (select count(*) from public.hdm_target_email_outbox o
         where o.user_id = ruid and o.created_at > now() - interval '24 hours') >= 3 then return null; end if;
    -- זוג: פעם ב-30 יום (כולל ביטול ושליחה חוזרת)
    insert into public.hdm_target_email_log as l (sender_profile, recipient_profile) values (s, r)
    on conflict (sender_profile, recipient_profile) do update set last_queued_at = now()
      where l.last_queued_at < now() - interval '30 days'
    returning true into ok;
    if ok is null then return null; end if;
    insert into public.hdm_target_email_outbox (user_id) values (ruid);
  exception when others then
    raise warning 'hdm_target_email_on_interest: %', sqlerrm;   -- החץ נשמר בכל מקרה
  end;
  return null;
end $$;
create trigger hdm_target_email_on_interest
  after insert on public.docs
  for each row when (new.collection = 'interests')
  execute function public.hdm_target_email_on_interest();

-- 5. לשולח המיילים (service_role בלבד): תפיסה אטומית — כל מייל נשלח פעם אחת.
create function public.hdm_target_email_claim(p_limit int default 20)
returns table (id bigint, kind text, to_email text, subject text, body_text text, attempts int)
language plpgsql volatile security definer set search_path = '' as $$
begin
  -- מי שביטל התראות / אימייל לא מאומת / חשבון חסום — לא נשלח, מסומן כדילוג
  update public.hdm_target_email_outbox o set skipped = 'opted_out_or_unavailable'
   where o.sent_at is null and o.skipped is null
     and (exists (select 1 from public.hdm_target_email_prefs p where p.user_id = o.user_id and not p.target_emails)
          or not exists (select 1 from auth.users u where u.id = o.user_id and u.email is not null and u.email_confirmed_at is not null
                           and (u.banned_until is null or u.banned_until < now()) and u.deleted_at is null)
          or not exists (select 1 from public.hdm_accounts a where a.auth_user_id = o.user_id));   -- החשבון נמחק
  return query
  with c as (
    update public.hdm_target_email_outbox e set claimed_at = now()
     where e.id in (select x.id from public.hdm_target_email_outbox x
                     where x.sent_at is null and x.skipped is null and x.attempts < 5
                       and x.created_at > now() - interval '3 days'
                       and (x.claimed_at is null or x.claimed_at < now() - interval '10 minutes')
                     order by x.id limit greatest(least(coalesce(p_limit, 20), 50), 1)
                     for update skip locked)
    returning e.id, e.user_id, e.attempts)
  select c.id, 'target_received'::text, u.email::text, t.subject, t.body_text, c.attempts
    from c join auth.users u on u.id = c.user_id cross join public.hdm_target_email_text() t
   order by c.id;
end $$;

create function public.hdm_target_email_done(p_id bigint, p_ok boolean, p_error text)
returns void language sql volatile security definer set search_path = '' as $$
  update public.hdm_target_email_outbox
     set sent_at    = case when p_ok then now() else sent_at end,
         attempts   = attempts + 1,
         last_error = case when p_ok then null else left(p_error, 200) end,
         claimed_at = now()            -- כשל: חוזר לתור רק אחרי 10 דקות (לא מיד), כדי שהרצה מקבילה/תשובה שהתעכבה לא יגרמו למייל כפול
   where id = p_id and sent_at is null
$$;

-- 6. לאפליקציה: מצב ההתראות שלי והחלפה
create function public.hdm_my_email_prefs()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'HDM_NOT_SIGNED_IN' using errcode = 'P0001'; end if;
  return jsonb_build_object('targetEmails',
    coalesce((select target_emails from public.hdm_target_email_prefs where user_id = auth.uid()), true));
end $$;

create function public.hdm_set_target_emails(p_on boolean)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'HDM_NOT_SIGNED_IN' using errcode = 'P0001'; end if;
  if p_on is null then raise exception 'HDM_BAD_INPUT' using errcode = 'P0001'; end if;
  insert into public.hdm_target_email_prefs (user_id, target_emails, updated_at) values (auth.uid(), p_on, now())
  on conflict (user_id) do update set target_emails = excluded.target_emails, updated_at = now();
  return public.hdm_my_email_prefs();
end $$;

revoke all on function public.hdm_target_email_text(), public.hdm_target_email_on_interest(),
  public.hdm_target_email_claim(int), public.hdm_target_email_done(bigint, boolean, text),
  public.hdm_my_email_prefs(), public.hdm_set_target_emails(boolean) from public, anon, authenticated;
grant execute on function public.hdm_my_email_prefs(), public.hdm_set_target_emails(boolean) to authenticated;
grant execute on function public.hdm_target_email_claim(int), public.hdm_target_email_done(bigint, boolean, text) to service_role;

do $$ begin
  if (select d from hdm_pre) <> (select count(*) from public.docs) or (select u from hdm_pre) <> (select count(*) from auth.users)
     or (select pl from hdm_pre) <> (select md5(string_agg(to_jsonb(p)::text, '|' order by plan)) from public.hdm_plans p) then
    raise exception 'עצירה: נתונים קיימים השתנו. שום דבר לא נשמר.';
  end if;
  if exists (select 1 from public.hdm_target_email_outbox) then raise exception 'עצירה: התור לא ריק אחרי ההתקנה.'; end if;
end $$;
do $$ begin
  if to_regclass('public.hdm_release_marker') is not null then
    insert into public.hdm_release_marker (version, note) values ('target_email_v1', 'התראת מייל על חץ 🎯 (27.10)');
  end if;
end $$;
commit;

-- ---------------------------------------------------------------------
-- ביטול מלא (לא רץ כחלק מהקובץ):
-- begin;
--   drop trigger if exists hdm_target_email_on_interest on public.docs;
--   drop function if exists public.hdm_target_email_on_interest(), public.hdm_target_email_claim(int),
--     public.hdm_target_email_done(bigint, boolean, text), public.hdm_my_email_prefs(),
--     public.hdm_set_target_emails(boolean), public.hdm_target_email_text();
--   drop table if exists public.hdm_target_email_outbox, public.hdm_target_email_log, public.hdm_target_email_prefs;
-- commit;
