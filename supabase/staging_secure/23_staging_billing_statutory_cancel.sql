-- =====================================================================
-- חיים דרך מספרים — ביטול חידוש מול ביטול עסקה לפי חוק הגנת הצרכן. Staging בלבד.
--
-- Staging: להריץ פעם אחת אחרי 21. נעצר אם כבר הותקן. "הכול או כלום". Production: לא רץ.
-- מה משתנה (אושר 19.10.2026):
--   1. ביטול רגיל (hdm_billing_cancel(false)) — ללא שינוי: החידוש נעצר, המנוי פעיל עד סוף התקופה ששולמה, אין החזר יחסי.
--   2. ביטול עסקה לפי החוק (hdm_billing_cancel(true), בתוך 14 ימים מההצטרפות): השירות מופסק עם הביטול
--      (current_period_end = now → המסלול חוזר לחינם), והבקשה להחזר נפתחת לטיפול (refund_state = open).
--   3. hdm_billing_status מחזיר את בקשת ביטול העסקה גם אחרי שהשירות הופסק (כדי שהלקוח יראה אישור).
--   4. נוסח המיילים: הפרדה בין ביטול חידוש לבין ביטול עסקה לפי החוק, בלי הבטחה גורפת להחזר.
-- בלי Grow, בלי חיובים ובלי שליחת מיילים. לא משנה משתמשים, פרופילים, שיחות או מנויים קיימים.
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_cancel_requests') is null then
    raise exception 'עצירה: מנגנון ביטול המנוי (21) לא מותקן. שום דבר לא שונה.';
  end if;
  if exists (select 1 from public.hdm_staging_marker where version = 'staging_billing_statutory_cancel_v1') then
    raise exception 'עצירה: 23 כבר מותקן. שום דבר לא שונה.';
  end if;
end $$;

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

insert into public.hdm_staging_marker (version, note)
values ('staging_billing_statutory_cancel_v1', 'ביטול חידוש מול ביטול עסקה לפי חוק הגנת הצרכן: ביטול עסקה מפסיק את השירות; נוסח מיילים בלי הבטחה גורפת להחזר');

commit;

select '✅ 23 הותקן: ביטול עסקה לפי החוק מפסיק את השירות; ביטול רגיל ללא שינוי' as "סטטוס",
       (select count(*) from public.hdm_subscriptions) as "מנויים קיימים (ללא שינוי)";
