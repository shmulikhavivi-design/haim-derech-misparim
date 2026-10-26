-- =====================================================================
-- חיים דרך מספרים — השלמת הצטרפות בצד השרת (תקלת 26.10). אותו קובץ בדיוק ל-Staging ול-Production.
-- פונקציה אחת חדשה, לקריאה בלבד: hdm_billing_pending_card_checkouts(p_limit) — ניסיונות הצטרפות שממתינים לשמירת כרטיס:
--   בסטטוס pending, לא נתפסו (grow_process_id ריק), עוד בתוקף, נפתחו לפני דקה לפחות, יש להם לקוח Morning ואין להם כרטיס שמור.
-- מחזירה את אותו מבנה כמו hdm_billing_checkout_lookup. רק service_role (המשימה המתוזמנת) יכול להריץ.
-- לא משנה אף טבלה, משתמש, מנוי או חיוב. החיוב עצמו נשאר בתפיסה האטומית הקיימת (hdm_billing_claim_checkout).
-- הרצה חוזרת בטוחה. ביטול: drop function public.hdm_billing_pending_card_checkouts(int);
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.hdm_checkouts') is null or to_regclass('public.hdm_billing_customers') is null or to_regclass('public.hdm_billing_tokens') is null
     or to_regprocedure('public.hdm_billing_checkout_lookup(uuid)') is null
     or (to_regclass('public.hdm_release_marker') is null and to_regclass('public.hdm_staging_marker') is null) then
    raise exception 'עצירה: מסד לא צפוי (חסרות טבלאות החיוב / זה לא מסד מאובטח של האפליקציה). שום דבר לא שונה.';
  end if;
end $$;

create or replace function public.hdm_billing_pending_card_checkouts(p_limit int default 20)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(public.hdm_billing_checkout_lookup(c.id) order by c.created_at), '[]'::jsonb)
    from (select c.id, c.created_at from public.hdm_checkouts c
           where c.status = 'pending' and c.grow_process_id is null and c.expires_at > now()
             and c.created_at <= now() - interval '1 minute'
             and exists (select 1 from public.hdm_billing_customers b where b.profile_id = c.profile_id)
             and not exists (select 1 from public.hdm_billing_tokens t where t.profile_id = c.profile_id)
           order by c.created_at
           limit greatest(1, least(coalesce(p_limit, 20), 50))) c
$$;
revoke all on function public.hdm_billing_pending_card_checkouts(int) from public, anon, authenticated;
grant execute on function public.hdm_billing_pending_card_checkouts(int) to service_role;

do $$ begin
  if has_function_privilege('authenticated', 'public.hdm_billing_pending_card_checkouts(int)', 'execute')
     or has_function_privilege('anon', 'public.hdm_billing_pending_card_checkouts(int)', 'execute')
     or not has_function_privilege('service_role', 'public.hdm_billing_pending_card_checkouts(int)', 'execute') then
    raise exception 'עצירה: ההרשאות לא כמצופה. שום דבר לא שונה.';
  end if;
end $$;
select '✅ hdm_billing_pending_card_checkouts הותקנה (קריאה בלבד, service_role בלבד)' as "תוצאה";
commit;
