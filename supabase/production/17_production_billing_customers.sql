-- =====================================================================
-- חיים דרך מספרים — אפשרות 2 (בחירת הבעלים 22.10): הלקוח מזין כרטיס פעם אחת. קישור פרופיל ↔ לקוח ב-Morning,
-- לפונקציות השרת בלבד (בלי גישה מהאפליקציה). לא נוגע במשתמשים, מנויים או תשלומים. "הכול או כלום".
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.hdm_staging_marker') is not null then raise exception 'עצירה: זה לא Production. שום דבר לא שונה.'; end if;
  if not exists (select 1 from public.hdm_release_marker where version = 'production_billing_v1') then raise exception 'עצירה: קודם 08. שום דבר לא שונה.'; end if;
  if to_regclass('public.hdm_billing_customers') is not null then raise exception 'עצירה: כבר מותקן. שום דבר לא שונה.'; end if;
end $$;
create table public.hdm_billing_customers (
  profile_id        text primary key,
  morning_client_id text not null unique,     -- מזהה הלקוח ב-Morning (גם externalKey של הכרטיס השמור)
  created_at        timestamptz not null default now()
);
alter table public.hdm_billing_customers enable row level security;
revoke all on public.hdm_billing_customers from public, anon, authenticated;
grant select, insert, update on public.hdm_billing_customers to service_role;
insert into public.hdm_release_marker (version, note) values ('production_billing_customers', 'אפשרות 2: כרטיס פעם אחת — לקוחות Morning (22.10)');
commit;
