-- =====================================================================
-- חיים דרך מספרים — אישור תנאי שימוש, מדיניות פרטיות וכללי התנהגות (נאכף בשרת)
--
-- Staging: להריץ פעם אחת אחרי 01–05. נעצר אם כבר הותקן. "הכול או כלום".
-- Production: אותו קוד (הקטע שבין הסימונים CONSENT) נכלל אוטומטית בקובץ המעבר
--             דרך scripts/release/build_production_sql.py.
--
-- מה זה עושה:
--   * hdm_terms_versions — גרסאות המסמכים. גרסה עם requires_reconsent = true מחייבת אישור מחדש מכולם.
--   * hdm_consents — תיעוד לכל משתמש: מזהה משתמש, מזהה פרופיל, גרסה, אילו מסמכים, מקור (הרשמה/מסך אישור), תאריך ושעה.
--   * hdm_me() — מחזירה את הפרופיל רק אם המשתמש אישר את הגרסה הנדרשת. כל כללי ה-RLS וכל פונקציות השרת
--     עוברים דרכה, ולכן בלי אישור אי אפשר לקרוא פרופילים/שיחות/התאמות ואי אפשר לכתוב כלום.
--   * hdm_terms_status() / hdm_accept_terms() — מה האפליקציה רואה ואיך מאשרים.
--   * מחיקת חשבון עובדת גם בלי אישור (זכות המשתמש), ומוחקת גם את רשומות האישור.
-- לא משנה ולא מוחק פרופילים, התאמות, שיחות או משתמשים קיימים.
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט הניסוי. בפרויקט הפעיל הקוד הזה נכלל בקובץ המעבר. שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_consents') is not null then
    raise exception 'עצירה: מנגנון האישור כבר מותקן. שום דבר לא שונה.';
  end if;
end $$;

-- ===== CONSENT START =====
-- ---------------------------------------------------------------------
-- אישור תנאי שימוש, מדיניות פרטיות וכללי התנהגות
-- ---------------------------------------------------------------------
create table public.hdm_terms_versions (
  version            text primary key check (version ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[a-z]?$'),
  published_at       timestamptz not null default now(),
  requires_reconsent boolean not null default true,   -- שינוי מהותי: כולם מאשרים מחדש
  note               text
);
insert into public.hdm_terms_versions (version, requires_reconsent, note)
values ('2026-10-16', true, 'השקה: תנאי שימוש, מדיניות פרטיות וכללי התנהגות');

create table public.hdm_consents (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  profile_id  text,
  version     text not null references public.hdm_terms_versions(version),
  documents   text[] not null default array['terms', 'privacy', 'conduct'],
  source      text not null check (source in ('signup', 'gate')),
  accepted_at timestamptz not null default now(),
  unique (user_id, version)
);
create index hdm_consents_user on public.hdm_consents (user_id, version);
alter table public.hdm_terms_versions enable row level security;
alter table public.hdm_consents       enable row level security;
revoke all on public.hdm_terms_versions, public.hdm_consents from public, anon, authenticated;

-- הגרסה שכל משתמש חייב לאשר כרגע (האחרונה שמחייבת אישור מחדש)
create function public.hdm_required_terms_version()
returns text language sql stable security definer set search_path = '' as $$
  select v.version from public.hdm_terms_versions v
   where v.requires_reconsent
   order by v.published_at desc, v.version desc
   limit 1
$$;

create function public.hdm_has_consent(p_uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_uid is not null and exists (
    select 1 from public.hdm_consents c
     where c.user_id = p_uid and c.version = public.hdm_required_terms_version())
$$;

-- הפרופיל של המשתמש המחובר — רק אחרי אישור המסמכים (כל ה-RLS ופונקציות השרת עוברים כאן)
create or replace function public.hdm_me()
returns text language sql stable security definer set search_path = '' as $$
  select a.profile_id from public.hdm_accounts a
   where a.auth_user_id = auth.uid() and public.hdm_has_consent(auth.uid())
$$;

create or replace function public.hdm_require_me()
returns text language plpgsql stable security definer set search_path = '' as $$
declare v text := public.hdm_me();
begin
  if v is null then
    if auth.uid() is not null
       and exists (select 1 from public.hdm_accounts a where a.auth_user_id = auth.uid())
       and not public.hdm_has_consent(auth.uid()) then
      raise exception 'HDM_TERMS_REQUIRED' using errcode = 'P0001',
        hint = 'יש לאשר את תנאי השימוש, מדיניות הפרטיות וכללי ההתנהגות.';
    end if;
    raise exception 'HDM_NOT_SIGNED_IN' using errcode = 'P0001', hint = 'נדרשת התחברות.';
  end if;
  return v;
end $$;

-- מה האפליקציה צריכה לדעת: איזו גרסה נדרשת והאם המשתמש אישר אותה
create function public.hdm_terms_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  req text := public.hdm_required_terms_version();
  last_v text; last_at timestamptz;
begin
  if uid is null then
    raise exception 'HDM_NOT_SIGNED_IN' using errcode = 'P0001', hint = 'נדרשת התחברות.';
  end if;
  select c.version, c.accepted_at into last_v, last_at
    from public.hdm_consents c where c.user_id = uid
   order by c.accepted_at desc limit 1;
  return jsonb_build_object('required', req, 'accepted', public.hdm_has_consent(uid),
                            'acceptedVersion', last_v, 'acceptedAt', last_at,
                            'reconsent', last_v is not null and not public.hdm_has_consent(uid));
end $$;

-- אישור מפורש: רק לגרסה הנדרשת כרגע. הרצה חוזרת לא יוצרת כפילות.
create function public.hdm_accept_terms(p_version text, p_source text default 'gate')
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'HDM_NOT_SIGNED_IN' using errcode = 'P0001', hint = 'נדרשת התחברות.';
  end if;
  if p_version is distinct from public.hdm_required_terms_version() then
    raise exception 'HDM_TERMS_VERSION' using errcode = 'P0001', hint = 'גרסת המסמכים התעדכנה. יש לרענן ולאשר שוב.';
  end if;
  if p_source is null or p_source not in ('signup', 'gate') then
    raise exception 'HDM_INVALID_INPUT' using errcode = 'P0001';
  end if;
  -- "הרשמה" רק אם תיבת האישור סומנה בהרשמה עצמה (נשמר עם משתמש ההתחברות). אחרת — מסך האישור.
  if p_source = 'signup' and coalesce((select u.raw_user_meta_data->>'hdm_terms' from auth.users u where u.id = uid), '') <> p_version then
    raise exception 'HDM_TERMS_SIGNUP' using errcode = 'P0001', hint = 'לא נמצא אישור מההרשמה. יש לאשר במסך האישור.';
  end if;
  insert into public.hdm_consents (user_id, profile_id, version, source)
  values (uid, (select a.profile_id from public.hdm_accounts a where a.auth_user_id = uid), p_version, p_source)
  on conflict (user_id, version) do nothing;
  return public.hdm_terms_status();
end $$;

-- אישור שניתן בהרשמה לפני שנוצר פרופיל: מזהה הפרופיל נרשם ברגע שהחשבון מקושר לפרופיל
create function public.hdm_consents_fill_profile()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.hdm_consents set profile_id = new.profile_id
   where user_id = new.auth_user_id and profile_id is null;
  return new;
end $$;
create trigger hdm_accounts_consent_profile
  after insert on public.hdm_accounts
  for each row execute function public.hdm_consents_fill_profile();

-- ניהול (SQL Editor בלבד): פרסום גרסה חדשה של המסמכים. requires_reconsent = true → כולם מאשרים מחדש בכניסה הבאה.
create function public.hdm_admin_publish_terms(p_version text, p_requires_reconsent boolean, p_note text default null)
returns text language plpgsql volatile security definer set search_path = '' as $$
begin
  insert into public.hdm_terms_versions (version, requires_reconsent, note)
  values (p_version, p_requires_reconsent, p_note);
  return 'גרסה ' || p_version || case when p_requires_reconsent then ' פורסמה — נדרש אישור מחדש מכל המשתמשים'
                                      else ' פורסמה — בלי אישור מחדש' end;
end $$;

-- מחיקת חשבון: מותרת גם למי שלא אישר את המסמכים, ומוחקת גם את רשומות האישור
create or replace function public.hdm_delete_my_data()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  me  text := (select a.profile_id from public.hdm_accounts a where a.auth_user_id = auth.uid());
  n   int;
  auth_deleted boolean := false;
begin
  if me is null then
    raise exception 'HDM_NOT_SIGNED_IN' using errcode = 'P0001', hint = 'נדרשת התחברות.';
  end if;
  delete from public.docs d
   where (d.collection = 'profiles'  and d.id = me)
      or (d.collection in ('interests', 'matches', 'chats', 'blocks') and public.hdm_pair_has(d.id, me))
      or (d.collection = 'chatReads' and public.hdm_pair_has(split_part(d.id, '___', 2), me))
      or (d.collection = '__lease'   and d.id like 'chats/%' and public.hdm_pair_has(substr(d.id, 7), me));
  get diagnostics n = row_count;
  delete from public.hdm_profile_private where profile_id = me;
  delete from public.hdm_chat_openings   where profile_id = me;
  delete from public.hdm_subscriptions   where profile_id = me;
  delete from public.hdm_consents        where user_id = uid;
  delete from public.hdm_accounts        where profile_id = me;
  begin
    delete from auth.users where id = uid;
    auth_deleted := found;
  exception when insufficient_privilege then
    auth_deleted := false;
  end;
  return jsonb_build_object('deletedDocs', n, 'authUserDeleted', auth_deleted);
end $$;

revoke all on function public.hdm_required_terms_version(), public.hdm_has_consent(uuid),
                       public.hdm_consents_fill_profile(), public.hdm_admin_publish_terms(text, boolean, text),
                       public.hdm_terms_status(), public.hdm_accept_terms(text, text)
  from public, anon, authenticated;
revoke all on function public.hdm_delete_my_data() from public, anon;
grant execute on function public.hdm_terms_status(), public.hdm_accept_terms(text, text), public.hdm_delete_my_data()
  to authenticated;
-- ===== CONSENT END =====

insert into public.hdm_staging_marker (version, note)
values ('staging_consent_v1', 'אישור תנאי שימוש, מדיניות פרטיות וכללי התנהגות — נאכף בשרת');

commit;

select '✅ מנגנון האישור הותקן' as "סטטוס",
       public.hdm_required_terms_version() as "גרסה נדרשת",
       (select count(*) from public.hdm_consents) as "אישורים";
