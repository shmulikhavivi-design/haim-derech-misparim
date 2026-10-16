-- =====================================================================
-- חיים דרך מספרים — מסלול פלוס בלי ניתוח נומרולוגי מורחב (VIP בלבד). אושר על ידי הבעלים 17.10.2026.
-- אותו קובץ בדיוק רץ ב-Staging ואחר כך ב-Production (בלי הבדל של אף תו).
-- פלוס ממשיך לקבל דירוג עם פירוט — האפליקציה מציגה לב + רמת התאמה + 3 שורות הניתוח המקוצר.
-- לא משנה מחירים, מכסות, הטבות אחרות, משתמשים, פרופילים, שיחות או מנויים. "הכול או כלום"; הרצה חוזרת לא עושה כלום.
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.hdm_plans') is null
     or (to_regclass('public.hdm_release_marker') is null and to_regclass('public.hdm_staging_marker') is null) then
    raise exception 'עצירה: זה לא מסד מאובטח של האפליקציה (לא Production אחרי המעבר ולא Staging). שום דבר לא שונה.';
  end if;
end $$;
update public.hdm_plans set extended_analysis = 'none' where plan = 'plus' and extended_analysis <> 'none';
do $$ begin
  if (select extended_analysis from public.hdm_plans where plan = 'plus') <> 'none' then raise exception 'עצירה: העדכון לא נקלט.'; end if;
  if (select extended_analysis from public.hdm_plans where plan = 'vip') <> 'after_my_target' then raise exception 'עצירה: VIP השתנה.'; end if;
  if (select string_agg(plan || ':' || price_agorot || ':' || can_rate || ':' || rating_details || ':' || can_target || ':' || can_chat || ':' || coalesce(monthly_new_chats::text, '∞') || ':' || see_who_targeted || ':' || limor_discount_pct, ',' order by sort_order) from public.hdm_plans)
     <> 'free:0:false:false:false:false:0:false:0,basic:2990:true:false:true:true:5:false:0,plus:4890:true:true:true:true:∞:true:0,vip:7990:true:true:true:true:∞:true:30' then
    raise exception 'עצירה: מחיר או הטבה אחרת השתנו. שום דבר לא נשמר.';
  end if;
end $$;
commit;
