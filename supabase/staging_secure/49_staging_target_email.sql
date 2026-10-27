-- =====================================================================
-- חיים דרך מספרים — תשתית התראת מייל על קבלת חץ 🎯 (גרסה 4, 27.10.2026).
-- אותו קובץ בדיוק רץ ב-Staging ואחר כך ב-Production (רק באישור הבעלים).
-- רק מוסיף: 3 טבלאות חדשות, טריגר אחד, 9 פונקציות. לא מוחק ולא משנה נתון קיים.
-- לא שולח מיילים: רק תור. השליחה (hdm-target-mailer) היא שלב נפרד.
--
-- מניעת כפילויות — "לכל היותר פעם אחת":
--   pending → claimed → sending → sent
--   * claimed: שורה נתפסה ע"י הרצה אחת (FOR UPDATE SKIP LOCKED) — הרצה מקבילה לא תקבל אותה.
--   * sending: נרשם (commit) רגע לפני המסירה ל-Brevo. שורה ב-sending לא נשלחת שוב לעולם —
--     גם אם סימון "נשלח" נכשל אחרי שליחה מוצלחת.
--   * ניסיון חוזר (retry) רק כש-Brevo דחה במפורש (קוד 4xx = לא נשלח). תשובה לא ברורה
--     (5xx / ניתוק / זמן קצוב) = uncertain — לא נשלח שוב.
-- הגבלה: זוג שולח→מקבל — מייל אחד ל-30 יום; מקבל — עד 3 ב-24 שעות.
--   נעילה לכל מקבל (advisory lock) — נאכף גם כשכמה חצים נשלחים בו-זמנית.
-- ביטול התראות: מבטל מיד כל מייל שבתור, ונבדק שוב ב-begin רגע לפני המסירה ל-Brevo.
--   נעילת טרנזקציה (xact) משתחררת ב-commit ולכן אינה מכסה את קריאת ה-HTTP. לכן:
--   * begin מסרב לעבוד אם המתקשר אינו מחזיק כבר נעילת session של אותו משתמש (pg_advisory_lock) —
--     זו הנעילה שמחזיקה פונקציית השליחה, בחיבור אחד, מ-begin ועד אחרי סימון התוצאה (כולל הקריאה ל-Brevo).
--   * ביטול התראות לוקח את אותה נעילה (xact) — ממתין עד שהמסירה הנוכחית מסתיימת, וכל מייל שעוד לא נמסר מבוטל.
--   תוצאה: ביטול שנשמר לפני begin — לא נשלח; ביטול בזמן מסירה — ממתין לסופה ונכנס לתוקף מיד אחריה.
-- רגע לפני המסירה נבדק שוב: אימייל מאומת, חשבון פעיל, אין חסימה בין השניים, והחץ עדיין קיים.
-- מבנה החץ (כמו ב-hdm_send_target): docs.collection = 'interests', id = '<שולח>__<מקבל>', data = {from, to, ts}.
-- פרטיות: במייל אין שום פרט על השולח. מזהה השולח נשמר בתור בשרת בלבד (לבדיקת חסימה) — סגור לאפליקציה.
-- תקלה בטריגר לא מבטלת את החץ. "הכול או כלום"; הרצה חוזרת נעצרת בלי לשנות.
-- הגנת סביבה: ב-Production הקובץ רץ רק אחרי השורה המפורשת (מודבקת ידנית לפני הקובץ, באישור הבעלים):
--   set hdm.allow_production_install = 'target_email_v1';
-- בלעדיה — נעצר ולא משנה כלום. ב-Staging (יש hdm_staging_marker) אין צורך בה.
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.hdm_staging_marker') is null
     and coalesce(current_setting('hdm.allow_production_install', true), '') <> 'target_email_v1' then
    raise exception 'עצירה: זה Production ולא ניתן אישור מפורש להתקנה. שום דבר לא שונה.';
  end if;
  if to_regclass('public.docs') is null or to_regclass('public.hdm_accounts') is null
     or (to_regclass('public.hdm_release_marker') is null and to_regclass('public.hdm_staging_marker') is null) then
    raise exception 'עצירה: זה לא מסד מאובטח של האפליקציה. שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_target_email_outbox') is not null then raise exception 'עצירה: כבר מותקן. שום דבר לא שונה.'; end if;
  if to_regprocedure('public.hdm_blocked_between(text,text)') is null then raise exception 'עצירה: חסרה hdm_blocked_between.'; end if;
  if not exists (select 1 from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = i.indkey[0]
                  where i.indrelid = 'public.hdm_accounts'::regclass and i.indisunique and i.indnatts = 1 and a.attname = 'profile_id') then
    raise exception 'עצירה: hdm_accounts.profile_id אינו ייחודי. שום דבר לא שונה.';
  end if;
  if (select count(*) from information_schema.columns where table_schema = 'auth' and table_name = 'users'
        and column_name in ('id', 'email', 'email_confirmed_at', 'banned_until', 'deleted_at')) <> 5 then
    raise exception 'עצירה: מבנה auth.users שונה מהצפוי. שום דבר לא שונה.';
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then raise exception 'עצירה: חסר service_role.'; end if;
  if exists (select 1 from pg_trigger where tgrelid = 'public.docs'::regclass and tgname = 'hdm_target_email_on_interest') then
    raise exception 'עצירה: הטריגר כבר קיים. שום דבר לא שונה.';
  end if;
end $$;
create temp table hdm_pre on commit drop as
  select (select count(*) from public.docs) d, (select md5(coalesce(string_agg(collection || id || data::text, ',' order by collection, id), '')) from public.docs) dh,
         (select count(*) from auth.users) u, (select md5(string_agg(to_jsonb(p)::text, '|' order by plan)) from public.hdm_plans p) pl,
         (select md5(coalesce(string_agg(to_jsonb(s)::text, '|' order by profile_id), '')) from public.hdm_subscriptions s) su,
         (select md5(coalesce(string_agg(to_jsonb(p)::text, '|' order by id), '')) from public.hdm_payments p) pa;

-- 1. העדפת המשתמש (ברירת מחדל: מופעל). נמחקת עם החשבון.
create table public.hdm_target_email_prefs (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  target_emails  boolean not null default true,
  updated_at     timestamptz not null default now()
);

-- 2. יומן זוגות (מייל אחד ל-30 יום לכל שולח→מקבל). נמחק עם החשבון של כל אחד מהצדדים.
create table public.hdm_target_email_log (
  sender_profile     text not null references public.hdm_accounts(profile_id) on delete cascade,
  recipient_profile  text not null references public.hdm_accounts(profile_id) on delete cascade,
  last_queued_at     timestamptz not null default now(),
  primary key (sender_profile, recipient_profile)
);
create index hdm_target_email_log_recipient on public.hdm_target_email_log (recipient_profile);

-- 3. תור המיילים. הכתובת נלקחת מהחשבון רק ברגע המסירה. מזהה השולח — לבדיקת חסימה בלבד, לא נשלח במייל.
create table public.hdm_target_email_outbox (
  id               bigint generated always as identity primary key,
  user_id          uuid not null references auth.users(id) on delete cascade,
  sender_profile   text not null references public.hdm_accounts(profile_id) on delete cascade,
  status           text not null default 'pending'
                   check (status in ('pending', 'claimed', 'sending', 'sent', 'retry', 'uncertain', 'failed', 'skipped')),
  created_at       timestamptz not null default now(),
  claimed_at       timestamptz,
  sending_at       timestamptz,
  sent_at          timestamptz,
  next_attempt_at  timestamptz not null default now(),
  attempts         int not null default 0,
  last_error       text,
  skipped          text
);
create index hdm_target_email_outbox_ready on public.hdm_target_email_outbox (next_attempt_at, id) where status in ('pending', 'retry', 'claimed');
create index hdm_target_email_outbox_user on public.hdm_target_email_outbox (user_id, created_at);
create index hdm_target_email_outbox_sender on public.hdm_target_email_outbox (sender_profile);

alter table public.hdm_target_email_prefs   enable row level security;
alter table public.hdm_target_email_log     enable row level security;
alter table public.hdm_target_email_outbox  enable row level security;
revoke all on public.hdm_target_email_prefs, public.hdm_target_email_log, public.hdm_target_email_outbox from public, anon, authenticated;

-- נוסח המייל — מקום אחד (נוסח הבעלים + שורת ביטול התראות)
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

-- האם מותר לשלוח למשתמש עכשיו (אימייל מאומת, לא חסום, יש חשבון, לא ביטל התראות)
create function public.hdm_target_email_allowed(p_uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from auth.users u join public.hdm_accounts a on a.auth_user_id = u.id
                  where u.id = p_uid and u.email is not null and u.email_confirmed_at is not null
                    and (u.banned_until is null or u.banned_until < now()) and u.deleted_at is null)
     and not exists (select 1 from public.hdm_target_email_prefs p where p.user_id = p_uid and not p.target_emails)
$$;

-- 4. הטריגר: חץ חדש שנשמר → שורה בתור (או כלום). לעולם לא מכשיל את שמירת החץ.
create function public.hdm_target_email_on_interest()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  s text := new.data->>'from';
  r text := new.data->>'to';
  ruid uuid;
  ok boolean;
begin
  begin
    if s is null or r is null or s = r or new.id is distinct from s || '__' || r then return null; end if;   -- רק חץ במבנה התקין
    select a.auth_user_id into ruid from public.hdm_accounts a where a.profile_id = r;
    if ruid is null or not public.hdm_target_email_allowed(ruid) then return null; end if;
    if not exists (select 1 from public.hdm_accounts where profile_id = s) then return null; end if;
    if public.hdm_blocked_between(s, r) then return null; end if;
    -- נעילה לכל מקבל עד סוף הטרנזקציה: חצים בו-זמניים לאותו מקבל נבדקים אחד אחרי השני
    perform pg_advisory_xact_lock(hashtextextended('hdm_target_email:' || ruid::text, 0));
    if not public.hdm_target_email_allowed(ruid) then return null; end if;   -- שוב, אחרי הנעילה
    if (select count(*) from public.hdm_target_email_outbox o
         where o.user_id = ruid and o.created_at > now() - interval '24 hours') >= 3 then return null; end if;
    insert into public.hdm_target_email_log as l (sender_profile, recipient_profile) values (s, r)
    on conflict (sender_profile, recipient_profile) do update set last_queued_at = now()
      where l.last_queued_at < now() - interval '30 days'
    returning true into ok;
    if ok is null then return null; end if;
    insert into public.hdm_target_email_outbox (user_id, sender_profile) values (ruid, s);
  exception when others then
    raise warning 'hdm_target_email_on_interest: %', sqlerrm;   -- החץ נשמר בכל מקרה
  end;
  return null;
end $$;
create trigger hdm_target_email_on_interest
  after insert on public.docs
  for each row when (new.collection = 'interests')
  execute function public.hdm_target_email_on_interest();

-- 5. שולח המיילים (service_role בלבד).
-- 5א. תפיסה: כל שורה נתפסת ע"י הרצה אחת בלבד.
create function public.hdm_target_email_claim(p_limit int default 20)
returns table (id bigint, kind text)
language plpgsql volatile security definer set search_path = '' as $$
begin
  update public.hdm_target_email_outbox o set status = 'skipped', skipped = 'opted_out_or_unavailable'
   where o.status in ('pending', 'retry', 'claimed') and not public.hdm_target_email_allowed(o.user_id);
  update public.hdm_target_email_outbox o set status = 'failed', last_error = coalesce(o.last_error, 'expired')
   where o.status in ('pending', 'retry') and (o.created_at < now() - interval '3 days' or o.attempts >= 5);
  return query
  with c as (
    update public.hdm_target_email_outbox e set status = 'claimed', claimed_at = now()
     where e.id in (select x.id from public.hdm_target_email_outbox x
                     where ((x.status in ('pending', 'retry') and x.next_attempt_at <= now())
                            or (x.status = 'claimed' and x.claimed_at < now() - interval '10 minutes'))   -- נתפס ולא נמסר — עוד לא נשלח
                     order by x.id limit greatest(least(coalesce(p_limit, 20), 50), 1)
                     for update skip locked)
    returning e.id)
  select c.id, 'target_received'::text from c order by c.id;
end $$;

-- האם החיבור הנוכחי מחזיק את נעילת המשתמש (pg_advisory_lock עם המפתח הזה)
create function public.hdm_target_email_lock_held(p_uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from pg_catalog.pg_locks l,
                   (select hashtextextended('hdm_target_email:' || p_uid::text, 0) as k) x
                  where l.locktype = 'advisory' and l.pid = pg_catalog.pg_backend_pid() and l.granted and l.objsubid = 1
                    and l.classid::bigint = ((x.k >> 32) & 4294967295) and l.objid::bigint = (x.k & 4294967295))
$$;

-- 5ב. רגע לפני המסירה ל-Brevo: בדיקה אחרונה, מעבר ל-sending ומסירת הכתובת. רק קריאה אחת מצליחה לכל שורה.
--     נבדק: אימייל מאומת/חשבון פעיל, לא ביטל התראות, אין חסימה בין השניים, החץ עדיין קיים.
--     רק למתקשר שמחזיק את נעילת ה-session של המשתמש. שורה שלא הוחזרה — לא לשלוח.
create function public.hdm_target_email_begin(p_id bigint)
returns table (id bigint, to_email text, subject text, body_text text)
language plpgsql volatile security definer set search_path = '' as $$
declare uid uuid; snd text; rcp text;
begin
  select o.user_id into uid from public.hdm_target_email_outbox o where o.id = p_id;
  if uid is null then return; end if;
  -- חובה: המתקשר מחזיק נעילת session של המשתמש לאורך כל המסירה. בלעדיה — לא מוסרים (השורה נשארת בתור).
  if not public.hdm_target_email_lock_held(uid) then return; end if;
  perform pg_advisory_xact_lock(hashtextextended('hdm_target_email:' || uid::text, 0));
  select o.sender_profile into snd from public.hdm_target_email_outbox o where o.id = p_id and o.status = 'claimed' for update;
  if snd is null then return; end if;
  select a.profile_id into rcp from public.hdm_accounts a where a.auth_user_id = uid;
  if not public.hdm_target_email_allowed(uid) then
    update public.hdm_target_email_outbox o set status = 'skipped', skipped = 'opted_out_or_unavailable' where o.id = p_id;
    return;
  end if;
  if rcp is null or public.hdm_blocked_between(snd, rcp)
     or not exists (select 1 from public.docs d where d.collection = 'interests' and d.id = snd || '__' || rcp) then
    update public.hdm_target_email_outbox o set status = 'skipped', skipped = 'blocked_or_withdrawn' where o.id = p_id;
    return;
  end if;
  update public.hdm_target_email_outbox o set status = 'sending', sending_at = now(), attempts = o.attempts + 1 where o.id = p_id;
  return query select p_id, u.email::text, t.subject, t.body_text
                 from auth.users u cross join public.hdm_target_email_text() t where u.id = uid;
end $$;

-- 5ג. תוצאה: sent / rejected (Brevo דחה במפורש — אפשר לנסות שוב) / uncertain (לא ברור — לא נשלח שוב)
create function public.hdm_target_email_done(p_id bigint, p_result text, p_error text)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if p_result not in ('sent', 'rejected', 'uncertain') then raise exception 'HDM_BAD_INPUT' using errcode = 'P0001'; end if;
  update public.hdm_target_email_outbox o
     set status          = case p_result when 'sent' then 'sent'
                                         when 'rejected' then case when o.attempts >= 5 then 'failed' else 'retry' end
                                         else 'uncertain' end,
         sent_at         = case when p_result = 'sent' then now() else o.sent_at end,
         next_attempt_at = case when p_result = 'rejected' then now() + interval '10 minutes' else o.next_attempt_at end,
         last_error      = case when p_result = 'sent' then null else left(p_error, 200) end
   where o.id = p_id and o.status = 'sending';
end $$;

-- 6. לאפליקציה: מצב ההתראות שלי והחלפה (כיבוי מבטל מיד מיילים שבתור)
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
  perform pg_advisory_xact_lock(hashtextextended('hdm_target_email:' || auth.uid()::text, 0));   -- מול מסירה בו-זמנית
  insert into public.hdm_target_email_prefs (user_id, target_emails, updated_at) values (auth.uid(), p_on, now())
  on conflict (user_id) do update set target_emails = excluded.target_emails, updated_at = now();
  if not p_on then
    update public.hdm_target_email_outbox set status = 'skipped', skipped = 'opted_out'
     where user_id = auth.uid() and status in ('pending', 'retry', 'claimed');
  end if;
  return public.hdm_my_email_prefs();
end $$;

revoke all on function public.hdm_target_email_text(), public.hdm_target_email_allowed(uuid), public.hdm_target_email_lock_held(uuid), public.hdm_target_email_on_interest(),
  public.hdm_target_email_claim(int), public.hdm_target_email_begin(bigint), public.hdm_target_email_done(bigint, text, text),
  public.hdm_my_email_prefs(), public.hdm_set_target_emails(boolean) from public, anon, authenticated;
grant execute on function public.hdm_my_email_prefs(), public.hdm_set_target_emails(boolean) to authenticated;
grant execute on function public.hdm_target_email_claim(int), public.hdm_target_email_begin(bigint),
  public.hdm_target_email_done(bigint, text, text) to service_role;

do $$ begin
  if (select d from hdm_pre) <> (select count(*) from public.docs)
     or (select dh from hdm_pre) <> (select md5(coalesce(string_agg(collection || id || data::text, ',' order by collection, id), '')) from public.docs)
     or (select u from hdm_pre) <> (select count(*) from auth.users)
     or (select pl from hdm_pre) <> (select md5(string_agg(to_jsonb(p)::text, '|' order by plan)) from public.hdm_plans p)
     or (select su from hdm_pre) <> (select md5(coalesce(string_agg(to_jsonb(s)::text, '|' order by profile_id), '')) from public.hdm_subscriptions s)
     or (select pa from hdm_pre) <> (select md5(coalesce(string_agg(to_jsonb(p)::text, '|' order by id), '')) from public.hdm_payments p) then
    raise exception 'עצירה: נתונים קיימים השתנו. שום דבר לא נשמר.';
  end if;
  if exists (select 1 from public.hdm_target_email_outbox) then raise exception 'עצירה: התור לא ריק אחרי ההתקנה.'; end if;
end $$;
do $$ begin
  if to_regclass('public.hdm_release_marker') is not null then
    insert into public.hdm_release_marker (version, note) values ('target_email_v1', 'התראת מייל על חץ 🎯 — תשתית בלבד (27.10)');
  end if;
end $$;
commit;

-- ביטול מלא (לא רץ כחלק מהקובץ):
-- begin;
--   drop trigger if exists hdm_target_email_on_interest on public.docs;
--   drop function if exists public.hdm_target_email_on_interest(), public.hdm_target_email_claim(int), public.hdm_target_email_begin(bigint),
--     public.hdm_target_email_done(bigint, text, text), public.hdm_my_email_prefs(), public.hdm_set_target_emails(boolean),
--     public.hdm_target_email_allowed(uuid), public.hdm_target_email_lock_held(uuid), public.hdm_target_email_text();
--   drop table if exists public.hdm_target_email_outbox, public.hdm_target_email_log, public.hdm_target_email_prefs;
--   delete from public.hdm_release_marker where version = 'target_email_v1';
-- commit;
