-- =====================================================================
-- חיים דרך מספרים — שדרוג באמצע חודש עם חיוב יחסי + חידוש בכרטיס שמור (Token). Staging בלבד.
--
-- Staging: להריץ פעם אחת אחרי 17. נעצר אם כבר הותקן. "הכול או כלום".
-- Production: לא רץ. אין כאן חיבור ל-Grow ואין חיובים.
--
-- המודל (אושר 17.10.2026, אפשרות Token — "Premium recurring – manage by you" של Grow):
--   * בהצטרפות נשמר Token של הכרטיס ב-Grow. השרת שלנו מבצע כל חיוב בעצמו (createTransactionWithToken),
--     בלי שהלקוח מזין שוב פרטי אשראי.
--   * חידוש: כל חודש באותו תאריך. השרת "תופס" חיוב אחד בלבד לכל תקופה (hdm_billing_claim_due_renewals),
--     כך שגם הרצה כפולה של המשימה המתוזמנת לא מחייבת פעמיים.
--   * שדרוג בכל שלב: חיוב יחסי רק על יתרת התקופה, לפי ההפרש בין המסלולים, מעוגל לאגורה.
--     המסלול החדש מופעל מיד אחרי אישור התשלום, ותאריך החיוב החודשי לא משתנה. מהחידוש הבא — מחיר המסלול החדש.
--   * שנמוך באמצע חודש: לא בשלב הזה (נחסם בשרת, כמו קודם).
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_payments') is null then
    raise exception 'עצירה: מנגנון המנויים המתחדשים (17) לא מותקן. שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_renewal_charges') is not null then
    raise exception 'עצירה: מנגנון השדרוג והחידוש בכרטיס שמור כבר מותקן. שום דבר לא שונה.';
  end if;
end $$;

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

insert into public.hdm_staging_marker (version, note)
values ('staging_billing_upgrade_v1', 'שדרוג עם חיוב יחסי + חידוש בכרטיס שמור (Token) — בלי חיבור ל-Grow ובלי חיובים');

commit;

select '✅ שדרוג וחידוש בכרטיס שמור הותקנו (בלי חיבור ל-Grow)' as "סטטוס",
       (select count(*) from public.hdm_subscriptions) as "מנויים קיימים (ללא שינוי)";
