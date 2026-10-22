-- =====================================================================
-- חיים דרך מספרים — מנויים בתשלום ב-Production (נוצר אוטומטית מ-scripts/release/build_production_billing_sql.py)
-- אותו קוד שרת שנבדק ב-Staging: 17 + 19 + 21 + 23 + 24. לא לערוך ידנית.
--
-- מה הקובץ עושה: מוסיף טבלאות ופונקציות שרת לתשלומים, חידושים, שדרוגים וביטולים.
-- מה הוא לא עושה: לא מחייב, לא מתחבר ל-Morning, לא משנה מחירים, לא משנה מסלול של אף משתמש,
--   ולא מוחק נתונים. הסליקה נשארת כבויה עד שהאפליקציה והפונקציות מופעלות בנפרד, באישור.
-- "הכול או כלום": עסקה אחת; כל בדיקה שנכשלת מבטלת הכול. הרצה חוזרת נעצרת בלי לשנות דבר.
-- להרצה רק אחרי גיבוי מלא ואישור מפורש של הבעלים.
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_release_marker') is null or to_regclass('public.hdm_staging_marker') is not null then
    raise exception 'עצירה: זה לא מסד ה-Production אחרי המעבר המאובטח. שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_consents') is null or to_regclass('public.hdm_subscriptions') is null or to_regclass('public.hdm_plans') is null then
    raise exception 'עצירה: חסרים רכיבי בסיס (אישור תנאים / מנויים / מסלולים). שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_payments') is not null or exists (select 1 from public.hdm_release_marker where version = 'production_billing_v1') then
    raise exception 'עצירה: מנגנון המנויים בתשלום כבר מותקן. שום דבר לא שונה.';
  end if;
end $$;

-- תמונת מצב לפני: מסלולים ומחירים, ומסלול כל משתמש (לבדיקה בסוף שלא השתנה דבר)
create temp table hdm_pre_plans on commit drop as
  select string_agg(plan || ':' || price_agorot || ':' || coalesce(monthly_new_chats::text, '∞') || ':' || limor_discount_pct, ',' order by sort_order) as v from public.hdm_plans;
create temp table hdm_pre_subs on commit drop as
  select profile_id, public.hdm_plan_of(profile_id) as plan from public.hdm_subscriptions;
create temp table hdm_pre_counts on commit drop as
  select (select count(*) from public.docs) as docs, (select count(*) from auth.users) as users, (select count(*) from public.hdm_accounts) as accounts;

-- ===================== 17_staging_billing.sql (ללא שינוי) =====================
-- ===== BILLING START =====
-- ---------------------------------------------------------------------
-- 1. שדות חדשים במנוי
-- ---------------------------------------------------------------------
alter table public.hdm_subscriptions
  add column auto_renew           boolean not null default false,   -- מתחדש אוטומטית (רק מנוי בתשלום)
  add column grow_direct_debit_id text unique,                      -- מזהה הוראת הקבע ב-Grow
  add column failed_attempts      int not null default 0,           -- חיובי חידוש שנכשלו ברצף
  add column last_payment_at      timestamptz;
alter table public.hdm_subscriptions drop constraint if exists hdm_subscriptions_status_check;
alter table public.hdm_subscriptions add constraint hdm_subscriptions_status_check
  check (status in ('active', 'canceled', 'expired', 'past_due'));

-- המסלול בפועל: גם במצב "חיוב נכשל" המנוי בתוקף רק עד סוף התקופה ששולמה — לא יום אחד יותר
create or replace function public.hdm_plan_of(p text)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce((
    select s.plan from public.hdm_subscriptions s
     where s.profile_id = p
       and s.status in ('active', 'canceled', 'past_due')
       and (s.current_period_end is null or s.current_period_end > now())
  ), 'free')
$$;

-- ---------------------------------------------------------------------
-- 2. טבלאות
-- ---------------------------------------------------------------------
-- גרסאות תנאי החידוש שהלקוח מאשר לפני תשלום
create table public.hdm_billing_terms_versions (
  version      text primary key,
  published_at timestamptz not null default now(),
  summary_he   text not null
);
insert into public.hdm_billing_terms_versions (version, summary_he) values
  ('billing-2026-10-17',
   'המנוי מתחדש אוטומטית מדי חודש באותו תאריך, בחיוב חודשי במחיר המסלול, עד לביטול. אפשר לבטל בכל עת מתוך האפליקציה; '
   || 'הביטול עוצר את החיובים הבאים, והמנוי נשאר בתוקף עד סוף התקופה ששולמה.');

-- ניסיון תשלום: נוצר לפני מעבר לדף התשלום של Grow. כאן נשמרת גם הסכמת הלקוח לתנאי החידוש.
create table public.hdm_checkouts (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null,
  profile_id       text not null,
  plan             text not null references public.hdm_plans(plan),
  amount_agorot    int  not null check (amount_agorot > 0),
  status           text not null default 'pending' check (status in ('pending', 'paid', 'failed', 'expired')),
  terms_version    text not null references public.hdm_billing_terms_versions(version),
  terms_accepted_at timestamptz not null default now(),
  grow_process_id  text unique,                 -- מזהה דף התשלום ב-Grow (יתמלא כשיחובר)
  created_at       timestamptz not null default now(),
  expires_at       timestamptz not null default now() + interval '30 minutes',
  closed_at        timestamptz
);
-- לכל היותר ניסיון תשלום פתוח אחד לכל פרופיל
create unique index hdm_checkouts_one_pending on public.hdm_checkouts (profile_id) where status = 'pending';

-- כל אירוע תשלום מ-Grow, פעם אחת בלבד לכל מזהה עסקה. נשמר גם אחרי מחיקת חשבון (חובת תיעוד).
create table public.hdm_payments (
  id                   bigint generated always as identity primary key,
  grow_transaction_id  text not null unique,
  kind                 text not null check (kind in ('initial', 'renewal')),
  outcome              text not null check (outcome in ('approved', 'failed')),
  result               text not null,       -- started / renewed / failed / duplicate / after_cancel / amount_mismatch / unknown
  needs_review         boolean not null default false,   -- למשל תשלום כפול שצריך להחזיר
  profile_id           text,
  checkout_id          uuid references public.hdm_checkouts(id),
  grow_direct_debit_id text,
  plan                 text,
  amount_agorot        int,
  period_end_after     timestamptz,
  raw                  jsonb not null default '{}'::jsonb,
  received_at          timestamptz not null default now()
);
create index hdm_payments_profile on public.hdm_payments (profile_id, received_at desc);

-- פעולות שצריך לבצע מול Grow (ביטול הוראת קבע). פונקציית השרת תבצע ותסמן בוצע.
create table public.hdm_grow_outbox (
  id                   bigint generated always as identity primary key,
  action               text not null check (action in ('cancel_direct_debit')),
  grow_direct_debit_id text not null,
  profile_id           text,
  reason               text not null,
  created_at           timestamptz not null default now(),
  attempts             int not null default 0,
  last_error           text,
  done_at              timestamptz
);
create unique index hdm_grow_outbox_one_open on public.hdm_grow_outbox (action, grow_direct_debit_id) where done_at is null;

alter table public.hdm_billing_terms_versions enable row level security;
alter table public.hdm_checkouts              enable row level security;
alter table public.hdm_payments               enable row level security;
alter table public.hdm_grow_outbox            enable row level security;
revoke all on public.hdm_billing_terms_versions, public.hdm_checkouts, public.hdm_payments, public.hdm_grow_outbox
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. עזרים
-- ---------------------------------------------------------------------
-- אותו תאריך בחודש לפי שעון ישראל (31 בינואר ← 28/29 בפברואר ← 31 במרץ)
create function public.hdm_billing_add_months(anchor timestamptz, k int)
returns timestamptz language sql immutable set search_path = '' as $$
  select ((anchor at time zone 'Asia/Jerusalem') + make_interval(months => k)) at time zone 'Asia/Jerusalem'
$$;

-- מועד החידוש הראשון שאחרי ref
create function public.hdm_billing_next_after(anchor timestamptz, ref timestamptz)
returns timestamptz language plpgsql immutable set search_path = '' as $$
declare k int := 1; t timestamptz;
begin
  loop
    t := public.hdm_billing_add_months(anchor, k);
    exit when t > ref;
    k := k + 1;
    if k > 1200 then raise exception 'hdm_billing_next_after: out of range'; end if;
  end loop;
  return t;
end $$;

create function public.hdm_billing_current_terms()
returns text language sql stable security definer set search_path = '' as $$
  select version from public.hdm_billing_terms_versions order by published_at desc, version desc limit 1
$$;

-- ביטול הוראת קבע ב-Grow נרשם אוטומטית בכל פעם שמנוי מתחדש מפסיק להתחדש:
-- ביטול על ידי הלקוח, ביטול/פקיעה על ידי מנהל, או מחיקת חשבון.
create function public.hdm_subscriptions_billing_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    if old.auto_renew and old.grow_direct_debit_id is not null then
      insert into public.hdm_grow_outbox (action, grow_direct_debit_id, profile_id, reason)
      values ('cancel_direct_debit', old.grow_direct_debit_id, old.profile_id, 'account_deleted')
      on conflict do nothing;
    end if;
    return old;
  end if;
  -- שינוי מסלול למנוי בתשלום פעיל — רק דרך אירוע מ-Grow (מדיניות שדרוג באמצע חודש עוד לא נקבעה)
  if old.source = 'payment' and old.auto_renew and new.plan is distinct from old.plan
     and coalesce(current_setting('hdm.billing_event', true), '') <> 'on' then
    raise exception 'HDM_PAID_PLAN_LOCKED' using errcode = 'P0001',
      hint = 'למנוי בתשלום פעיל אי אפשר לשנות מסלול ידנית. קודם מבטלים, או ממתינים למדיניות שדרוג.';
  end if;
  if old.auto_renew and new.status in ('canceled', 'expired') then
    new.auto_renew := false;
  end if;
  if old.auto_renew and not new.auto_renew and old.grow_direct_debit_id is not null then
    insert into public.hdm_grow_outbox (action, grow_direct_debit_id, profile_id, reason)
    values ('cancel_direct_debit', old.grow_direct_debit_id, old.profile_id,
            coalesce(nullif(current_setting('hdm.cancel_reason', true), ''), 'canceled'))
    on conflict do nothing;
  end if;
  return new;
end $$;
create trigger hdm_subscriptions_billing_guard
  before update or delete on public.hdm_subscriptions
  for each row execute function public.hdm_subscriptions_billing_guard();

-- ---------------------------------------------------------------------
-- 4. פונקציות לאפליקציה (משתמש מחובר שאישר את התנאים)
-- ---------------------------------------------------------------------
-- מצב המנוי שלי: תאריך החיוב הבא, אפשרות ביטול, תנאי החידוש
create function public.hdm_billing_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me text := public.hdm_require_me();
  s  public.hdm_subscriptions%rowtype;
  pl text := public.hdm_plan_of(me);
  ck public.hdm_checkouts%rowtype;
  paid boolean;
begin
  select * into s from public.hdm_subscriptions where profile_id = me;
  select * into ck from public.hdm_checkouts where profile_id = me and status = 'pending' and expires_at > now();
  paid := s.profile_id is not null and s.source = 'payment' and pl <> 'free';
  return jsonb_build_object(
    'plan',            pl,
    'paid',            paid,                                         -- מנוי בתשלום (לא מסלול שהוגדר ידנית)
    'status',          case when pl = 'free' then 'none' else s.status end,
    'autoRenew',       paid and s.auto_renew,
    'nextChargeAt',    case when paid and s.auto_renew then s.current_period_end end,
    'nextChargeAgorot', case when paid and s.auto_renew then (select price_agorot from public.hdm_plans where plan = s.plan) end,
    'activeUntil',     case when pl <> 'free' then s.current_period_end end,
    'canCancel',       paid and s.auto_renew,
    'paymentFailed',   paid and s.status = 'past_due',
    'pendingCheckout', ck.id is not null,
    'termsVersion',    public.hdm_billing_current_terms(),
    'termsText',       (select summary_he from public.hdm_billing_terms_versions where version = public.hdm_billing_current_terms()));
end $$;

-- פתיחת ניסיון תשלום, אחרי שהלקוח ראה ואישר את תנאי החידוש. לא מחייב כלום.
create function public.hdm_billing_start_checkout(p_plan text, p_terms_version text, p_accept boolean)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me  text := public.hdm_require_me();
  uid uuid := auth.uid();
  s   public.hdm_subscriptions%rowtype;
  ck  public.hdm_checkouts%rowtype;
  price int;
begin
  if p_plan not in ('basic', 'plus', 'vip') then
    raise exception 'HDM_BILLING_PLAN' using errcode = 'P0001', hint = 'מסלול לא מוכר.';
  end if;
  if p_accept is not true then
    raise exception 'HDM_BILLING_TERMS_REQUIRED' using errcode = 'P0001', hint = 'יש לאשר את תנאי החידוש לפני התשלום.';
  end if;
  if p_terms_version is distinct from public.hdm_billing_current_terms() then
    raise exception 'HDM_BILLING_TERMS_VERSION' using errcode = 'P0001', hint = 'תנאי החידוש עודכנו. יש לקרוא ולאשר שוב.';
  end if;
  perform pg_advisory_xact_lock(hashtext('hdm_billing:' || me));

  select * into s from public.hdm_subscriptions where profile_id = me;
  if s.profile_id is not null and s.source = 'payment' and public.hdm_plan_of(me) <> 'free' then
    if s.auto_renew then
      raise exception 'HDM_BILLING_ALREADY_SUBSCRIBED' using errcode = 'P0001', hint = 'כבר יש לך מנוי פעיל.';
    end if;
    raise exception 'HDM_BILLING_STILL_ACTIVE' using errcode = 'P0001',
      hint = 'המנוי שביטלת בתוקף עד ' || to_char(s.current_period_end at time zone 'Asia/Jerusalem', 'DD.MM.YYYY')
             || '. אפשר להצטרף מחדש אחרי תאריך זה.';
  end if;

  update public.hdm_checkouts set status = 'expired', closed_at = now()
   where profile_id = me and status = 'pending' and expires_at <= now();
  select * into ck from public.hdm_checkouts where profile_id = me and status = 'pending';
  if ck.id is not null then
    if ck.plan = p_plan then
      return jsonb_build_object('checkoutId', ck.id, 'plan', ck.plan, 'amountAgorot', ck.amount_agorot, 'reused', true);
    end if;
    raise exception 'HDM_BILLING_PENDING' using errcode = 'P0001',
      hint = 'יש תשלום שעדיין בתהליך. אפשר לנסות שוב בעוד כמה דקות.';
  end if;

  select price_agorot into price from public.hdm_plans where plan = p_plan;
  insert into public.hdm_checkouts (user_id, profile_id, plan, amount_agorot, terms_version)
  values (uid, me, p_plan, price, p_terms_version)
  returning * into ck;
  return jsonb_build_object('checkoutId', ck.id, 'plan', ck.plan, 'amountAgorot', ck.amount_agorot, 'reused', false);
end $$;

-- ביטול על ידי הלקוח: עוצר את החידוש, המנוי בתוקף עד סוף התקופה ששולמה
create function public.hdm_billing_cancel()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me text := public.hdm_require_me();
  s  public.hdm_subscriptions%rowtype;
begin
  perform pg_advisory_xact_lock(hashtext('hdm_billing:' || me));
  select * into s from public.hdm_subscriptions where profile_id = me for update;
  if s.profile_id is null or s.source <> 'payment' or public.hdm_plan_of(me) = 'free' then
    raise exception 'HDM_BILLING_NOTHING_TO_CANCEL' using errcode = 'P0001', hint = 'אין מנוי בתשלום לביטול.';
  end if;
  if not s.auto_renew then
    return jsonb_build_object('canceled', true, 'already', true, 'activeUntil', s.current_period_end);
  end if;
  perform set_config('hdm.cancel_reason', 'customer', true);
  update public.hdm_subscriptions
     set status = 'canceled', auto_renew = false, canceled_at = now(), updated_at = now()
   where profile_id = me;
  perform set_config('hdm.cancel_reason', '', true);
  insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan, note)
  values (me, 'cancel', s.plan, s.plan, 'ביטול על ידי הלקוח מתוך האפליקציה');
  return jsonb_build_object('canceled', true, 'already', false, 'activeUntil', s.current_period_end);
end $$;

-- ---------------------------------------------------------------------
-- 5. פונקציות שרת בלבד (service_role) — יופעלו רק מ-Edge Function אחרי אימות מול Grow
-- ---------------------------------------------------------------------
-- קישור דף התשלום של Grow לניסיון התשלום
create function public.hdm_billing_attach_process(p_checkout uuid, p_process_id text)
returns void language sql volatile security definer set search_path = '' as $$
  update public.hdm_checkouts set grow_process_id = p_process_id
   where id = p_checkout and status = 'pending' and grow_process_id is null
$$;

-- קליטת אירוע תשלום מאומת. בטוח להפעלה חוזרת: אותו מזהה עסקה נקלט פעם אחת בלבד.
-- p: { transactionId, kind: initial|renewal, outcome: approved|failed, amountAgorot, checkoutId?, directDebitId?, raw? }
create function public.hdm_billing_apply_grow_event(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  tx      text := nullif(p->>'transactionId', '');
  kind    text := p->>'kind';
  outcome text := p->>'outcome';
  amt     int  := (p->>'amountAgorot')::int;
  dd      text := nullif(p->>'directDebitId', '');
  ckid    uuid := nullif(p->>'checkoutId', '')::uuid;
  pay_id  bigint;
  ck      public.hdm_checkouts%rowtype;
  s       public.hdm_subscriptions%rowtype;
  me      text;
  cur     text;
  res     text;
  review  boolean := false;
  new_end timestamptz;
  price   int;
begin
  if tx is null or kind not in ('initial', 'renewal') or outcome not in ('approved', 'failed') then
    raise exception 'HDM_BILLING_BAD_EVENT' using errcode = 'P0001';
  end if;

  insert into public.hdm_payments (grow_transaction_id, kind, outcome, result, checkout_id, grow_direct_debit_id, amount_agorot, raw)
  values (tx, kind, outcome, 'received', ckid, dd, amt, coalesce(p->'raw', '{}'::jsonb))
  on conflict (grow_transaction_id) do nothing
  returning id into pay_id;
  if pay_id is null then
    return jsonb_build_object('result', 'already_processed');   -- אותו אירוע הגיע שוב — לא עושים כלום
  end if;

  perform set_config('hdm.billing_event', 'on', true);

  if kind = 'initial' then
    select * into ck from public.hdm_checkouts where id = ckid for update;
    if ck.id is null then
      res := 'unknown'; review := outcome = 'approved';
    else
      me := ck.profile_id;
      perform pg_advisory_xact_lock(hashtext('hdm_billing:' || me));
      if outcome = 'failed' then
        if ck.status = 'pending' then update public.hdm_checkouts set status = 'failed', closed_at = now() where id = ck.id; end if;
        res := 'failed';
      elsif ck.status = 'paid' then
        res := 'duplicate'; review := true;                    -- תשלום שני לאותו ניסיון — להחזיר
      elsif amt is distinct from ck.amount_agorot then
        res := 'amount_mismatch'; review := true;
      else
        select * into s from public.hdm_subscriptions where profile_id = me for update;
        if s.profile_id is not null and s.source = 'payment' and s.auto_renew and public.hdm_plan_of(me) <> 'free' then
          res := 'duplicate'; review := true;                  -- כבר יש מנוי בתשלום פעיל — לא מאריכים, להחזיר
        else
          cur := public.hdm_plan_of(me);
          new_end := public.hdm_billing_add_months(now(), 1);
          insert into public.hdm_subscriptions as x (profile_id, plan, status, period_anchor, current_period_end, source,
                                                      auto_renew, grow_direct_debit_id, failed_attempts, last_payment_at, note)
          values (me, ck.plan, 'active', now(), new_end, 'payment', true, dd, 0, now(), 'Grow')
          on conflict (profile_id) do update set
            plan = excluded.plan, status = 'active', period_anchor = excluded.period_anchor,
            current_period_end = excluded.current_period_end, canceled_at = null, source = 'payment',
            auto_renew = true, grow_direct_debit_id = excluded.grow_direct_debit_id, failed_attempts = 0,
            last_payment_at = now(), updated_at = now();
          update public.hdm_checkouts set status = 'paid', closed_at = now() where id = ck.id;
          insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan, note)
          values (me, 'start', cur, ck.plan, 'תשלום מאושר ב-Grow ' || tx);
          res := 'started';
        end if;
      end if;
    end if;

  else  -- renewal
    select * into s from public.hdm_subscriptions where grow_direct_debit_id = dd for update;
    if s.profile_id is null then
      res := 'unknown'; review := outcome = 'approved';
    else
      me := s.profile_id;
      perform pg_advisory_xact_lock(hashtext('hdm_billing:' || me));
      select price_agorot into price from public.hdm_plans where plan = s.plan;
      if outcome = 'failed' then
        if s.auto_renew then
          update public.hdm_subscriptions
             set status = 'past_due', failed_attempts = failed_attempts + 1, updated_at = now()
           where profile_id = me;
          insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan, note)
          values (me, 'payment_failed', s.plan, s.plan, 'חיוב חידוש נכשל ' || tx);
          if s.failed_attempts + 1 >= 3 then              -- אחרי 3 כישלונות: מפסיקים לנסות
            perform set_config('hdm.cancel_reason', 'payment_failed', true);
            update public.hdm_subscriptions set auto_renew = false, updated_at = now() where profile_id = me;
            insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan, note)
            values (me, 'renewal_stopped', s.plan, s.plan, '3 חיובים נכשלו — החידוש הופסק');
          end if;
        end if;
        res := 'failed';
      elsif not s.auto_renew then
        res := 'after_cancel'; review := true;                 -- חיוב אחרי ביטול — להחזיר ולוודא שהוראת הקבע בוטלה
        insert into public.hdm_grow_outbox (action, grow_direct_debit_id, profile_id, reason)
        values ('cancel_direct_debit', dd, me, 'charged_after_cancel') on conflict do nothing;
      elsif amt is distinct from price then
        res := 'amount_mismatch'; review := true;
      elsif s.current_period_end > now() + interval '7 days' then
        res := 'duplicate'; review := true;                    -- התקופה כבר שולמה — לא מאריכים, להחזיר
      else
        new_end := public.hdm_billing_next_after(s.period_anchor, greatest(now(), coalesce(s.current_period_end, now())));
        update public.hdm_subscriptions
           set status = 'active', current_period_end = new_end, failed_attempts = 0,
               last_payment_at = now(), updated_at = now()
         where profile_id = me;
        insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan, note)
        values (me, 'renew', s.plan, s.plan, 'חידוש מאושר ב-Grow ' || tx);
        res := 'renewed';
      end if;
    end if;
  end if;

  perform set_config('hdm.billing_event', '', true);
  perform set_config('hdm.cancel_reason', '', true);
  update public.hdm_payments
     set result = res, needs_review = review, profile_id = me,
         plan = coalesce(ck.plan, s.plan), period_end_after = new_end
   where id = pay_id;
  return jsonb_build_object('result', res, 'needsReview', review, 'profileId', me, 'periodEnd', new_end);
end $$;

-- פעולות פתוחות מול Grow, וסימון שבוצעו
create function public.hdm_billing_outbox_pending()
returns setof public.hdm_grow_outbox language sql stable security definer set search_path = '' as $$
  select * from public.hdm_grow_outbox where done_at is null order by id
$$;
create function public.hdm_billing_outbox_done(p_id bigint, p_ok boolean, p_error text default null)
returns void language sql volatile security definer set search_path = '' as $$
  update public.hdm_grow_outbox
     set attempts = attempts + 1, last_error = case when p_ok then null else p_error end,
         done_at = case when p_ok then now() end
   where id = p_id and done_at is null
$$;

-- ---------------------------------------------------------------------
-- 6. הרשאות
-- ---------------------------------------------------------------------
revoke all on function
  public.hdm_billing_add_months(timestamptz, int), public.hdm_billing_next_after(timestamptz, timestamptz),
  public.hdm_billing_current_terms(), public.hdm_subscriptions_billing_guard(),
  public.hdm_billing_status(), public.hdm_billing_start_checkout(text, text, boolean), public.hdm_billing_cancel(),
  public.hdm_billing_attach_process(uuid, text), public.hdm_billing_apply_grow_event(jsonb),
  public.hdm_billing_outbox_pending(), public.hdm_billing_outbox_done(bigint, boolean, text)
  from public, anon, authenticated;
grant execute on function
  public.hdm_billing_status(), public.hdm_billing_start_checkout(text, text, boolean), public.hdm_billing_cancel()
  to authenticated;
grant execute on function
  public.hdm_billing_attach_process(uuid, text), public.hdm_billing_apply_grow_event(jsonb),
  public.hdm_billing_outbox_pending(), public.hdm_billing_outbox_done(bigint, boolean, text)
  to service_role;
-- ===== BILLING END =====

-- ===================== 19_staging_billing_upgrade.sql (ללא שינוי) =====================
-- ===== BILLING UPGRADE START =====
-- ---------------------------------------------------------------------
-- 1. טבלאות ושדות
-- ---------------------------------------------------------------------
-- grow_direct_debit_id מכיל במודל הזה את recurringDebitId של Grow (מזהה סדרת החיובים בכרטיס השמור)
comment on column public.hdm_subscriptions.grow_direct_debit_id is 'Grow recurringDebitId (token model) / directDebitId';

-- ה-Token של הכרטיס ב-Grow (לא מספר כרטיס). קריאה רק לפונקציית השרת. נמחק במחיקת חשבון.
create table public.hdm_billing_tokens (
  profile_id  text primary key,
  grow_token  text not null,
  card_last4  text check (card_last4 ~ '^[0-9]{4}$'),
  updated_at  timestamptz not null default now()
);

-- ניסיון תשלום יכול להיות הצטרפות או שדרוג
alter table public.hdm_checkouts
  add column kind              text not null default 'initial' check (kind in ('initial', 'upgrade')),
  add column from_plan         text references public.hdm_plans(plan),
  add column quoted_period_end timestamptz;          -- סוף התקופה שעליה חושב החיוב היחסי
alter table public.hdm_payments drop constraint if exists hdm_payments_kind_check;
alter table public.hdm_payments add constraint hdm_payments_kind_check check (kind in ('initial', 'renewal', 'upgrade'));

-- חיובי חידוש שהשרת שלנו מבצע בכרטיס השמור: חיוב אחד בתהליך/מאושר לכל תקופה
create table public.hdm_renewal_charges (
  id          uuid primary key default gen_random_uuid(),
  profile_id  text not null,
  period_end  timestamptz not null,        -- התקופה שמחדשים (current_period_end בזמן החיוב)
  attempt     int  not null,
  amount_agorot int not null,
  status      text not null default 'pending' check (status in ('pending', 'approved', 'failed', 'review')),
  created_at  timestamptz not null default now(),
  closed_at   timestamptz,
  unique (profile_id, period_end, attempt)
);
create unique index hdm_renewal_one_live on public.hdm_renewal_charges (profile_id, period_end)
  where status in ('pending', 'approved', 'review');

alter table public.hdm_billing_tokens  enable row level security;
alter table public.hdm_renewal_charges enable row level security;
revoke all on public.hdm_billing_tokens, public.hdm_renewal_charges from public, anon, authenticated;

-- מחיקת חשבון: מוחקת גם את ה-Token (תשלומים נשמרים לתיעוד)
create function public.hdm_billing_token_cleanup()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from public.hdm_billing_tokens where profile_id = old.profile_id;
  return old;
end $$;
create trigger hdm_billing_token_cleanup after delete on public.hdm_accounts
  for each row execute function public.hdm_billing_token_cleanup();

-- ---------------------------------------------------------------------
-- 2. חישוב יחסי
-- ---------------------------------------------------------------------
-- תחילת התקופה הנוכחית (החודש שמסתיים ב-period_end)
create function public.hdm_billing_period_start(anchor timestamptz, period_end timestamptz)
returns timestamptz language plpgsql immutable set search_path = '' as $$
declare k int := 1;
begin
  loop
    exit when public.hdm_billing_add_months(anchor, k) >= period_end;
    k := k + 1;
    if k > 1200 then raise exception 'hdm_billing_period_start: out of range'; end if;
  end loop;
  return public.hdm_billing_add_months(anchor, k - 1);
end $$;

-- החיוב היחסי לשדרוג: (מחיר חדש − מחיר נוכחי) × (זמן שנותר ÷ אורך התקופה), מעוגל לאגורה
create function public.hdm_billing_proration(p_from text, p_to text, anchor timestamptz, period_end timestamptz, at_time timestamptz default now())
returns int language plpgsql stable security definer set search_path = '' as $$
declare
  diff  int := (select price_agorot from public.hdm_plans where plan = p_to) - (select price_agorot from public.hdm_plans where plan = p_from);
  ps    timestamptz := public.hdm_billing_period_start(anchor, period_end);
  total numeric := extract(epoch from (period_end - ps));
  left_ numeric := greatest(extract(epoch from (period_end - at_time)), 0);
begin
  if diff <= 0 or total <= 0 then return 0; end if;
  return round(diff * least(left_ / total, 1))::int;
end $$;

-- ---------------------------------------------------------------------
-- 3. לאפליקציה: הצעת מחיר לשדרוג ופתיחת תשלום שדרוג
-- ---------------------------------------------------------------------
create function public.hdm_billing_upgrade_quote(p_plan text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me text := public.hdm_require_me();
  s  public.hdm_subscriptions%rowtype;
  amt int;
begin
  select * into s from public.hdm_subscriptions where profile_id = me;
  if s.profile_id is null or s.source <> 'payment' or not s.auto_renew or s.status <> 'active'
     or s.current_period_end is null or s.current_period_end <= now() then
    raise exception 'HDM_BILLING_UPGRADE_NA' using errcode = 'P0001', hint = 'שדרוג זמין למנוי פעיל בתשלום.';
  end if;
  if (select sort_order from public.hdm_plans where plan = p_plan) is null
     or (select sort_order from public.hdm_plans where plan = p_plan) <= (select sort_order from public.hdm_plans where plan = s.plan) then
    raise exception 'HDM_BILLING_UPGRADE_PLAN' using errcode = 'P0001', hint = 'אפשר לשדרג רק למסלול גבוה יותר.';
  end if;
  amt := public.hdm_billing_proration(s.plan, p_plan, s.period_anchor, s.current_period_end);
  return jsonb_build_object(
    'fromPlan', s.plan, 'toPlan', p_plan,
    'chargeNowAgorot', amt,
    'periodEnd', s.current_period_end,
    'nextChargeAt', s.current_period_end,
    'nextChargeAgorot', (select price_agorot from public.hdm_plans where plan = p_plan),
    'termsVersion', public.hdm_billing_current_terms());
end $$;

create function public.hdm_billing_start_upgrade(p_plan text, p_terms_version text, p_accept boolean, p_quoted_agorot int)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me  text := public.hdm_require_me();
  uid uuid := auth.uid();
  q   jsonb;
  ck  public.hdm_checkouts%rowtype;
  s   public.hdm_subscriptions%rowtype;
begin
  if p_accept is not true then
    raise exception 'HDM_BILLING_TERMS_REQUIRED' using errcode = 'P0001', hint = 'יש לאשר את תנאי השדרוג והחידוש לפני התשלום.';
  end if;
  if p_terms_version is distinct from public.hdm_billing_current_terms() then
    raise exception 'HDM_BILLING_TERMS_VERSION' using errcode = 'P0001', hint = 'תנאי החידוש עודכנו. יש לקרוא ולאשר שוב.';
  end if;
  perform pg_advisory_xact_lock(hashtext('hdm_billing:' || me));
  q := public.hdm_billing_upgrade_quote(p_plan);
  -- הסכום שהלקוח ראה ואישר חייב להיות הסכום שיחויב (סטייה של עד 10 אגורות בגלל זמן שעבר — לטובת הלקוח)
  if p_quoted_agorot is null or (q->>'chargeNowAgorot')::int > p_quoted_agorot or p_quoted_agorot - (q->>'chargeNowAgorot')::int > 10 then
    raise exception 'HDM_BILLING_QUOTE_CHANGED' using errcode = 'P0001', hint = 'הסכום עודכן. יש לבדוק את הסכום החדש ולאשר שוב.';
  end if;
  select * into s from public.hdm_subscriptions where profile_id = me;

  update public.hdm_checkouts set status = 'expired', closed_at = now()
   where profile_id = me and status = 'pending' and expires_at <= now();
  if exists (select 1 from public.hdm_checkouts where profile_id = me and status = 'pending') then
    raise exception 'HDM_BILLING_PENDING' using errcode = 'P0001', hint = 'יש תשלום שעדיין בתהליך. אפשר לנסות שוב בעוד כמה דקות.';
  end if;
  if exists (select 1 from public.hdm_renewal_charges where profile_id = me and status = 'pending') then
    raise exception 'HDM_BILLING_PENDING' using errcode = 'P0001', hint = 'מתבצע עכשיו חיוב חידוש. אפשר לשדרג בעוד כמה דקות.';
  end if;

  -- סכום קטן מ-₪1 (השעות האחרונות של התקופה): השדרוג מופעל בלי חיוב, והמחיר החדש חל מהחידוש הבא
  if (q->>'chargeNowAgorot')::int < 100 then
    perform set_config('hdm.billing_event', 'on', true);
    update public.hdm_subscriptions set plan = p_plan, updated_at = now() where profile_id = me;
    perform set_config('hdm.billing_event', '', true);
    insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan, note)
    values (me, 'upgrade', s.plan, p_plan, 'שדרוג בלי חיוב (יתרה קטנה מ-₪1)');
    return jsonb_build_object('upgraded', true, 'charged', false, 'plan', p_plan);
  end if;

  insert into public.hdm_checkouts (user_id, profile_id, plan, amount_agorot, terms_version, kind, from_plan, quoted_period_end)
  values (uid, me, p_plan, (q->>'chargeNowAgorot')::int, p_terms_version, 'upgrade', s.plan, s.current_period_end)
  returning * into ck;
  return jsonb_build_object('upgraded', false, 'checkoutId', ck.id, 'plan', ck.plan, 'amountAgorot', ck.amount_agorot);
end $$;

-- ---------------------------------------------------------------------
-- 4. לפונקציית השרת בלבד: Token, חידושים שהגיע מועדם, קליטת תוצאות
-- ---------------------------------------------------------------------
create function public.hdm_billing_save_token(p_profile text, p_token text, p_last4 text default null)
returns void language sql volatile security definer set search_path = '' as $$
  insert into public.hdm_billing_tokens (profile_id, grow_token, card_last4) values (p_profile, p_token, p_last4)
  on conflict (profile_id) do update set grow_token = excluded.grow_token, card_last4 = excluded.card_last4, updated_at = now()
$$;

-- "תפיסת" החידושים שהגיע מועדם. כל מנוי מקבל לכל היותר חיוב אחד בתהליך/מאושר לכל תקופה.
-- ניסיון חוזר אחרי כישלון: עד 3 ניסיונות, לפחות 48 שעות ביניהם. חיוב "בתהליך" שלא קיבל תשובה — לא מנסים שוב
-- אוטומטית (ייתכן שהלקוח חויב); מסמנים לבדיקה ידנית.
create function public.hdm_billing_claim_due_renewals(p_limit int default 50)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  r   record;
  out jsonb := '[]'::jsonb;
  att int;
  last_fail timestamptz;
  ch  public.hdm_renewal_charges%rowtype;
begin
  update public.hdm_renewal_charges set status = 'review', closed_at = now()
   where status = 'pending' and created_at < now() - interval '2 hours';

  for r in
    select s.profile_id, s.plan, s.current_period_end, s.grow_direct_debit_id, p.price_agorot
      from public.hdm_subscriptions s join public.hdm_plans p on p.plan = s.plan
     where s.source = 'payment' and s.auto_renew and s.status in ('active', 'past_due')
       and s.current_period_end <= now()
       and s.current_period_end > now() - interval '7 days'
       and exists (select 1 from public.hdm_billing_tokens t where t.profile_id = s.profile_id)
     order by s.current_period_end
     limit p_limit
     for update of s skip locked
  loop
    continue when exists (select 1 from public.hdm_renewal_charges c
                           where c.profile_id = r.profile_id and c.period_end = r.current_period_end
                             and c.status in ('pending', 'approved', 'review'));
    select count(*), max(closed_at) into att, last_fail from public.hdm_renewal_charges c
     where c.profile_id = r.profile_id and c.period_end = r.current_period_end and c.status = 'failed';
    continue when att >= 3 or (last_fail is not null and last_fail > now() - interval '48 hours');
    insert into public.hdm_renewal_charges (profile_id, period_end, attempt, amount_agorot)
    values (r.profile_id, r.current_period_end, att + 1, r.price_agorot)
    returning * into ch;
    out := out || jsonb_build_object('chargeId', ch.id, 'profileId', r.profile_id, 'amountAgorot', ch.amount_agorot,
                                     'recurringDebitId', r.grow_direct_debit_id, 'attempt', ch.attempt,
                                     'token', (select grow_token from public.hdm_billing_tokens where profile_id = r.profile_id));
  end loop;
  return out;
end $$;

-- קליטת אירוע מאומת מ-Grow: מוסיף "upgrade" ו-"renewal" שמזוהה לפי chargeId; כל השאר — כמו ב-17
alter function public.hdm_billing_apply_grow_event(jsonb) rename to hdm_billing_apply_grow_event_v1;
revoke all on function public.hdm_billing_apply_grow_event_v1(jsonb) from public, anon, authenticated, service_role;

create function public.hdm_billing_apply_grow_event(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  tx      text := nullif(p->>'transactionId', '');
  ev_kind text := p->>'kind';
  outcome text := p->>'outcome';
  amt     int  := (p->>'amountAgorot')::int;
  ckid    uuid := nullif(p->>'checkoutId', '')::uuid;
  chid    uuid := nullif(p->>'chargeId', '')::uuid;
  pay_id  bigint;
  ck      public.hdm_checkouts%rowtype;
  ch      public.hdm_renewal_charges%rowtype;
  s       public.hdm_subscriptions%rowtype;
  res     text;
  review  boolean := false;
  out     jsonb;
begin
  -- חידוש בכרטיס שמור: מזהים את המנוי לפי החיוב שהשרת תפס, ומעבירים לטיפול הקיים
  if ev_kind = 'renewal' and chid is not null then
    select * into ch from public.hdm_renewal_charges where id = chid for update;
    if ch.id is null then
      raise exception 'HDM_BILLING_BAD_EVENT' using errcode = 'P0001';
    end if;
    select * into s from public.hdm_subscriptions where profile_id = ch.profile_id;
    if amt is distinct from ch.amount_agorot then
      p := p || jsonb_build_object('amountAgorot', amt);    -- הבדיקה ב-v1 תסמן amount_mismatch
    end if;
    out := public.hdm_billing_apply_grow_event_v1(p || jsonb_build_object('directDebitId', s.grow_direct_debit_id));
    if out->>'result' <> 'already_processed' then
      update public.hdm_renewal_charges
         set status = case when out->>'result' = 'renewed' then 'approved'
                           when out->>'result' = 'failed' then 'failed' else 'review' end,
             closed_at = now()
       where id = chid and status in ('pending', 'review');
    end if;
    return out;
  end if;

  if ev_kind is distinct from 'upgrade' then
    return public.hdm_billing_apply_grow_event_v1(p);
  end if;

  -- ---- שדרוג ----
  if tx is null or outcome not in ('approved', 'failed') then
    raise exception 'HDM_BILLING_BAD_EVENT' using errcode = 'P0001';
  end if;
  insert into public.hdm_payments (grow_transaction_id, kind, outcome, result, checkout_id, amount_agorot, raw)
  values (tx, 'upgrade', outcome, 'received', ckid, amt, coalesce(p->'raw', '{}'::jsonb))
  on conflict (grow_transaction_id) do nothing
  returning id into pay_id;
  if pay_id is null then
    return jsonb_build_object('result', 'already_processed');
  end if;

  select * into ck from public.hdm_checkouts where id = ckid and kind = 'upgrade' for update;
  if ck.id is null then
    res := 'unknown'; review := outcome = 'approved';
  else
    perform pg_advisory_xact_lock(hashtext('hdm_billing:' || ck.profile_id));
    select * into s from public.hdm_subscriptions where profile_id = ck.profile_id for update;
    if outcome = 'failed' then
      if ck.status = 'pending' then update public.hdm_checkouts set status = 'failed', closed_at = now() where id = ck.id; end if;
      res := 'failed';                                         -- המסלול לא משתנה
    elsif ck.status = 'paid' then
      res := 'duplicate'; review := true;
    elsif amt is distinct from ck.amount_agorot then
      res := 'amount_mismatch'; review := true;
    elsif s.profile_id is null or s.plan <> ck.from_plan or s.current_period_end is distinct from ck.quoted_period_end
          or s.current_period_end <= now() then
      res := 'stale'; review := true;                          -- המנוי השתנה מאז ההצעה — לא משדרגים, להחזר
    else
      perform set_config('hdm.billing_event', 'on', true);
      update public.hdm_subscriptions set plan = ck.plan, last_payment_at = now(), updated_at = now()
       where profile_id = ck.profile_id;                       -- תאריך החיוב (period_anchor / current_period_end) לא משתנה
      perform set_config('hdm.billing_event', '', true);
      update public.hdm_checkouts set status = 'paid', closed_at = now() where id = ck.id;
      insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan, note)
      values (ck.profile_id, 'upgrade', ck.from_plan, ck.plan, 'שדרוג בחיוב יחסי, מאושר ב-Grow ' || tx);
      res := 'upgraded';
    end if;
  end if;
  update public.hdm_payments set result = res, needs_review = review, profile_id = ck.profile_id, plan = ck.plan
   where id = pay_id;
  return jsonb_build_object('result', res, 'needsReview', review, 'profileId', ck.profile_id);
end $$;

-- ---------------------------------------------------------------------
-- 5. הרשאות
-- ---------------------------------------------------------------------
revoke all on function
  public.hdm_billing_token_cleanup(), public.hdm_billing_period_start(timestamptz, timestamptz),
  public.hdm_billing_proration(text, text, timestamptz, timestamptz, timestamptz),
  public.hdm_billing_upgrade_quote(text), public.hdm_billing_start_upgrade(text, text, boolean, int),
  public.hdm_billing_save_token(text, text, text), public.hdm_billing_claim_due_renewals(int),
  public.hdm_billing_apply_grow_event(jsonb)
  from public, anon, authenticated;
grant execute on function public.hdm_billing_upgrade_quote(text), public.hdm_billing_start_upgrade(text, text, boolean, int)
  to authenticated;
grant execute on function public.hdm_billing_save_token(text, text, text), public.hdm_billing_claim_due_renewals(int),
  public.hdm_billing_apply_grow_event(jsonb)
  to service_role;
-- ===== BILLING UPGRADE END =====

-- ===================== 21_staging_billing_cancel.sql (ללא שינוי) =====================
-- ===== BILLING CANCEL START =====
-- ---------------------------------------------------------------------
-- 1. טבלאות
-- ---------------------------------------------------------------------
alter table public.hdm_grow_outbox add column needs_review boolean not null default false;

-- בקשת ביטול: תיעוד מועד הבקשה, מצב האישור מול Grow ובקשת החזר
create table public.hdm_cancel_requests (
  id               uuid primary key default gen_random_uuid(),
  profile_id       text not null,
  user_id          uuid,
  plan             text not null,
  source           text not null default 'app' check (source in ('app', 'admin', 'email')),
  requested_at     timestamptz not null default now(),
  active_until     timestamptz,                         -- סוף התקופה ששולמה
  state            text not null check (state in ('pending', 'confirmed')),
  grow_required    boolean not null,                    -- היה צריך לבטל סדרת חיובים ב-Grow
  outbox_id        bigint references public.hdm_grow_outbox(id),
  confirmed_at     timestamptz,
  needs_review     boolean not null default false,      -- כשל חוזר מול Grow — טיפול ידני
  last_error       text,
  refund_eligible  boolean not null default false,      -- בתוך 14 יום מההצטרפות
  refund_requested boolean not null default false,
  refund_state     text check (refund_state in ('open', 'done', 'rejected'))
);
create index hdm_cancel_requests_profile on public.hdm_cancel_requests (profile_id, requested_at desc);
create unique index hdm_cancel_requests_outbox on public.hdm_cancel_requests (outbox_id) where outbox_id is not null;

-- תור מיילים ללקוח (ביטול). הכתובת נלקחת מהחשבון בזמן השליחה — לא נשמרת כאן.
create table public.hdm_email_outbox (
  id           bigint generated always as identity primary key,
  user_id      uuid not null,
  profile_id   text,
  kind         text not null check (kind in ('cancel_received', 'cancel_confirmed')),
  ref_id       uuid not null,                           -- בקשת הביטול
  subject      text not null,
  body_text    text not null,
  created_at   timestamptz not null default now(),
  attempts     int not null default 0,
  last_error   text,
  sent_at      timestamptz,
  unique (kind, ref_id)                                 -- מייל אחד מכל סוג לכל בקשה
);

alter table public.hdm_cancel_requests enable row level security;
alter table public.hdm_email_outbox    enable row level security;
revoke all on public.hdm_cancel_requests, public.hdm_email_outbox from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. עזרים
-- ---------------------------------------------------------------------
create function public.hdm_plan_name_he(p text)
returns text language sql immutable set search_path = '' as $$
  select case p when 'basic' then 'בסיסי' when 'plus' then 'פלוס' when 'vip' then 'VIP' when 'free' then 'חינם' else p end
$$;

create function public.hdm_fmt_date_il(t timestamptz)
returns text language sql immutable set search_path = '' as $$
  select to_char(t at time zone 'Asia/Jerusalem', 'FMDD.FMMM.YYYY')
$$;

-- מכניס מייל ביטול לתור (פעם אחת לכל סוג ובקשה)
create function public.hdm_cancel_queue_email(p_req uuid, p_kind text)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare
  r     public.hdm_cancel_requests%rowtype;
  nm    text;
  subj  text;
  body  text;
  tail  text;
begin
  select * into r from public.hdm_cancel_requests where id = p_req;
  if r.id is null or r.user_id is null then return; end if;
  select coalesce(nullif(trim(data->>'currentName'), ''), '') into nm from public.docs
   where collection = 'profiles' and id = r.profile_id;
  tail := E'\n\nהמסלול יישאר פעיל עד ' || coalesce(public.hdm_fmt_date_il(r.active_until), 'סוף התקופה ששולמה')
       || E', ואחר כך החשבון יעבור אוטומטית למסלול החינמי.\n'
       || E'ביטול המנוי לא מוחק את החשבון, את הפרופיל, את ההתאמות או את השיחות.'
       || case when r.refund_requested
               then E'\n\nבקשת ההחזר הכספי שלך התקבלה, ותטופל לפי מדיניות ביטול המנוי, תוך 14 יום.' else '' end
       || E'\n\nלשאלות: life.through.numbers333@gmail.com\nחיים דרך מספרים';
  if p_kind = 'cancel_received' then
    subj := 'קיבלנו את בקשת ביטול המנוי — חיים דרך מספרים';
    body := 'שלום' || case when nm <> '' then ' ' || nm else '' end || E',\n\n'
         || 'קיבלנו את בקשתך לבטל את מנוי ' || public.hdm_plan_name_he(r.plan) || ' ב־' || public.hdm_fmt_date_il(r.requested_at) || E'.\n'
         || 'החידוש האוטומטי נעצר, ולא יתבצעו חיובים נוספים. הביטול ממתין לאישור סופי מספק הסליקה — '
         || 'נשלח אליך אישור נוסף כשיתקבל.' || tail;
  elsif p_kind = 'cancel_confirmed' then
    subj := 'אישור ביטול מנוי — חיים דרך מספרים';
    body := 'שלום' || case when nm <> '' then ' ' || nm else '' end || E',\n\n'
         || 'ביטול מנוי ' || public.hdm_plan_name_he(r.plan) || ' אושר. הבקשה התקבלה ב־' || public.hdm_fmt_date_il(r.requested_at)
         || E'.\nהמנוי לא יתחדש, ולא יתבצעו חיובים נוספים.' || tail;
  else
    raise exception 'hdm_cancel_queue_email: unknown kind %', p_kind;
  end if;
  insert into public.hdm_email_outbox (user_id, profile_id, kind, ref_id, subject, body_text)
  values (r.user_id, r.profile_id, p_kind, r.id, subj, body)
  on conflict (kind, ref_id) do nothing;
end $$;

-- ---------------------------------------------------------------------
-- 3. ביטול על ידי הלקוח
-- ---------------------------------------------------------------------
drop function public.hdm_billing_cancel();
create function public.hdm_billing_cancel(p_refund boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me   text := public.hdm_require_me();
  uid  uuid := auth.uid();
  s    public.hdm_subscriptions%rowtype;
  r    public.hdm_cancel_requests%rowtype;
  ob   bigint;
  elig boolean;
begin
  perform pg_advisory_xact_lock(hashtext('hdm_billing:' || me));
  select * into s from public.hdm_subscriptions where profile_id = me for update;
  if s.profile_id is null or s.source <> 'payment' or public.hdm_plan_of(me) = 'free' then
    raise exception 'HDM_BILLING_NOTHING_TO_CANCEL' using errcode = 'P0001', hint = 'אין מנוי בתשלום לביטול.';
  end if;
  if not s.auto_renew then          -- כבר בוטל (או שהחידוש נעצר) — לא כופלים
    select * into r from public.hdm_cancel_requests
     where profile_id = me and requested_at >= s.period_anchor order by requested_at desc limit 1;
    return jsonb_build_object('canceled', true, 'already', true, 'activeUntil', s.current_period_end,
                              'cancelState', coalesce(r.state, 'confirmed'), 'requestedAt', r.requested_at,
                              'refundRequested', coalesce(r.refund_requested, false));
  end if;

  elig := s.period_anchor > now() - interval '14 days';
  if p_refund and not elig then
    raise exception 'HDM_BILLING_REFUND_WINDOW' using errcode = 'P0001',
      hint = 'עברו יותר מ-14 יום מההצטרפות. הביטול עוצר את החידוש, והמסלול נשאר פעיל עד סוף התקופה ששולמה.';
  end if;

  -- עצירת החידוש: מכאן שום חיוב חידוש לא נתפס (hdm_billing_claim_due_renewals דורש auto_renew)
  perform set_config('hdm.cancel_reason', 'customer', true);
  update public.hdm_subscriptions
     set status = 'canceled', auto_renew = false, canceled_at = now(), updated_at = now()
   where profile_id = me;
  perform set_config('hdm.cancel_reason', '', true);

  -- הבקשה מול Grow נרשמת בתור על ידי hdm_subscriptions_billing_guard (17)
  if s.grow_direct_debit_id is not null then
    select id into ob from public.hdm_grow_outbox
     where action = 'cancel_direct_debit' and grow_direct_debit_id = s.grow_direct_debit_id and done_at is null
     order by id desc limit 1;
  end if;

  insert into public.hdm_cancel_requests (profile_id, user_id, plan, source, active_until, state, grow_required, outbox_id,
                                          confirmed_at, refund_eligible, refund_requested, refund_state)
  values (me, uid, s.plan, 'app', s.current_period_end,
          case when ob is null then 'confirmed' else 'pending' end, ob is not null, ob,
          case when ob is null then now() end, elig, coalesce(p_refund, false),
          case when p_refund then 'open' end)
  returning * into r;

  insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan, note)
  values (me, 'cancel', s.plan, s.plan,
          'ביטול על ידי הלקוח מתוך האפליקציה' || case when ob is null then '' else ' — ממתין לאישור Grow' end
          || case when p_refund then ' — התבקש החזר (14 יום)' else '' end);

  perform public.hdm_cancel_queue_email(r.id, case when r.state = 'pending' then 'cancel_received' else 'cancel_confirmed' end);

  return jsonb_build_object('canceled', true, 'already', false, 'activeUntil', s.current_period_end,
                            'cancelState', r.state, 'requestedAt', r.requested_at, 'refundRequested', r.refund_requested);
end $$;

-- ---------------------------------------------------------------------
-- 4. תוצאה מ-Grow (פונקציית השרת בלבד): מאשרת את הביטול רק אחרי תשובה חיובית
-- ---------------------------------------------------------------------
create or replace function public.hdm_billing_outbox_done(p_id bigint, p_ok boolean, p_error text default null)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare
  ob  public.hdm_grow_outbox%rowtype;
  rid uuid;
begin
  update public.hdm_grow_outbox
     set attempts = attempts + 1,
         last_error = case when p_ok then null else left(coalesce(p_error, 'error'), 500) end,
         done_at = case when p_ok then now() end,
         needs_review = case when p_ok then false else attempts + 1 >= 3 end
   where id = p_id and done_at is null
  returning * into ob;
  if ob.id is null then return; end if;                 -- כבר טופל — לא עושים כלום

  if p_ok then
    update public.hdm_cancel_requests
       set state = 'confirmed', confirmed_at = now(), needs_review = false, last_error = null
     where outbox_id = p_id and state = 'pending'
    returning id into rid;
    if rid is not null then
      insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan, note)
      select profile_id, 'cancel_confirmed', plan, plan, 'Grow אישרה את ביטול סדרת החיובים' from public.hdm_cancel_requests where id = rid;
      perform public.hdm_cancel_queue_email(rid, 'cancel_confirmed');
    end if;
  else
    update public.hdm_cancel_requests
       set needs_review = ob.needs_review, last_error = ob.last_error
     where outbox_id = p_id and state = 'pending';
  end if;
end $$;

-- בקשות ביטול שממתינות או נכשלו מול Grow — לטיפול מנהל (פונקציית שרת / לוח בקרה בעתיד)
create function public.hdm_billing_cancel_issues()
returns table (request_id uuid, profile_id text, plan text, requested_at timestamptz, attempts int,
               last_error text, needs_review boolean, refund_requested boolean, refund_state text)
language sql stable security definer set search_path = '' as $$
  select r.id, r.profile_id, r.plan, r.requested_at, coalesce(o.attempts, 0), coalesce(o.last_error, r.last_error),
         r.needs_review or coalesce(o.needs_review, false), r.refund_requested, r.refund_state
    from public.hdm_cancel_requests r left join public.hdm_grow_outbox o on o.id = r.outbox_id
   where r.state = 'pending' or r.needs_review or r.refund_state = 'open'
   order by r.requested_at
$$;

-- ---------------------------------------------------------------------
-- 5. תור המיילים (פונקציית השרת בלבד)
-- ---------------------------------------------------------------------
create function public.hdm_email_outbox_pending(p_limit int default 20)
returns table (id bigint, kind text, to_email text, subject text, body_text text, attempts int)
language sql stable security definer set search_path = '' as $$
  select e.id, e.kind, u.email::text, e.subject, e.body_text, e.attempts
    from public.hdm_email_outbox e join auth.users u on u.id = e.user_id
   where e.sent_at is null and e.attempts < 5
   order by e.id limit p_limit
$$;
create function public.hdm_email_outbox_done(p_id bigint, p_ok boolean, p_error text default null)
returns void language sql volatile security definer set search_path = '' as $$
  update public.hdm_email_outbox
     set attempts = attempts + 1, sent_at = case when p_ok then now() end,
         last_error = case when p_ok then null else left(coalesce(p_error, 'error'), 500) end
   where id = p_id and sent_at is null
$$;

-- ---------------------------------------------------------------------
-- 6. מצב המנוי שלי: מוסיף את מצב הביטול ואת זכאות ההחזר
-- ---------------------------------------------------------------------
create or replace function public.hdm_billing_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me text := public.hdm_require_me();
  s  public.hdm_subscriptions%rowtype;
  pl text := public.hdm_plan_of(me);
  ck public.hdm_checkouts%rowtype;
  r  public.hdm_cancel_requests%rowtype;
  paid boolean;
begin
  select * into s from public.hdm_subscriptions where profile_id = me;
  select * into ck from public.hdm_checkouts where profile_id = me and status = 'pending' and expires_at > now();
  paid := s.profile_id is not null and s.source = 'payment' and pl <> 'free';
  if paid and not s.auto_renew then
    select * into r from public.hdm_cancel_requests
     where profile_id = me and requested_at >= s.period_anchor order by requested_at desc limit 1;
  end if;
  return jsonb_build_object(
    'plan',            pl,
    'paid',            paid,
    'status',          case when pl = 'free' then 'none' else s.status end,
    'autoRenew',       paid and s.auto_renew,
    'nextChargeAt',    case when paid and s.auto_renew then s.current_period_end end,
    'nextChargeAgorot', case when paid and s.auto_renew then (select price_agorot from public.hdm_plans where plan = s.plan) end,
    'activeUntil',     case when pl <> 'free' then s.current_period_end end,
    'canCancel',       paid and s.auto_renew,
    'refundEligible',  paid and s.auto_renew and s.period_anchor > now() - interval '14 days',
    'refundUntil',     case when paid and s.auto_renew and s.period_anchor > now() - interval '14 days' then s.period_anchor + interval '14 days' end,
    'paymentFailed',   paid and s.status = 'past_due',
    'cancel',          case when r.id is null then null else jsonb_build_object(
                         'state', r.state, 'requestedAt', r.requested_at, 'confirmedAt', r.confirmed_at,
                         'activeUntil', r.active_until, 'delayed', r.needs_review,
                         'refundRequested', r.refund_requested, 'refundState', r.refund_state) end,
    'pendingCheckout', ck.id is not null,
    'termsVersion',    public.hdm_billing_current_terms(),
    'termsText',       (select summary_he from public.hdm_billing_terms_versions where version = public.hdm_billing_current_terms()));
end $$;

-- ---------------------------------------------------------------------
-- 7. הרשאות
-- ---------------------------------------------------------------------
revoke all on function
  public.hdm_plan_name_he(text), public.hdm_fmt_date_il(timestamptz), public.hdm_cancel_queue_email(uuid, text),
  public.hdm_billing_cancel(boolean), public.hdm_billing_outbox_done(bigint, boolean, text), public.hdm_billing_cancel_issues(),
  public.hdm_email_outbox_pending(int), public.hdm_email_outbox_done(bigint, boolean, text), public.hdm_billing_status()
  from public, anon, authenticated;
grant execute on function public.hdm_billing_cancel(boolean), public.hdm_billing_status() to authenticated;
grant execute on function
  public.hdm_billing_outbox_done(bigint, boolean, text), public.hdm_billing_cancel_issues(),
  public.hdm_email_outbox_pending(int), public.hdm_email_outbox_done(bigint, boolean, text)
  to service_role;
-- ===== BILLING CANCEL END =====

-- ===================== 23_staging_billing_statutory_cancel.sql (ללא שינוי) =====================
create or replace function public.hdm_cancel_queue_email(p_req uuid, p_kind text)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare
  r     public.hdm_cancel_requests%rowtype;
  nm    text;
  subj  text;
  body  text;
  tail  text;
begin
  select * into r from public.hdm_cancel_requests where id = p_req;
  if r.id is null or r.user_id is null then return; end if;
  select coalesce(nullif(trim(data->>'currentName'), ''), '') into nm from public.docs
   where collection = 'profiles' and id = r.profile_id;
  if r.refund_requested then
    -- ביטול עסקה לפי חוק הגנת הצרכן: השירות מופסק עם הביטול, וההחזר מחושב לפי החוק
    tail := E'\n\nביקשת לבטל את העסקה לפי חוק הגנת הצרכן. השירות הופסק עם הביטול, והחשבון עבר למסלול החינמי.\n'
         || E'ההחזר יחושב לפי החוק — הסכום ששולם בניכוי התמורה עבור התקופה שבה השירות ניתן — ויוחזר לאמצעי התשלום המקורי בתוך 14 ימים מקבלת הודעת הביטול.\n'
         || E'ביטול העסקה לא מוחק את החשבון, את הפרופיל, את ההתאמות או את השיחות.';
  else
    -- ביטול חידוש רגיל: פעיל עד סוף התקופה ששולמה, בלי חיוב נוסף ובלי החזר יחסי (אלא אם הדין מחייב)
    tail := E'\n\nהמנוי יישאר פעיל עד ' || coalesce(public.hdm_fmt_date_il(r.active_until), 'סוף התקופה ששולמה')
         || E'. בתום התקופה המנוי יסתיים ללא חיוב נוסף, והחשבון יעבור אוטומטית למסלול החינמי.\n'
         || E'ביטול החידוש אינו מזכה בהחזר יחסי עבור יתרת התקופה, אלא אם הדין מחייב אחרת. זכויות ביטול עסקה לפי חוק הגנת הצרכן נשמרות — ראו "מדיניות ביטול מנוי".\n'
         || E'ביטול המנוי לא מוחק את החשבון, את הפרופיל, את ההתאמות או את השיחות.';
  end if;
  tail := tail || E'\n\nלשאלות: life.through.numbers333@gmail.com · 054-6628866\nחיים דרך מספרים';
  if p_kind = 'cancel_received' then
    subj := 'קיבלנו את בקשת ביטול המנוי — חיים דרך מספרים';
    body := 'שלום' || case when nm <> '' then ' ' || nm else '' end || E',\n\n'
         || 'קיבלנו את בקשתך לבטל את מנוי ' || public.hdm_plan_name_he(r.plan) || ' ב־' || public.hdm_fmt_date_il(r.requested_at) || E'.\n'
         || 'החידוש האוטומטי נעצר, ולא יתבצעו חיובים נוספים. הביטול ממתין לאישור סופי מספק הסליקה — '
         || 'נשלח אליך אישור נוסף כשיתקבל.' || tail;
  elsif p_kind = 'cancel_confirmed' then
    subj := 'אישור ביטול מנוי — חיים דרך מספרים';
    body := 'שלום' || case when nm <> '' then ' ' || nm else '' end || E',\n\n'
         || 'ביטול מנוי ' || public.hdm_plan_name_he(r.plan) || ' אושר. הבקשה התקבלה ב־' || public.hdm_fmt_date_il(r.requested_at)
         || E'.\nהמנוי לא יתחדש, ולא יתבצעו חיובים נוספים.' || tail;
  else
    raise exception 'hdm_cancel_queue_email: unknown kind %', p_kind;
  end if;
  insert into public.hdm_email_outbox (user_id, profile_id, kind, ref_id, subject, body_text)
  values (r.user_id, r.profile_id, p_kind, r.id, subj, body)
  on conflict (kind, ref_id) do nothing;
end $$;

create or replace function public.hdm_billing_cancel(p_refund boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me   text := public.hdm_require_me();
  uid  uuid := auth.uid();
  s    public.hdm_subscriptions%rowtype;
  r    public.hdm_cancel_requests%rowtype;
  ob   bigint;
  elig boolean;
begin
  perform pg_advisory_xact_lock(hashtext('hdm_billing:' || me));
  select * into s from public.hdm_subscriptions where profile_id = me for update;
  if s.profile_id is null or s.source <> 'payment' or public.hdm_plan_of(me) = 'free' then
    raise exception 'HDM_BILLING_NOTHING_TO_CANCEL' using errcode = 'P0001', hint = 'אין מנוי בתשלום לביטול.';
  end if;
  if not s.auto_renew then          -- כבר בוטל (או שהחידוש נעצר) — לא כופלים
    select * into r from public.hdm_cancel_requests
     where profile_id = me and requested_at >= s.period_anchor order by requested_at desc limit 1;
    return jsonb_build_object('canceled', true, 'already', true, 'activeUntil', s.current_period_end,
                              'cancelState', coalesce(r.state, 'confirmed'), 'requestedAt', r.requested_at,
                              'refundRequested', coalesce(r.refund_requested, false));
  end if;

  elig := s.period_anchor > now() - interval '14 days';
  if p_refund and not elig then
    raise exception 'HDM_BILLING_REFUND_WINDOW' using errcode = 'P0001',
      hint = 'בקשת ביטול עסקה לפי החוק מתוך האפליקציה זמינה בתוך 14 ימים מההצטרפות. לבקשות לפי החוק אחרי מועד זה — פנו באימייל או בטלפון. ביטול החידוש זמין תמיד.';
  end if;

  -- עצירת החידוש: מכאן שום חיוב חידוש לא נתפס (hdm_billing_claim_due_renewals דורש auto_renew)
  perform set_config('hdm.cancel_reason', 'customer', true);
  update public.hdm_subscriptions
     set status = 'canceled', auto_renew = false, canceled_at = now(), updated_at = now(),
         -- ביטול עסקה לפי החוק: השירות מופסק עם הביטול. ביטול חידוש רגיל: פעיל עד סוף התקופה ששולמה
         current_period_end = case when coalesce(p_refund, false) then now() else current_period_end end
   where profile_id = me
  returning * into s;
  perform set_config('hdm.cancel_reason', '', true);

  -- הבקשה מול Grow נרשמת בתור על ידי hdm_subscriptions_billing_guard (17)
  if s.grow_direct_debit_id is not null then
    select id into ob from public.hdm_grow_outbox
     where action = 'cancel_direct_debit' and grow_direct_debit_id = s.grow_direct_debit_id and done_at is null
     order by id desc limit 1;
  end if;

  insert into public.hdm_cancel_requests (profile_id, user_id, plan, source, active_until, state, grow_required, outbox_id,
                                          confirmed_at, refund_eligible, refund_requested, refund_state)
  values (me, uid, s.plan, 'app', s.current_period_end,
          case when ob is null then 'confirmed' else 'pending' end, ob is not null, ob,
          case when ob is null then now() end, elig, coalesce(p_refund, false),
          case when p_refund then 'open' end)
  returning * into r;

  insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan, note)
  values (me, 'cancel', s.plan, s.plan,
          'ביטול על ידי הלקוח מתוך האפליקציה' || case when ob is null then '' else ' — ממתין לאישור Grow' end
          || case when p_refund then ' — ביטול עסקה לפי חוק הגנת הצרכן: השירות הופסק, החזר לטיפול' else '' end);

  perform public.hdm_cancel_queue_email(r.id, case when r.state = 'pending' then 'cancel_received' else 'cancel_confirmed' end);

  return jsonb_build_object('canceled', true, 'already', false, 'activeUntil', s.current_period_end,
                            'cancelState', r.state, 'requestedAt', r.requested_at, 'refundRequested', r.refund_requested);
end $$;

-- מצב המנוי: מציג גם ביטול עסקה לפי החוק אחרי שהשירות הופסק
create or replace function public.hdm_billing_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me text := public.hdm_require_me();
  s  public.hdm_subscriptions%rowtype;
  pl text := public.hdm_plan_of(me);
  ck public.hdm_checkouts%rowtype;
  r  public.hdm_cancel_requests%rowtype;
  paid boolean;
begin
  select * into s from public.hdm_subscriptions where profile_id = me;
  select * into ck from public.hdm_checkouts where profile_id = me and status = 'pending' and expires_at > now();
  paid := s.profile_id is not null and s.source = 'payment' and pl <> 'free';
  if s.profile_id is not null then
    select * into r from public.hdm_cancel_requests
     where profile_id = me and requested_at >= s.period_anchor order by requested_at desc limit 1;
    -- מוצג: ביטול חידוש בזמן שהמנוי עוד פעיל, או ביטול עסקה לפי החוק (גם אחרי שהשירות הופסק)
    if r.id is not null and not ((paid and not s.auto_renew) or r.refund_requested) then r := null; end if;
  end if;
  return jsonb_build_object(
    'plan',            pl,
    'paid',            paid,
    'status',          case when pl = 'free' then 'none' else s.status end,
    'autoRenew',       paid and s.auto_renew,
    'nextChargeAt',    case when paid and s.auto_renew then s.current_period_end end,
    'nextChargeAgorot', case when paid and s.auto_renew then (select price_agorot from public.hdm_plans where plan = s.plan) end,
    'activeUntil',     case when pl <> 'free' then s.current_period_end end,
    'canCancel',       paid and s.auto_renew,
    'refundEligible',  paid and s.auto_renew and s.period_anchor > now() - interval '14 days',
    'refundUntil',     case when paid and s.auto_renew and s.period_anchor > now() - interval '14 days' then s.period_anchor + interval '14 days' end,
    'paymentFailed',   paid and s.status = 'past_due',
    'cancel',          case when r.id is null then null else jsonb_build_object(
                         'state', r.state, 'requestedAt', r.requested_at, 'confirmedAt', r.confirmed_at,
                         'activeUntil', r.active_until, 'delayed', r.needs_review,
                         'refundRequested', r.refund_requested, 'refundState', r.refund_state) end,
    'pendingCheckout', ck.id is not null,
    'termsVersion',    public.hdm_billing_current_terms(),
    'termsText',       (select summary_he from public.hdm_billing_terms_versions where version = public.hdm_billing_current_terms()));
end $$;

-- ההרשאות נשמרות ב-create or replace; מוודאים שוב
revoke all on function public.hdm_cancel_queue_email(uuid, text), public.hdm_billing_cancel(boolean) from public, anon, authenticated;
revoke all on function public.hdm_billing_status() from public, anon, authenticated;
grant execute on function public.hdm_billing_cancel(boolean), public.hdm_billing_status() to authenticated;

-- ===================== 24_staging_billing_morning.sql (ללא שינוי) =====================
-- ---------------------------------------------------------------------
-- 1. פרטי ניסיון תשלום — לפונקציית השרת בלבד
-- ---------------------------------------------------------------------
create function public.hdm_billing_checkout_lookup(p_checkout uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
           'id', c.id, 'userId', c.user_id, 'profileId', c.profile_id, 'kind', c.kind, 'plan', c.plan,
           'fromPlan', c.from_plan, 'amountAgorot', c.amount_agorot, 'status', c.status,
           'createdAt', c.created_at, 'expiresAt', c.expires_at, 'expired', c.expires_at <= now(),
           'email', lower(u.email), 'token', t.grow_token, 'processId', c.grow_process_id)
    from public.hdm_checkouts c
    left join auth.users u on u.id = c.user_id
    left join public.hdm_billing_tokens t on t.profile_id = c.profile_id
   where c.id = p_checkout
$$;

-- "תפיסת" ניסיון תשלום לפני פנייה ל-Morning: מצליח פעם אחת בלבד, כך שלחיצה כפולה לא מחייבת פעמיים
create function public.hdm_billing_claim_checkout(p_checkout uuid, p_process_id text)
returns boolean language sql volatile security definer set search_path = '' as $$
  with x as (
    update public.hdm_checkouts set grow_process_id = p_process_id
     where id = p_checkout and status = 'pending' and expires_at > now() and grow_process_id is null
    returning 1)
  select exists (select 1 from x)
$$;

-- ---------------------------------------------------------------------
-- 2. תוצאת חיוב חידוש בכרטיס השמור (Morning) — לפונקציית השרת בלבד
-- p: { chargeId, transactionId, outcome: approved|failed, amountAgorot, raw? }
-- בטוח להפעלה חוזרת: אותו מזהה עסקה נקלט פעם אחת בלבד.
-- ---------------------------------------------------------------------
create function public.hdm_billing_apply_morning_renewal(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  tx      text := nullif(p->>'transactionId', '');
  outcome text := p->>'outcome';
  amt     int  := (p->>'amountAgorot')::int;
  chid    uuid := nullif(p->>'chargeId', '')::uuid;
  pay_id  bigint;
  ch      public.hdm_renewal_charges%rowtype;
  s       public.hdm_subscriptions%rowtype;
  res     text;
  review  boolean := false;
  new_end timestamptz;
begin
  if tx is null or chid is null or outcome not in ('approved', 'failed') then
    raise exception 'HDM_BILLING_BAD_EVENT' using errcode = 'P0001';
  end if;
  select * into ch from public.hdm_renewal_charges where id = chid for update;
  if ch.id is null then
    raise exception 'HDM_BILLING_BAD_EVENT' using errcode = 'P0001';
  end if;

  insert into public.hdm_payments (grow_transaction_id, kind, outcome, result, profile_id, amount_agorot, raw)
  values (tx, 'renewal', outcome, 'received', ch.profile_id, amt, coalesce(p->'raw', '{}'::jsonb))
  on conflict (grow_transaction_id) do nothing
  returning id into pay_id;
  if pay_id is null then
    return jsonb_build_object('result', 'already_processed');
  end if;

  perform pg_advisory_xact_lock(hashtext('hdm_billing:' || ch.profile_id));
  select * into s from public.hdm_subscriptions where profile_id = ch.profile_id for update;

  if s.profile_id is null then
    res := 'unknown'; review := outcome = 'approved';
  elsif outcome = 'failed' then
    if s.auto_renew then
      update public.hdm_subscriptions
         set status = 'past_due', failed_attempts = failed_attempts + 1, updated_at = now()
       where profile_id = s.profile_id;
      insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan, note)
      values (s.profile_id, 'payment_failed', s.plan, s.plan, 'חיוב חידוש בכרטיס השמור נכשל (Morning) ' || tx);
      if s.failed_attempts + 1 >= 3 then                    -- אחרי 3 כישלונות: מפסיקים לנסות
        perform set_config('hdm.cancel_reason', 'payment_failed', true);
        update public.hdm_subscriptions set auto_renew = false, updated_at = now() where profile_id = s.profile_id;
        perform set_config('hdm.cancel_reason', '', true);
        insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan, note)
        values (s.profile_id, 'renewal_stopped', s.plan, s.plan, '3 חיובים נכשלו — החידוש הופסק');
      end if;
    end if;
    res := 'failed';
  elsif not s.auto_renew then
    res := 'after_cancel'; review := true;                  -- חיוב אחרי ביטול — לא מאריכים, להחזיר
  elsif amt is distinct from ch.amount_agorot then
    res := 'amount_mismatch'; review := true;
  elsif s.current_period_end > now() + interval '7 days' then
    res := 'duplicate'; review := true;                     -- התקופה כבר שולמה — לא מאריכים, להחזיר
  else
    new_end := public.hdm_billing_next_after(s.period_anchor, greatest(now(), coalesce(s.current_period_end, now())));
    update public.hdm_subscriptions
       set status = 'active', current_period_end = new_end, failed_attempts = 0,
           last_payment_at = now(), updated_at = now()
     where profile_id = s.profile_id;
    insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan, note)
    values (s.profile_id, 'renew', s.plan, s.plan, 'חידוש מאושר (Morning) ' || tx);
    res := 'renewed';
  end if;

  update public.hdm_renewal_charges
     set status = case when res = 'renewed' then 'approved' when res = 'failed' then 'failed' else 'review' end,
         closed_at = now()
   where id = chid and status in ('pending', 'review');
  update public.hdm_payments
     set result = res, needs_review = review, plan = s.plan, period_end_after = new_end
   where id = pay_id;
  return jsonb_build_object('result', res, 'needsReview', review, 'profileId', ch.profile_id, 'periodEnd', new_end);
end $$;

-- ---------------------------------------------------------------------
-- 3. הרשאות: פונקציית השרת בלבד
-- ---------------------------------------------------------------------
revoke all on function public.hdm_billing_checkout_lookup(uuid), public.hdm_billing_claim_checkout(uuid, text),
  public.hdm_billing_apply_morning_renewal(jsonb)
  from public, anon, authenticated;
grant execute on function public.hdm_billing_checkout_lookup(uuid), public.hdm_billing_claim_checkout(uuid, text),
  public.hdm_billing_apply_morning_renewal(jsonb)
  to service_role;

-- ===================== בדיקות אחרי ההתקנה (באותה עסקה) =====================
do $$
declare bad int;
begin
  if (select string_agg(plan || ':' || price_agorot || ':' || coalesce(monthly_new_chats::text, '∞') || ':' || limor_discount_pct, ',' order by sort_order) from public.hdm_plans)
     <> (select v from hdm_pre_plans) then
    raise exception 'עצירה: מסלול או מחיר השתנו. שום דבר לא נשמר.';
  end if;
  select count(*) into bad from hdm_pre_subs p where public.hdm_plan_of(p.profile_id) is distinct from p.plan;
  if bad > 0 then raise exception 'עצירה: המסלול של % משתמשים השתנה. שום דבר לא נשמר.', bad; end if;
  if (select docs from hdm_pre_counts) <> (select count(*) from public.docs)
     or (select users from hdm_pre_counts) <> (select count(*) from auth.users)
     or (select accounts from hdm_pre_counts) <> (select count(*) from public.hdm_accounts) then
    raise exception 'עצירה: מספר הרשומות השתנה. שום דבר לא נשמר.';
  end if;
  if (select count(*) from public.hdm_payments) + (select count(*) from public.hdm_checkouts) + (select count(*) from public.hdm_billing_tokens) <> 0 then
    raise exception 'עצירה: נוצרו רשומות תשלום. שום דבר לא נשמר.';
  end if;
  if to_regprocedure('public.hdm_billing_checkout_lookup(uuid)') is null or to_regprocedure('public.hdm_billing_apply_morning_renewal(jsonb)') is null then
    raise exception 'עצירה: פונקציות Morning לא הותקנו. שום דבר לא נשמר.';
  end if;
end $$;

insert into public.hdm_release_marker (version, note)
values ('production_billing_v1', 'מנויים בתשלום (17+19+21+23+24 מ-Staging) — מותקן, הסליקה כבויה עד הפעלה נפרדת');

commit;
