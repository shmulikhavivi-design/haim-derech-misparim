-- =====================================================================
-- חיים דרך מספרים — Staging בלבד: מסלול פלוס בלי ניתוח נומרולוגי מורחב (VIP בלבד). אושר על ידי הבעלים 16.10.2026.
-- פלוס ממשיך לקבל דירוג התאמה עם פירוט (rating_details) — ממנו האפליקציה מציגה את רמת ההתאמה ואת 3 שורות הניתוח המקוצר.
-- לא משנה מחירים, מכסות או הטבות אחרות. "הכול או כלום"; הרצה חוזרת לא עושה כלום.
-- =====================================================================
begin;
do $$ begin
  if to_regclass('public.hdm_staging_marker') is null then raise exception 'עצירה: זה לא פרויקט Staging. שום דבר לא שונה.'; end if;
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
insert into public.hdm_staging_marker(version) select 'staging_plus_no_extended_v1' where not exists (select 1 from public.hdm_staging_marker where version = 'staging_plus_no_extended_v1');
commit;
select plan, extended_analysis, rating_details, price_agorot from public.hdm_plans order by sort_order;
