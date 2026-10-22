-- =====================================================================
-- חיים דרך מספרים — אפשרות 2 (כרטיס פעם אחת): קישור פרופיל ↔ לקוח ב-Morning. לפונקציות השרת בלבד. Staging.
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.hdm_staging_marker') is null then raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא שונה.'; end if;
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
commit;
