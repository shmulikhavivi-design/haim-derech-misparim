-- =====================================================================
-- חיים דרך מספרים — מסלול חינם: הצגת רמת התאמה בלבד (❤️/🩷/💔). בקשת הבעלים 25.10.2026.
-- אותו קובץ בדיוק רץ ב-Staging ואחר כך ב-Production (בלי הבדל של אף תו).
-- משנה ערך אחד בלבד: hdm_plans.can_rate = true במסלול free.
-- free נשאר: rating_details = false (בלי פירוט/ניתוח), can_target = false (בלי 🎯), can_chat = false (בלי צ'אט),
-- extended_analysis כפי שהוא. בסיסי / פלוס / VIP לא משתנים בכלל — נבדק עמודה-עמודה לפני ואחרי.
-- לא נוגע במשתמשים, פרופילים, שיחות, מנויים או חיובים. "הכול או כלום"; הרצה חוזרת לא עושה כלום.
-- ביטול: update public.hdm_plans set can_rate = false where plan = 'free';
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.hdm_plans') is null
     or (to_regclass('public.hdm_release_marker') is null and to_regclass('public.hdm_staging_marker') is null) then
    raise exception 'עצירה: זה לא מסד מאובטח של האפליקציה (לא Production אחרי המעבר ולא Staging). שום דבר לא שונה.';
  end if;
  if (select count(*) from public.hdm_plans where plan = 'free') <> 1 then raise exception 'עצירה: מסלול free לא נמצא.'; end if;
  if (select rating_details or can_target or can_chat from public.hdm_plans where plan = 'free') then
    raise exception 'עצירה: מסלול free במצב לא צפוי (פירוט/🎯/צ''אט פתוחים). שום דבר לא שונה.';
  end if;
end $$;
-- תמונת מצב של כל המסלולים (חוץ מהעמודה שמשתנה ב-free)
create temp table hdm_plans_before on commit drop as
  select plan, (to_jsonb(p) - case when plan = 'free' then 'can_rate' else '' end) as row_json from public.hdm_plans p;
update public.hdm_plans set can_rate = true where plan = 'free' and can_rate = false;
do $$ begin
  if not (select can_rate from public.hdm_plans where plan = 'free') then raise exception 'עצירה: העדכון לא נקלט.'; end if;
  if exists (
    select 1 from public.hdm_plans p full join hdm_plans_before b using (plan)
    where b.plan is null or p.plan is null
       or (to_jsonb(p) - case when p.plan = 'free' then 'can_rate' else '' end) is distinct from b.row_json) then
    raise exception 'עצירה: מסלול או הטבה אחרת השתנו. שום דבר לא נשמר.';
  end if;
end $$;
commit;
