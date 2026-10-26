-- חיים דרך מספרים — השלמת הצטרפות בצד השרת (26.10). הכול או כלום.
-- מוסיף פונקציה אחת לקריאה בלבד. לא משנה אף לקוח, מנוי או תשלום.
begin;
-- 1. בדיקות מקדימות + תמונת מצב
do $$ begin
  if to_regclass('public.hdm_checkouts') is null or to_regclass('public.hdm_billing_customers') is null
     or to_regclass('public.hdm_billing_tokens') is null
     or to_regprocedure('public.hdm_billing_checkout_lookup(uuid)') is null
     or (to_regclass('public.hdm_release_marker') is null and to_regclass('public.hdm_staging_marker') is null) then
    raise exception 'עצירה: מסד לא צפוי. שום דבר לא שונה.';
  end if;
  -- מניעת חיוב כפול: התפיסה האטומית קיימת (חיוב אחד לכל ניסיון)
  if pg_get_functiondef('public.hdm_billing_claim_checkout(uuid,text)'::regprocedure) not like '%grow_process_id is null%' then
    raise exception 'עצירה: מנגנון מניעת החיוב הכפול לא נמצא. שום דבר לא שונה.';
  end if;
end $$;
create temp table hdm_before on commit drop as select
  (select count(*) from public.hdm_checkouts) ck, (select count(*) from public.hdm_payments) pay,
  (select count(*) from public.hdm_subscriptions) sub, (select count(*) from public.hdm_billing_tokens) tok,
  (select count(*) from public.hdm_billing_customers) cust, (select count(*) from auth.users) usr,
  (select md5(string_agg(s::text, '|' order by s.profile_id)) from public.hdm_subscriptions s) sub_md5;
-- 2. הפונקציה: ניסיונות הצטרפות שממתינים לשמירת כרטיס (בתוקף, לא נתפסו, יש לקוח Morning, אין כרטיס שמור, בני דקה+)
create or replace function public.hdm_billing_pending_card_checkouts(p_limit int default 20)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(public.hdm_billing_checkout_lookup(c.id) order by c.created_at), '[]'::jsonb)
    from (select c.id, c.created_at from public.hdm_checkouts c
           where c.status = 'pending' and c.grow_process_id is null and c.expires_at > now()
             and c.created_at <= now() - interval '1 minute'
             and exists (select 1 from public.hdm_billing_customers b where b.profile_id = c.profile_id)
             and not exists (select 1 from public.hdm_billing_tokens t where t.profile_id = c.profile_id)
           order by c.created_at limit greatest(1, least(coalesce(p_limit, 20), 50))) c
$$;
revoke all on function public.hdm_billing_pending_card_checkouts(int) from public, anon, authenticated;
grant execute on function public.hdm_billing_pending_card_checkouts(int) to service_role;
-- 3. בדיקות אחרי: הרשאות נכונות, ושום נתון לא השתנה
do $$ begin
  if has_function_privilege('authenticated', 'public.hdm_billing_pending_card_checkouts(int)', 'execute')
     or has_function_privilege('anon', 'public.hdm_billing_pending_card_checkouts(int)', 'execute')
     or not has_function_privilege('service_role', 'public.hdm_billing_pending_card_checkouts(int)', 'execute') then
    raise exception 'עצירה: הרשאות לא כמצופה. שום דבר לא שונה.';
  end if;
  if (select row(ck, pay, sub, tok, cust, usr, sub_md5) from hdm_before) is distinct from
     (select row((select count(*) from public.hdm_checkouts), (select count(*) from public.hdm_payments),
                 (select count(*) from public.hdm_subscriptions), (select count(*) from public.hdm_billing_tokens),
                 (select count(*) from public.hdm_billing_customers), (select count(*) from auth.users),
                 (select md5(string_agg(s::text, '|' order by s.profile_id)) from public.hdm_subscriptions s))) then
    raise exception 'עצירה: נתונים השתנו. שום דבר לא שונה.';
  end if;
end $$;
select '✅ הותקן. לקוחות, מנויים ותשלומים לא השתנו.' as "תוצאה";
commit;
-- חזרה לאחור (רק אם צריך): drop function public.hdm_billing_pending_card_checkouts(int);
