-- =====================================================================
-- חיים דרך מספרים — מניעת שליחה כפולה של מיילי הביטול (Staging). אותו קוד כמו ב-Production 19. "הכול או כלום".
-- =====================================================================
begin;
do $$ begin if to_regclass('public.hdm_staging_marker') is null then raise exception 'עצירה: זה לא פרויקט הניסוי.'; end if; end $$;
-- מניעת שליחה כפולה: כל מייל "נתפס" לפני השליחה. הרצה מקבילה או חוזרת לא תקבל אותו שוב (10 דקות),
-- ומייל שנשלח (sent_at) לא נשלח שוב לעולם. מייל שנכשל חוזר לתור אחרי 10 דקות, עד 5 ניסיונות.
alter table public.hdm_email_outbox add column if not exists claimed_at timestamptz;
create or replace function public.hdm_email_outbox_claim(p_limit int default 20)
returns table (id bigint, kind text, to_email text, subject text, body_text text, attempts int)
language plpgsql volatile security definer set search_path = '' as $$
begin
  return query
  with c as (
    update public.hdm_email_outbox e set claimed_at = now()
     where e.id in (select x.id from public.hdm_email_outbox x
                     where x.sent_at is null and x.attempts < 5
                       and (x.claimed_at is null or x.claimed_at < now() - interval '10 minutes')
                     order by x.id limit greatest(coalesce(p_limit, 20), 1)
                     for update skip locked)
    returning e.id, e.kind, e.user_id, e.subject, e.body_text, e.attempts)
  select c.id, c.kind, u.email::text, c.subject, c.body_text, c.attempts
    from c join auth.users u on u.id = c.user_id order by c.id;
end $$;
revoke all on function public.hdm_email_outbox_claim(int) from public, anon, authenticated;
grant execute on function public.hdm_email_outbox_claim(int) to service_role;
insert into public.hdm_staging_marker (version, note) values ('staging_email_claim_v1', 'מניעת שליחה כפולה של מיילי ביטול');
commit;
