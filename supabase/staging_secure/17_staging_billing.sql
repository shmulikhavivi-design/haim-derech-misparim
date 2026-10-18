-- =====================================================================
-- חיים דרך מספרים — מנויים מתחדשים (הכנה לחיבור Grow). Staging בלבד.
--
-- Staging: להריץ פעם אחת אחרי 01–05, 14, 16. נעצר אם כבר הותקן. "הכול או כלום".
-- Production: לא רץ. הקטע שבין הסימונים BILLING ייכלל בקובץ מעבר נפרד רק אחרי אישור.
-- אין כאן שום חיבור ל-Grow ושום חיוב. האירועים מ-Grow יגיעו בעתיד דרך פונקציית שרת (Edge Function)
-- שמאמתת אותם, והיא בלבד תקרא ל-hdm_billing_apply_grow_event (הרשאת service_role בלבד).
--
-- מודל המנוי שאושר (17.10.2026):
--   1. חיוב ביום ההצטרפות.  2. חידוש אוטומטי כל חודש באותו תאריך (לפי שעון ישראל), עד ביטול.
--   3. ביטול עוצר את החידוש; המנוי בתוקף עד סוף התקופה ששולמה.
--   4. חיוב שנכשל — המנוי לא מוארך. אחרי 3 כישלונות החידוש נעצר.
--   5. אין חיוב כפול: אירוע עם אותו מזהה עסקה נקלט פעם אחת; תשלום שני לאותה תקופה לא מאריך ומסומן להחזר.
--      כל שינוי במנוי בתשלום נעשה רק לפי אירוע מאומת מ-Grow.
--   6. הלקוח רואה את תאריך החיוב הבא ויכול לבטל מתוך האפליקציה.
--
-- לא משנה ולא מוחק משתמשים, פרופילים, שיחות או מנויים קיימים (כולל 4 החשבונות בפלוס).
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_consents') is null then
    raise exception 'עצירה: מנגנון האישור (14) לא מותקן. שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_payments') is not null then
    raise exception 'עצירה: מנגנון המנויים המתחדשים כבר מותקן. שום דבר לא שונה.';
  end if;
end $$;

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

insert into public.hdm_staging_marker (version, note)
values ('staging_billing_v1', 'מנויים מתחדשים — הכנה לחיבור Grow (בלי חיבור ובלי חיובים)');

commit;

select '✅ מנגנון המנויים המתחדשים הותקן (בלי חיבור ל-Grow)' as "סטטוס",
       public.hdm_billing_current_terms() as "גרסת תנאי החידוש",
       (select count(*) from public.hdm_subscriptions) as "מנויים קיימים (ללא שינוי)",
       (select count(*) from public.hdm_subscriptions where auto_renew) as "מתחדשים";
