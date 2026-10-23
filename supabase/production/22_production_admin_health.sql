-- =====================================================================
-- חיים דרך מספרים — לוח הניהול: מצב החיבורים, התראות פתוחות, אישור התקנון החדש ותשלומים אחרונים (23.10).
-- למנהלים בלבד (hdm_am_i_admin נבדק בתוך כל פונקציה). קריאה בלבד, חוץ מסימון התראה כ"טופלה".
-- לא משנה משתמשים, פרופילים, מנויים, תשלומים או מחירים. הרצה חוזרת בטוחה (create or replace).
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.hdm_release_marker') is null or to_regclass('public.hdm_staging_marker') is not null then
    raise exception 'עצירה: זה לא מסד ה-Production. שום דבר לא שונה.';
  end if;
  if to_regprocedure('public.hdm_am_i_admin()') is null or to_regclass('public.hdm_billing_alerts') is null
     or to_regclass('public.hdm_email_outbox') is null then
    raise exception 'עצירה: חסרים לוח הניהול (20) או ההתראות (18). שום דבר לא שונה.';
  end if;
end $$;
create temp table hdm_pre on commit drop as
  select (select count(*) from auth.users) u, (select count(*) from public.docs) d, (select count(*) from public.hdm_subscriptions) s,
         (select count(*) from public.hdm_payments) p, (select count(*) from public.hdm_billing_alerts) a;

-- ---------------------------------------------------------------------
-- מצב החיבורים ונתונים תפעוליים
-- ---------------------------------------------------------------------
create or replace function public.hdm_admin_health()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  tz constant text := 'Asia/Jerusalem';
  today0 timestamptz := date_trunc('day', now() at time zone tz) at time zone tz;
  req text;
  r jsonb;
begin
  if not public.hdm_am_i_admin() then raise exception 'HDM_NOT_ADMIN' using errcode = '42501'; end if;
  select max(version) into req from public.hdm_terms_versions where requires_reconsent;
  with real_users as (
         select u.id from auth.users u
          where not public.hdm_admin_is_test(u.id, u.email)
            and exists (select 1 from public.hdm_accounts a join public.docs d on d.collection = 'profiles' and d.id = a.profile_id where a.auth_user_id = u.id)),
       jobs as (
         select j.jobname, j.schedule, j.active,
                (select d.status from cron.job_run_details d where d.jobid = j.jobid order by d.start_time desc limit 1) last_status,
                (select d.start_time from cron.job_run_details d where d.jobid = j.jobid order by d.start_time desc limit 1) last_run,
                (select count(*) from cron.job_run_details d where d.jobid = j.jobid and d.status <> 'succeeded' and d.start_time > now() - interval '24 hours') fails24h
           from cron.job j where j.jobname in ('hdm-billing-worker', 'hdm-billing-alerts-scan', 'hdm-morning-renewals'))
  select jsonb_build_object(
    'generatedAt', now(),
    'emails', jsonb_build_object(
      'sentToday', (select count(*) from public.hdm_email_outbox where sent_at >= today0),
      'sent7d', (select count(*) from public.hdm_email_outbox where sent_at >= now() - interval '7 days'),
      'pending', (select count(*) from public.hdm_email_outbox where sent_at is null and attempts < 5),
      'failed', (select count(*) from public.hdm_email_outbox where sent_at is null and attempts >= 5),
      'oldestPendingMin', (select floor(extract(epoch from now() - min(created_at)) / 60)::int from public.hdm_email_outbox where sent_at is null),
      'lastSentAt', (select max(sent_at) from public.hdm_email_outbox),
      'lastError', (select left(regexp_replace(last_error, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+', '<email>', 'g'), 160)
                      from public.hdm_email_outbox where sent_at is null and last_error is not null order by id desc limit 1)),
    'signupEmails', jsonb_build_object(   -- מיילי האישור של ההרשמה נשלחים מ-Supabase דרך Brevo; כאן רואים אם אנשים נתקעים לפני האישור
      'unconfirmed24h', (select count(*) from auth.users u where u.email_confirmed_at is null and u.created_at < now() - interval '24 hours'
                           and not public.hdm_admin_is_test(u.id, u.email)),
      'unconfirmedRecent', (select count(*) from auth.users u where u.email_confirmed_at is null and u.created_at >= now() - interval '24 hours'
                           and not public.hdm_admin_is_test(u.id, u.email))),
    'jobs', coalesce((select jsonb_agg(jsonb_build_object('name', jobname, 'schedule', schedule, 'active', active, 'lastStatus', last_status,
                     'lastRun', last_run, 'fails24h', fails24h,
                     'ok', active and last_status = 'succeeded'
                           and last_run > now() - case when jobname = 'hdm-morning-renewals' then interval '2 hours'
                                                       when jobname = 'hdm-billing-alerts-scan' then interval '40 minutes'
                                                       else interval '15 minutes' end) order by jobname) from jobs), '[]'::jsonb),
    'billing', jsonb_build_object(
      'lastPaymentAt', (select max(received_at) from public.hdm_payments),
      'lastApprovedAt', (select max(received_at) from public.hdm_payments where outcome = 'approved'),
      'checkouts24h', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) from (select status, count(*) n from public.hdm_checkouts where created_at > now() - interval '24 hours' group by status) z),
      'cardsSaved', (select count(*) from public.hdm_billing_tokens),
      'vipOnSale', (select on_sale from public.hdm_plan_sale where plan = 'vip'),
      'cancelPending', (select count(*) from public.hdm_cancel_requests where state = 'pending'),
      'cancelNeedsReview', (select count(*) from public.hdm_cancel_requests where needs_review)),
    'terms', jsonb_build_object('required', req,
      'accepted', (select count(*) from real_users ru where exists (select 1 from public.hdm_consents c where c.user_id = ru.id and c.version = req)),
      'total', (select count(*) from real_users)),
    'alerts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'kind', a.kind, 'at', a.created_at, 'amountAgorot', a.amount_agorot,
                       'details', left(regexp_replace(coalesce(a.details, ''), '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+', '<email>', 'g'), 200),
                       'name', (select nullif(trim(coalesce(d.data->>'currentName', '')), '') from public.docs d where d.collection = 'profiles' and d.id = a.profile_id))
                       order by a.created_at desc)
                         from (select * from public.hdm_billing_alerts where resolved_at is null order by created_at desc limit 20) a), '[]'::jsonb),
    'alertsOpen', (select count(*) from public.hdm_billing_alerts where resolved_at is null),
    'recentPayments', coalesce((select jsonb_agg(jsonb_build_object('at', p.received_at, 'kind', p.kind, 'outcome', p.outcome, 'plan', p.plan,
                       'amountAgorot', p.amount_agorot, 'review', p.needs_review,
                       'name', (select nullif(trim(coalesce(d.data->>'currentName', '')), '') from public.docs d where d.collection = 'profiles' and d.id = p.profile_id))
                       order by p.received_at desc)
                         from (select * from public.hdm_payments order by received_at desc limit 10) p), '[]'::jsonb)
  ) into r;
  return r;
end $$;
revoke all on function public.hdm_admin_health() from public, anon;
grant execute on function public.hdm_admin_health() to authenticated;   -- ההרשאה נבדקת בתוך הפונקציה

-- ---------------------------------------------------------------------
-- סימון התראה כ"טופלה" (מנהלים בלבד). לא מוחק — רק מסמן מתי טופלה.
-- ---------------------------------------------------------------------
create or replace function public.hdm_admin_resolve_alert(p_id bigint)
returns boolean language plpgsql volatile security definer set search_path = '' as $$
begin
  if not public.hdm_am_i_admin() then raise exception 'HDM_NOT_ADMIN' using errcode = '42501'; end if;
  update public.hdm_billing_alerts set resolved_at = now() where id = p_id and resolved_at is null;
  return found;
end $$;
revoke all on function public.hdm_admin_resolve_alert(bigint) from public, anon;
grant execute on function public.hdm_admin_resolve_alert(bigint) to authenticated;

do $$ begin
  if (select u from hdm_pre) <> (select count(*) from auth.users) or (select d from hdm_pre) <> (select count(*) from public.docs)
     or (select s from hdm_pre) <> (select count(*) from public.hdm_subscriptions) or (select p from hdm_pre) <> (select count(*) from public.hdm_payments)
     or (select a from hdm_pre) <> (select count(*) from public.hdm_billing_alerts) then
    raise exception 'עצירה: מספר הרשומות השתנה.'; end if;
end $$;
insert into public.hdm_release_marker (version, note)
select 'production_admin_health', 'לוח הניהול: מצב החיבורים, התראות, אישור התקנון ותשלומים אחרונים (23.10)'
 where not exists (select 1 from public.hdm_release_marker where version = 'production_admin_health');
commit;
