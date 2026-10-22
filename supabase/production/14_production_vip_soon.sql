-- =====================================================================
-- חיים דרך מספרים — VIP "בקרוב" (Production), בקשת הבעלים 22.10: VIP מוצג אבל אי אפשר להצטרף/לשדרג אליו (נחסם בשרת).
-- בסיסי ופלוס פתוחים. מחיר, הטבות, הרשאות וחידוש של VIP לא משתנים. לא נוגע במשתמשים, מנויים או תשלומים. "הכול או כלום".
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.hdm_staging_marker') is not null then raise exception 'עצירה: זה לא Production. שום דבר לא שונה.'; end if;
  if not exists (select 1 from public.hdm_release_marker where version = 'production_billing_v1') then raise exception 'עצירה: קודם 08. שום דבר לא שונה.'; end if;
  if to_regclass('public.hdm_plan_sale') is not null then raise exception 'עצירה: כבר מותקן. שום דבר לא שונה.'; end if;
end $$;
create temp table hdm_pre on commit drop as select (select count(*) from public.hdm_subscriptions) s, (select count(*) from public.docs) d, (select count(*) from auth.users) u;
-- מסלולים שפתוחים לרכישה. VIP — "בקרוב": מוצג, אבל אי אפשר להצטרף או לשדרג אליו. כל שאר תשתית ה-VIP (מחיר, הטבות,
-- הרשאות, חידוש ומנוי קיים) נשארת כמו שהיא. הפעלה בעתיד: update public.hdm_plan_sale set on_sale = true where plan = 'vip';
create table public.hdm_plan_sale (
  plan       text primary key references public.hdm_plans(plan),
  on_sale    boolean not null,
  note       text,
  updated_at timestamptz not null default now()
);
alter table public.hdm_plan_sale enable row level security;
revoke all on public.hdm_plan_sale from public, anon, authenticated;
insert into public.hdm_plan_sale (plan, on_sale, note) values
  ('basic', true,  null),
  ('plus',  true,  null),
  ('vip',   false, 'בקרוב — ייפתח לרכישה אחרי הוספת שירותים חדשים (בקשת הבעלים 22.10)');

create function public.hdm_billing_plan_on_sale(p_plan text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select on_sale from public.hdm_plan_sale where plan = p_plan), false)
$$;
revoke all on function public.hdm_billing_plan_on_sale(text) from public, anon;
grant execute on function public.hdm_billing_plan_on_sale(text) to authenticated, service_role;

-- כל ניסיון תשלום (הצטרפות או שדרוג) נרשם ב-hdm_checkouts — לכן החסימה כאן תופסת את שני המסלולים בשרת.
create function public.hdm_checkouts_require_on_sale()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not public.hdm_billing_plan_on_sale(new.plan) then
    raise exception 'HDM_BILLING_PLAN_SOON' using errcode = 'P0001',
      hint = 'מסלול ' || coalesce((select name_he from public.hdm_plans where plan = new.plan), new.plan) || ' יהיה זמין בקרוב.';
  end if;
  return new;
end $$;
revoke all on function public.hdm_checkouts_require_on_sale() from public, anon, authenticated;
create trigger hdm_checkouts_require_on_sale before insert on public.hdm_checkouts
  for each row execute function public.hdm_checkouts_require_on_sale();
do $$ begin
  if (select s from hdm_pre) <> (select count(*) from public.hdm_subscriptions) or (select d from hdm_pre) <> (select count(*) from public.docs)
     or (select u from hdm_pre) <> (select count(*) from auth.users) then raise exception 'עצירה: מספר הרשומות השתנה.'; end if;
end $$;
insert into public.hdm_release_marker (version, note) values ('production_vip_soon', 'VIP בקרוב — לא פתוח לרכישה (22.10)');
commit;
