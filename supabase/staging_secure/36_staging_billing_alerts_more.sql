-- =====================================================================
-- חיים דרך מספרים — התראות סליקה, תוספת (Staging): בקשת החזר בתוך 14 יום + מייל ביטול שלא נשלח תוך 30 דקות + תשלום שסומן לבדיקה אחרי שנרשם. "הכול או כלום".
-- (ב-Production זה חלק מ-18, שעוד לא הותקן.)
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.hdm_staging_marker') is null then raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא שונה.'; end if;
  if to_regclass('public.hdm_billing_alerts') is null then raise exception 'עצירה: קודם 34. שום דבר לא שונה.'; end if;
  if to_regprocedure('public.hdm_billing_alerts_on_cancel()') is not null then raise exception 'עצירה: כבר מותקן. שום דבר לא שונה.'; end if;
end $$;
alter table public.hdm_billing_alerts drop constraint hdm_billing_alerts_kind_check;
alter table public.hdm_billing_alerts add constraint hdm_billing_alerts_kind_check check (kind in ('first_charge_failed', 'renewal_failed', 'renewal_final_failure',
  'needs_review', 'charge_unconfirmed', 'upgrade_failed', 'refund_requested', 'email_delayed'));
create or replace function public.hdm_billing_alerts_on_payment() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' and new.outcome = 'failed' and new.kind = 'renewal' then
    perform public.hdm_billing_alert_add('renewal_failed', new.profile_id, new.grow_transaction_id, new.amount_agorot, 'חיוב חידוש נדחה — ינוסה שוב בעוד 48 שעות');
  end if;
  -- גם כשהתשלום מסומן לבדיקה רק אחרי שנרשם (למשל תשלום כפול לאותו ניסיון)
  if new.needs_review and (tg_op = 'INSERT' or not coalesce(old.needs_review, false)) then
    perform public.hdm_billing_alert_add('needs_review', new.profile_id, new.grow_transaction_id, new.amount_agorot, 'תשלום לבדיקה ידנית: ' || new.result);
  end if;
  return new;
end $$;
drop trigger hdm_billing_alerts_on_payment on public.hdm_payments;
create trigger hdm_billing_alerts_on_payment after insert or update of needs_review on public.hdm_payments for each row execute function public.hdm_billing_alerts_on_payment();
-- תוספת (22.10 15:11): בקשת החזר כספי בתוך 14 יום, ומייל ביטול שלא נשלח תוך 30 דקות
create function public.hdm_billing_alerts_on_cancel() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.refund_requested then
    perform public.hdm_billing_alert_add('refund_requested', new.profile_id, 'cancel:' || new.id,
      (select p.amount_agorot from public.hdm_payments p where p.profile_id = new.profile_id and p.outcome = 'approved' order by p.received_at desc limit 1),
      'בקשת החזר כספי (ביטול בתוך 14 יום) — לבצע החזר ב-Morning ולסמן טופל');
  end if;
  return new;
end $$;
create trigger hdm_billing_alerts_on_cancel after insert on public.hdm_cancel_requests for each row execute function public.hdm_billing_alerts_on_cancel();
create or replace function public.hdm_billing_scan_alerts() returns int language plpgsql volatile security definer set search_path = '' as $$
declare n int; m int;
begin
  with x as (
    insert into public.hdm_billing_alerts (kind, profile_id, ref, amount_agorot, details)
    select 'charge_unconfirmed', c.profile_id, 'checkout:' || c.id, c.amount_agorot, 'חיוב נשלח ל-Morning ולא אושר תוך 15 דקות — לבדוק ב-Morning אם חויב'
      from public.hdm_checkouts c
     where c.status = 'pending' and c.grow_process_id like 'morning-charge:%' and c.created_at < now() - interval '15 minutes'
    on conflict (kind, ref) do nothing returning 1)
  select count(*) into n from x;
  with y as (
    insert into public.hdm_billing_alerts (kind, profile_id, ref, amount_agorot, details)
    select 'email_delayed', e.profile_id, 'email:' || e.id, null,
           'מייל ' || case e.kind when 'cancel_confirmed' then 'אישור ביטול' else 'קבלת בקשת ביטול' end || ' לא נשלח תוך 30 דקות'
           || coalesce(' (' || e.last_error || ')', '') || ' — לבדוק את Brevo'
      from public.hdm_email_outbox e
     where e.sent_at is null and e.created_at < now() - interval '30 minutes'
    on conflict (kind, ref) do nothing returning 1)
  select count(*) into m from y;
  return n + m;
end $$;
revoke all on function public.hdm_billing_alerts_on_cancel(), public.hdm_billing_scan_alerts() from public, anon, authenticated;
grant execute on function public.hdm_billing_scan_alerts() to service_role;
insert into public.hdm_staging_marker (version, note) values ('staging_billing_alerts_more_v1', 'התראות: החזר בתוך 14 יום, מייל ביטול שלא נשלח');
commit;
