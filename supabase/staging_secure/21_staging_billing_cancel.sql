-- =====================================================================
-- חיים דרך מספרים — ביטול מנוי: "בטיפול" עד אישור מספק הסליקה, מייל אישור, בקשת החזר. Staging בלבד.
--
-- Staging: להריץ פעם אחת אחרי 17 ו-19. נעצר אם כבר הותקן. "הכול או כלום".
-- Production: לא רץ. אין כאן חיבור ל-Grow, אין חיובים ואין שליחת מיילים בפועל.
--
-- מה משתנה (אושר 18.10.2026):
--   1. ביטול על ידי הלקוח עוצר מיד את החידוש (שום חיוב נוסף לא נתפס), ונרשם כבקשת ביטול.
--      אם יש סדרת חיובים ב-Grow — הבקשה במצב "בטיפול" (pending) עד שפונקציית השרת מקבלת אישור מ-Grow.
--      רק אז המצב "אושר" (confirmed). אם אין שום סדרה ב-Grow — אין מה לבטל שם, והביטול מאושר מיד.
--   2. כישלון מול Grow: נרשם, נספר; אחרי 3 כישלונות מסומן לטיפול ידני. החיובים נשארים חסומים בכל מקרה.
--   3. מייל ללקוח: "הבקשה התקבלה" (כשממתינים ל-Grow) ו"הביטול אושר". המיילים נכנסים לתור;
--      פונקציית שרת תשלח אותם (עוד לא פעילה).
--   4. בתוך 14 יום מההצטרפות אפשר לסמן "אני מבקש/ת החזר" — נרשם לטיפול לפי מדיניות הביטול.
--   5. ביטול המנוי לא נוגע בחשבון, בפרופיל, בהתאמות או בשיחות.
--
-- תואם לאחור: hdm_billing_cancel() בלי פרמטרים עדיין עובד ומחזיר את אותם שדות (canceled, already, activeUntil).
-- לא משנה ולא מוחק משתמשים, פרופילים, שיחות או מנויים קיימים.
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_renewal_charges') is null then
    raise exception 'עצירה: מנגנוני המנויים (17, 19) לא מותקנים. שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_cancel_requests') is not null then
    raise exception 'עצירה: מנגנון ביטול המנוי כבר מותקן. שום דבר לא שונה.';
  end if;
end $$;

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

insert into public.hdm_staging_marker (version, note)
values ('staging_billing_cancel_v1', 'ביטול מנוי: בטיפול עד אישור Grow, מייל אישור (בתור), בקשת החזר בתוך 14 יום — בלי Grow ובלי חיובים');

commit;

select '✅ מנגנון ביטול המנוי הותקן (בלי חיבור ל-Grow ובלי שליחת מיילים)' as "סטטוס",
       (select count(*) from public.hdm_subscriptions) as "מנויים קיימים (ללא שינוי)",
       (select count(*) from public.hdm_cancel_requests) as "בקשות ביטול";
