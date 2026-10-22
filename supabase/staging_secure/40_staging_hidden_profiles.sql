-- =====================================================================
-- חיים דרך מספרים — פרופילים מוסתרים מחיפוש הזוגיות (Staging). אותו גוף כמו Production 21, בלי הסתרת הבעלים. "הכול או כלום".
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.hdm_staging_marker') is null then raise exception 'עצירה: זה לא פרויקט הניסוי.'; end if;
  if to_regclass('public.hdm_hidden_profiles') is not null then raise exception 'עצירה: כבר מותקן.'; end if;
end $$;
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
insert into public.hdm_staging_marker (version, note) values ('staging_hidden_profiles_v1', 'פרופילים מוסתרים מחיפוש');
commit;
