-- =====================================================================
-- חיים דרך מספרים — חשבונית מס/קבלה אוטומטית ב-Morning (חשבונית ירוקה) אחרי כל תשלום מוצלח ב-Grow. Staging בלבד.
--
-- Staging: להריץ פעם אחת אחרי 17–28. נעצר אם כבר הותקן. "הכול או כלום". Production: לא רץ.
--
-- איך זה עובד:
--   * כשתשלום נקלט סופית כ"הצליח" (started / renewed / upgraded) — טריגר מכניס בקשת מסמך לתור, פעם אחת בלבד לכל תשלום.
--     תשלומים שסומנו לבדיקה (סכום שגוי, כפול, אחרי ביטול) לא נכנסים — מטופלים ידנית.
--   * פונקציית שרת (morning-invoices) "תופסת" בקשות, מפיקה ב-Morning ומסמנת "הופק" עם מספר המסמך.
--   * בקשה שנשלחה ולא קיבלה תשובה לא נשלחת שוב אוטומטית (ייתכן שהמסמך כבר הופק) — מסומנת לבדיקה, כמו בחיובים.
--   * החשבונית נפרדת מהמנוי: תקלה ב-Morning לא מבטלת ולא מעכבת מנוי.
--   * הרשומות נשמרות גם אחרי מחיקת חשבון (חובת תיעוד), עם הפרטים שהיו בזמן התשלום.
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא שונה.';
  end if;
  if to_regprocedure('public.hdm_billing_apply_card_renewal(jsonb)') is null then
    raise exception 'עצירה: צריך קודם את 17–28. שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_invoice_queue') is not null then
    raise exception 'עצירה: תור החשבוניות כבר מותקן. שום דבר לא שונה.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. תור המסמכים
-- ---------------------------------------------------------------------
create table public.hdm_invoice_queue (
  id              bigint generated always as identity primary key,
  payment_id      bigint not null unique references public.hdm_payments(id),   -- מסמך אחד לכל תשלום
  profile_id      text,
  email           text,
  kind            text not null,           -- initial / renewal / upgrade
  plan            text,
  amount_agorot   int  not null check (amount_agorot > 0),
  paid_at         timestamptz not null,
  provider_ref    text,                    -- מזהה העסקה ב-Grow
  status          text not null default 'pending' check (status in ('pending', 'sending', 'issued', 'failed', 'review')),
  attempts        int  not null default 0,
  last_error      text,
  doc_id          text,
  doc_number      text,
  claimed_at      timestamptz,
  issued_at       timestamptz,
  created_at      timestamptz not null default now()
);
create index hdm_invoice_queue_open on public.hdm_invoice_queue (status, id) where status in ('pending', 'failed', 'sending');
alter table public.hdm_invoice_queue enable row level security;
revoke all on public.hdm_invoice_queue from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. כניסה לתור: כשהתוצאה הסופית של תשלום היא הצלחה (שורה עוברת מ-'received' לתוצאה)
-- ---------------------------------------------------------------------
create function public.hdm_invoice_enqueue()
returns trigger language plpgsql security definer set search_path = '' as $$
declare em text;
begin
  if new.outcome = 'approved' and new.result in ('started', 'renewed', 'upgraded') and not new.needs_review
     and old.result is distinct from new.result and coalesce(new.amount_agorot, 0) > 0 then
    select lower(u.email) into em
      from public.hdm_accounts a join auth.users u on u.id = a.auth_user_id where a.profile_id = new.profile_id;
    if em is null and new.checkout_id is not null then
      select lower(u.email) into em from public.hdm_checkouts c join auth.users u on u.id = c.user_id where c.id = new.checkout_id;
    end if;
    insert into public.hdm_invoice_queue (payment_id, profile_id, email, kind, plan, amount_agorot, paid_at, provider_ref)
    values (new.id, new.profile_id, em, new.kind, new.plan, new.amount_agorot, new.received_at,
            coalesce(new.raw->>'transactionId', new.grow_transaction_id))
    on conflict (payment_id) do nothing;
  end if;
  return new;
end $$;
create trigger hdm_invoice_enqueue after update of result on public.hdm_payments
  for each row execute function public.hdm_invoice_enqueue();

-- ---------------------------------------------------------------------
-- 3. פונקציות השרת: תפיסה, סימון תוצאה, תקלות
-- ---------------------------------------------------------------------
-- תופס עד p_limit בקשות. "sending" שתקוע יותר משעה → לבדיקה (לא שולחים שוב — ייתכן שהמסמך הופק).
-- נכשל: עד 5 ניסיונות, לפחות 30 דקות ביניהם.
create function public.hdm_invoice_claim(p_limit int default 10)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare out jsonb := '[]'::jsonb; r record;
begin
  update public.hdm_invoice_queue set status = 'review', last_error = coalesce(last_error, 'נשלח ולא התקבלה תשובה — לבדוק ב-Morning')
   where status = 'sending' and claimed_at < now() - interval '1 hour';
  for r in
    select q.*, t.payer_name, t.card_last4
      from public.hdm_invoice_queue q left join public.hdm_billing_tokens t on t.profile_id = q.profile_id
     where q.status = 'pending' or (q.status = 'failed' and q.attempts < 5 and q.claimed_at < now() - interval '30 minutes')
     order by q.id limit p_limit
     for update of q skip locked
  loop
    update public.hdm_invoice_queue set status = 'sending', attempts = attempts + 1, claimed_at = now() where id = r.id;
    out := out || jsonb_build_object('id', r.id, 'kind', r.kind, 'plan', r.plan, 'amountAgorot', r.amount_agorot,
             'paidAt', r.paid_at, 'email', r.email, 'name', r.payer_name, 'last4', r.card_last4, 'providerRef', r.provider_ref);
  end loop;
  return out;
end $$;

create function public.hdm_invoice_done(p_id bigint, p_ok boolean, p_doc_id text default null, p_doc_number text default null, p_error text default null)
returns void language sql volatile security definer set search_path = '' as $$
  update public.hdm_invoice_queue
     set status = case when p_ok then 'issued' when attempts >= 5 then 'review' else 'failed' end,
         doc_id = case when p_ok then p_doc_id else doc_id end, doc_number = case when p_ok then p_doc_number else doc_number end,
         issued_at = case when p_ok then now() end, last_error = case when p_ok then null else left(coalesce(p_error, 'error'), 500) end
   where id = p_id and status = 'sending'
$$;

-- לבדיקת מנהל: מה לא הופק
create function public.hdm_invoice_issues()
returns setof public.hdm_invoice_queue language sql stable security definer set search_path = '' as $$
  select * from public.hdm_invoice_queue where status in ('failed', 'review') order by id
$$;

-- מחיקת חשבון: המסמכים נשארים (חובת תיעוד), הקישור לפרופיל ולמייל נשמר רק עד שהמסמך הופק
create function public.hdm_invoice_on_account_delete()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.hdm_invoice_queue set email = null where profile_id = old.profile_id and status = 'issued';
  return old;
end $$;
create trigger hdm_invoice_on_account_delete after delete on public.hdm_accounts
  for each row execute function public.hdm_invoice_on_account_delete();

revoke all on function public.hdm_invoice_enqueue(), public.hdm_invoice_claim(int),
  public.hdm_invoice_done(bigint, boolean, text, text, text), public.hdm_invoice_issues(), public.hdm_invoice_on_account_delete()
  from public, anon, authenticated;
grant execute on function public.hdm_invoice_claim(int), public.hdm_invoice_done(bigint, boolean, text, text, text),
  public.hdm_invoice_issues() to service_role;

insert into public.hdm_staging_marker (version, note)
values ('staging_invoices_morning_v1', 'תור חשבוניות Morning אחרי תשלום מוצלח — בלי פנייה ל-Morning');

commit;

select '✅ תור החשבוניות (Morning) הותקן ב-Staging' as "סטטוס";
