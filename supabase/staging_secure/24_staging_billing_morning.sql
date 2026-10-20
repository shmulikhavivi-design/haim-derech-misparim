-- =====================================================================
-- חיים דרך מספרים — חיבור הסליקה דרך Morning (חשבונית ירוקה) + Grow. Staging בלבד.
--
-- Staging: להריץ פעם אחת אחרי 17, 19, 21 ו-23. נעצר אם כבר הותקן. "הכול או כלום".
-- Production: לא רץ. אין כאן קריאות ל-Morning ואין חיובים — רק פונקציות שרת שה-Edge Functions משתמשות בהן.
--
-- המודל (כרטיס שמור, "Token"): התשלום הראשון בדף התשלום המאובטח של Morning; החידושים והשדרוגים — חיוב
-- של הכרטיס השמור מהשרת שלנו (POST /payments/tokens/{id}/charge). אין "הוראת קבע" אצל Morning/Grow,
-- ולכן ביטול חידוש = השרת שלנו מפסיק לחייב (hdm_billing_claim_due_renewals דורש auto_renew), והביטול מאושר מיד.
--
-- מה נוסף כאן:
--   1. hdm_billing_checkout_lookup — פרטי ניסיון התשלום לפונקציית השרת (כולל מייל המשתמש לאימות המסמך מ-Morning).
--      hdm_billing_claim_checkout — "תפיסה" חד-פעמית של ניסיון תשלום לפני הפנייה ל-Morning (נגד חיוב כפול).
--   2. hdm_billing_apply_morning_renewal — קליטת תוצאת חיוב חידוש בכרטיס השמור, לפי החיוב שהשרת "תפס".
--      (הפונקציה הקיימת מזהה חידוש לפי מזהה סדרת חיובים של Grow, שאין במודל הזה.)
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_renewal_charges') is null or to_regclass('public.hdm_cancel_requests') is null then
    raise exception 'עצירה: צריך קודם את 17, 19, 21 ו-23 (מנויים, שדרוג, ביטול). שום דבר לא שונה.';
  end if;
  if to_regprocedure('public.hdm_billing_checkout_lookup(uuid)') is not null then
    raise exception 'עצירה: החיבור ל-Morning כבר מותקן. שום דבר לא שונה.';
  end if;
end $$;

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

insert into public.hdm_staging_marker (version, note)
values ('staging_billing_morning_v1', 'חיבור Morning (Grow): פרטי ניסיון תשלום וקליטת חידוש בכרטיס שמור — בלי חיובים');

commit;

select '✅ החיבור ל-Morning הותקן ב-Staging (פונקציות שרת בלבד, בלי חיובים)' as "סטטוס",
       (select count(*) from public.hdm_subscriptions) as "מנויים קיימים (ללא שינוי)";
