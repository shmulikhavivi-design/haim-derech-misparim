-- =====================================================================
-- חיים דרך מספרים — הפרופיל של הבעלים: חשבון מנהל בלבד, מוסתר מחיפוש הזוגיות (Production). ⛔ רק באישור הבעלים.
-- לא מוחק את הפרופיל, את החשבון, את המנוי או את התשלומים. אפשר להחזיר: delete from public.hdm_hidden_profiles where profile_id = '…';
-- נבדק לפני: לבעלים אין 🎯, התאמות, שיחות, חסימות או דיווחים — ההסתרה לא משפיעה על אף משתמש. "הכול או כלום".
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.hdm_staging_marker') is not null then raise exception 'עצירה: זה לא Production. שום דבר לא שונה.'; end if;
  if to_regclass('public.hdm_admins') is null then raise exception 'עצירה: קודם 20 (לוח הניהול). שום דבר לא שונה.'; end if;
  if to_regclass('public.hdm_hidden_profiles') is not null then raise exception 'עצירה: כבר מותקן. שום דבר לא שונה.'; end if;
end $$;
create temp table hdm_pre on commit drop as select (select count(*) from auth.users) u, (select count(*) from public.docs) d, (select count(*) from public.hdm_subscriptions) s, (select count(*) from public.hdm_payments) p;
-- ---------------------------------------------------------------------
-- פרופילים מוסתרים מחיפוש הזוגיות (חשבון מנהל בלבד). לא מוחק כלום: הפרופיל, החשבון, המנוי והתשלומים נשארים.
-- ---------------------------------------------------------------------
create table public.hdm_hidden_profiles (
  profile_id text primary key,
  reason     text not null default 'admin_only',
  hidden_at  timestamptz not null default now()
);
alter table public.hdm_hidden_profiles enable row level security;
revoke all on table public.hdm_hidden_profiles from public, anon, authenticated;

create function public.hdm_profile_hidden(p text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.hdm_hidden_profiles h where h.profile_id = p)
$$;
revoke all on function public.hdm_profile_hidden(text) from public, anon;
grant execute on function public.hdm_profile_hidden(text) to authenticated;

-- משתמשים אחרים לא רואים פרופיל מוסתר (בעל הפרופיל עדיין רואה את עצמו)
drop policy profiles_read on public.docs;
create policy profiles_read on public.docs for select to authenticated
  using (collection = 'profiles'
         and (id = public.hdm_me()
              or (public.hdm_me() is not null
                  and not public.hdm_blocked_me(id)
                  and coalesce(data->>'ageBlocked', '') <> 'true'
                  and not public.hdm_profile_hidden(id))));

-- אי אפשר לסמן 🎯 לפרופיל מוסתר (ולכן גם לא לפתוח איתו שיחה)
create function public.hdm_block_hidden_target() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.collection = 'interests' and public.hdm_profile_hidden(split_part(new.id, '__', 2)) then
    raise exception 'HDM_TARGET_UNAVAILABLE' using errcode = 'P0001', hint = 'הפרופיל הזה לא זמין.';
  end if;
  return new;
end $$;
revoke all on function public.hdm_block_hidden_target() from public, anon, authenticated;
create trigger hdm_block_hidden_target before insert on public.docs for each row when (new.collection = 'interests') execute function public.hdm_block_hidden_target();

-- בלוח הניהול: מנהלים ופרופילים מוסתרים לא נספרים כמשתמשים אמיתיים
create or replace function public.hdm_admin_is_test(p_uid uuid, p_email text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(lower(p_email) like '%@example.invalid', false)
      or coalesce(lower(p_email) like 'life.through.numbers333+%@gmail.com', false)
      or (p_uid is not null and exists (select 1 from public.hdm_test_accounts t where t.auth_user_id = p_uid))
      or (p_uid is not null and exists (select 1 from public.hdm_admins a where a.auth_user_id = p_uid))
      or (p_uid is not null and exists (select 1 from public.hdm_accounts acc join public.hdm_hidden_profiles h on h.profile_id = acc.profile_id where acc.auth_user_id = p_uid))
$$;
revoke all on function public.hdm_admin_is_test(uuid, text) from public, anon, authenticated;
insert into public.hdm_hidden_profiles (profile_id, reason)
select a.profile_id, 'admin_only' from public.hdm_accounts a join auth.users u on u.id = a.auth_user_id
 where md5(lower(u.email)) = '162e004328485070b0af8b256ad2e798';
do $$ begin
  if (select count(*) from public.hdm_hidden_profiles) <> 1 then raise exception 'עצירה: הפרופיל של הבעלים לא נמצא.'; end if;
  if (select u from hdm_pre) <> (select count(*) from auth.users) or (select d from hdm_pre) <> (select count(*) from public.docs)
     or (select s from hdm_pre) <> (select count(*) from public.hdm_subscriptions) or (select p from hdm_pre) <> (select count(*) from public.hdm_payments) then
    raise exception 'עצירה: מספר הרשומות השתנה.'; end if;
end $$;
insert into public.hdm_release_marker (version, note) values ('production_owner_admin_only', 'הפרופיל של הבעלים מוסתר מחיפוש הזוגיות (22.10)');
commit;
