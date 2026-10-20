-- =====================================================================
-- חיים דרך מספרים — חיבור ישיר ל-Grow (Meshulam), מודל "כרטיס שמור, החיובים מנוהלים על ידינו". Staging בלבד.
--
-- Staging: להריץ פעם אחת אחרי 17, 19, 21, 23 ו-24. נעצר אם כבר הותקן. "הכול או כלום".
-- Production: לא רץ. אין כאן קריאות ל-Grow ואין חיובים — רק פונקציות שרת ל-Edge Functions.
--
-- המודל (תיעוד Grow, "Premium recurring – managed internally by your company"):
--   * הצטרפות: דף התשלום של Grow (createPaymentProcess, saveCardToken=1). Grow מחזירה cardToken בהודעת השרת.
--   * חידוש: השרת שלנו מחייב כל חודש את הכרטיס השמור (createTransactionWithToken). בחיוב הראשון בכרטיס
--     isRecurringDebitPayment=1 ← Grow מחזירה recurringDebitId; בהמשך שולחים אותו.
--   * ביטול חידוש: השרת מפסיק לחייב (hdm_billing_claim_due_renewals דורש auto_renew). אצל Grow אין סדרה שרצה
--     לבד, ולכן אין "ביטול" ששולחים ל-Grow; הבקשה בתור מאושרת על ידי פונקציית השרת (hdm_billing_grow_confirm_cancellations).
--
-- מה נוסף כאן:
--   1. פרטי המשלם לחיובים בכרטיס השמור (Grow דורשת שם מלא וטלפון בכל חיוב) — נשמרים מהודעת השרת של Grow.
--   2. hdm_billing_save_grow_card / hdm_billing_card_details — שמירה וקריאה (שרת בלבד).
--   3. hdm_billing_set_recurring_id — שמירת recurringDebitId שהתקבל בחיוב הראשון בכרטיס.
--   4. hdm_billing_grow_confirm_cancellations — אישור ביטולים במודל הזה.
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא שונה.';
  end if;
  if to_regprocedure('public.hdm_billing_checkout_lookup(uuid)') is null or to_regclass('public.hdm_cancel_requests') is null then
    raise exception 'עצירה: צריך קודם את 17, 19, 21, 23 ו-24. שום דבר לא שונה.';
  end if;
  if to_regprocedure('public.hdm_billing_save_grow_card(text, text, text, text, text, text)') is not null then
    raise exception 'עצירה: החיבור ל-Grow כבר מותקן. שום דבר לא שונה.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. פרטי המשלם והכרטיס (טבלה סגורה — שרת בלבד; נמחקת עם החשבון כמו ה-Token)
-- ---------------------------------------------------------------------
alter table public.hdm_billing_tokens
  add column payer_name  text,
  add column payer_phone text check (payer_phone is null or payer_phone ~ '^0[0-9]{8,9}$'),
  add column card_exp    text check (card_exp is null or card_exp ~ '^[0-9]{4}$');

-- ---------------------------------------------------------------------
-- 2. שמירה וקריאה של הכרטיס השמור
-- ---------------------------------------------------------------------
create function public.hdm_billing_save_grow_card(p_profile text, p_token text, p_last4 text, p_name text, p_phone text, p_exp text)
returns void language sql volatile security definer set search_path = '' as $$
  insert into public.hdm_billing_tokens (profile_id, grow_token, card_last4, payer_name, payer_phone, card_exp)
  values (p_profile, p_token, nullif(p_last4, ''), nullif(btrim(p_name), ''), nullif(p_phone, ''), nullif(p_exp, ''))
  on conflict (profile_id) do update set
    grow_token = excluded.grow_token, card_last4 = excluded.card_last4,
    payer_name = coalesce(excluded.payer_name, public.hdm_billing_tokens.payer_name),
    payer_phone = coalesce(excluded.payer_phone, public.hdm_billing_tokens.payer_phone),
    card_exp = excluded.card_exp, updated_at = now()
$$;

create function public.hdm_billing_card_details(p_profile text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('token', t.grow_token, 'last4', t.card_last4, 'name', t.payer_name, 'phone', t.payer_phone,
                            'exp', t.card_exp, 'recurringDebitId', s.grow_direct_debit_id)
    from public.hdm_billing_tokens t
    left join public.hdm_subscriptions s on s.profile_id = t.profile_id
   where t.profile_id = p_profile
$$;

-- ---------------------------------------------------------------------
-- 3. recurringDebitId — נשמר פעם אחת, רק למנוי בתשלום שעדיין מתחדש
-- ---------------------------------------------------------------------
create function public.hdm_billing_set_recurring_id(p_profile text, p_id text)
returns boolean language sql volatile security definer set search_path = '' as $$
  with x as (
    update public.hdm_subscriptions set grow_direct_debit_id = p_id, updated_at = now()
     where profile_id = p_profile and source = 'payment' and auto_renew and grow_direct_debit_id is null
       and nullif(btrim(p_id), '') is not null
    returning 1)
  select exists (select 1 from x)
$$;

-- ---------------------------------------------------------------------
-- 4. אישור ביטולים: במודל הזה Grow לא מחייבת לבד, ולכן מספיק שהשרת שלנו הפסיק לחייב.
--    מאשר רק בקשות שהמנוי שלהן באמת כבוי (auto_renew = false) — כך "בוטל" לא מוצג לפני שהחידוש נעצר.
-- ---------------------------------------------------------------------
create function public.hdm_billing_grow_confirm_cancellations()
returns int language plpgsql volatile security definer set search_path = '' as $$
declare
  ob record;
  n  int := 0;
begin
  for ob in
    select o.id from public.hdm_grow_outbox o
     where o.done_at is null and o.action = 'cancel_direct_debit'
       and not exists (select 1 from public.hdm_subscriptions s
                        where s.grow_direct_debit_id = o.grow_direct_debit_id and s.auto_renew)
     order by o.id
     for update skip locked
  loop
    perform public.hdm_billing_outbox_done(ob.id, true);
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- 5. הרשאות: פונקציית השרת בלבד
-- ---------------------------------------------------------------------
revoke all on function
  public.hdm_billing_save_grow_card(text, text, text, text, text, text), public.hdm_billing_card_details(text),
  public.hdm_billing_set_recurring_id(text, text), public.hdm_billing_grow_confirm_cancellations()
  from public, anon, authenticated;
grant execute on function
  public.hdm_billing_save_grow_card(text, text, text, text, text, text), public.hdm_billing_card_details(text),
  public.hdm_billing_set_recurring_id(text, text), public.hdm_billing_grow_confirm_cancellations()
  to service_role;

insert into public.hdm_staging_marker (version, note)
values ('staging_billing_grow_v1', 'חיבור ישיר ל-Grow: פרטי משלם, recurringDebitId, אישור ביטולים — בלי חיובים');

commit;

select '✅ החיבור הישיר ל-Grow הותקן ב-Staging (פונקציות שרת בלבד, בלי חיובים)' as "סטטוס",
       (select count(*) from public.hdm_subscriptions) as "מנויים קיימים (ללא שינוי)";
