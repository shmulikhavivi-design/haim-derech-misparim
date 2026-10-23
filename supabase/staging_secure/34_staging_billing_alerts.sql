-- =====================================================================
-- חיים דרך מספרים — התראות סליקה לבעלים (Staging). "הכול או כלום".
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.hdm_staging_marker') is null then raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא שונה.'; end if;
  if to_regclass('public.hdm_billing_alerts') is not null then raise exception 'עצירה: כבר מותקן. שום דבר לא שונה.'; end if;
end $$;
-- התראות סליקה לבעלים (22.10): כל חיוב שנכשל, תשלום שדורש בדיקה, או חיוב שנשלח ולא אושר — נרשם כהתראה,
-- מוצג באפליקציה רק למי שברשימת המקבלים, עד סימון "טופל". לא משנה תשלומים, מנויים או חיובים.
create table public.hdm_billing_alerts (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  kind          text not null check (kind in ('first_charge_failed', 'renewal_failed', 'renewal_final_failure',
                                              'needs_review', 'charge_unconfirmed', 'upgrade_failed')),
  profile_id    text,
  ref           text not null,                 -- מזהה התשלום / החיוב / ניסיון התשלום
  amount_agorot int,
  details       text,
  resolved_at   timestamptz,
  unique (kind, ref)
);
create table public.hdm_billing_alert_recipients (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  added_at   timestamptz not null default now()
);
alter table public.hdm_billing_alerts enable row level security;
alter table public.hdm_billing_alert_recipients enable row level security;
revoke all on public.hdm_billing_alerts, public.hdm_billing_alert_recipients from public, anon, authenticated;

create function public.hdm_billing_alert_add(p_kind text, p_profile text, p_ref text, p_amount int, p_details text)
returns void language sql volatile security definer set search_path = '' as $$
  insert into public.hdm_billing_alerts (kind, profile_id, ref, amount_agorot, details)
  values (p_kind, p_profile, p_ref, p_amount, left(p_details, 300))
  on conflict (kind, ref) do nothing
$$;

-- תשלומים: נכשל / לבדיקה
create function public.hdm_billing_alerts_on_payment() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- הצטרפות/שדרוג שנדחו — התראה אחת מניסיון התשלום (hdm_billing_alerts_on_checkout); כאן רק חידושים
  if new.outcome = 'failed' and new.kind = 'renewal' then
    perform public.hdm_billing_alert_add('renewal_failed', new.profile_id, new.grow_transaction_id, new.amount_agorot, 'חיוב חידוש נדחה — ינוסה שוב בעוד 48 שעות');
  end if;
  if new.needs_review then
    perform public.hdm_billing_alert_add('needs_review', new.profile_id, new.grow_transaction_id, new.amount_agorot, 'תשלום לבדיקה ידנית: ' || new.result);
  end if;
  return new;
end $$;
create trigger hdm_billing_alerts_on_payment after insert on public.hdm_payments for each row execute function public.hdm_billing_alerts_on_payment();

-- ניסיון תשלום (הצטרפות/שדרוג) שנסגר כנכשל — כרטיס נדחה
create function public.hdm_billing_alerts_on_checkout() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'failed' and old.status is distinct from 'failed' then
    perform public.hdm_billing_alert_add(case when new.kind = 'upgrade' then 'upgrade_failed' else 'first_charge_failed' end,
      new.profile_id, 'checkout:' || new.id, new.amount_agorot, 'כרטיס נדחה — ' || case when new.kind = 'upgrade' then 'שדרוג ל-' else 'הצטרפות ל-' end || new.plan);
  end if;
  return new;
end $$;
create trigger hdm_billing_alerts_on_checkout after update on public.hdm_checkouts for each row execute function public.hdm_billing_alerts_on_checkout();

-- חיובי חידוש: בלי תשובה (review) / כישלון שלישי (המנוי יסתיים)
create function public.hdm_billing_alerts_on_renewal() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'review' and old.status is distinct from 'review' then
    perform public.hdm_billing_alert_add('charge_unconfirmed', new.profile_id, 'renewal:' || new.id, new.amount_agorot, 'חיוב חידוש בלי תשובה ברורה — לבדוק ב-Morning אם חויב');
  elsif new.status = 'failed' and old.status is distinct from 'failed' and new.attempt >= 3 then
    perform public.hdm_billing_alert_add('renewal_final_failure', new.profile_id, 'renewal:' || new.id, new.amount_agorot, 'ניסיון חידוש שלישי נכשל — המנוי יסתיים בלי חיוב נוסף');
  end if;
  return new;
end $$;
create trigger hdm_billing_alerts_on_renewal after update on public.hdm_renewal_charges for each row execute function public.hdm_billing_alerts_on_renewal();

-- סריקה (מהמשימה המתוזמנת): חיוב ראשון/שדרוג שנשלח ל-Morning ולא נסגר תוך 15 דקות
create function public.hdm_billing_scan_alerts() returns int language plpgsql volatile security definer set search_path = '' as $$
declare n int;
begin
  with x as (
    insert into public.hdm_billing_alerts (kind, profile_id, ref, amount_agorot, details)
    select 'charge_unconfirmed', c.profile_id, 'checkout:' || c.id, c.amount_agorot, 'חיוב נשלח ל-Morning ולא אושר תוך 15 דקות — לבדוק ב-Morning אם חויב'
      from public.hdm_checkouts c
     where c.status = 'pending' and c.grow_process_id like 'morning-charge:%' and c.created_at < now() - interval '15 minutes'
    on conflict (kind, ref) do nothing returning 1)
  select count(*) into n from x;
  return n;
end $$;

-- לאפליקציה: רק מקבלי ההתראות רואים ומסמנים
create function public.hdm_billing_alerts_mine() returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.hdm_billing_alert_recipients where user_id = auth.uid()) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'at', a.created_at, 'kind', a.kind, 'amount', a.amount_agorot, 'details', a.details,
                    'profile', a.profile_id) order by a.created_at desc)
                     from public.hdm_billing_alerts a where a.resolved_at is null), '[]'::jsonb);
end $$;
create function public.hdm_billing_alert_resolve(p_id bigint) returns boolean language plpgsql volatile security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.hdm_billing_alert_recipients where user_id = auth.uid()) then
    raise exception 'HDM_NOT_ALLOWED' using errcode = 'P0001';
  end if;
  update public.hdm_billing_alerts set resolved_at = now() where id = p_id and resolved_at is null;
  return found;
end $$;
revoke all on function public.hdm_billing_alert_add(text, text, text, int, text), public.hdm_billing_alerts_on_payment(),
  public.hdm_billing_alerts_on_renewal(), public.hdm_billing_alerts_on_checkout(), public.hdm_billing_scan_alerts(), public.hdm_billing_alerts_mine(),
  public.hdm_billing_alert_resolve(bigint) from public, anon, authenticated;
grant execute on function public.hdm_billing_alerts_mine(), public.hdm_billing_alert_resolve(bigint) to authenticated;
grant execute on function public.hdm_billing_scan_alerts() to service_role;
commit;
