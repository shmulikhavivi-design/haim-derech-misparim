-- =====================================================================
-- חיים דרך מספרים — מערכת מנויים, שלב 2 מתוך 3: מסלול פלוס לחשבונות הבדיקה
-- להרצה רק אחרי subscriptions.sql, ולפני subscriptions_enforce.sql.
--
-- שמוליק, נועה, לימור ודני מקבלים מסלול פלוס לצורכי בדיקה, ללא חיוב וללא תאריך סיום.
-- לא נמחק ולא מתאפס שום פרופיל, התאמה או שיחה.
--
-- איך מריצים:
--   א. מריצים את הקובץ כמו שהוא. רץ רק החלק הראשון (תצוגה בלבד) ומוצגת רשימת כל הפרופילים.
--   ב. מעתיקים את המזהים (עמודת id) של ארבעת החשבונות לשורות שבחלק השני,
--      מסירים את סימני ההערה (--) משורות ה-select, ומריצים שוב.
-- =====================================================================

-- ---- חלק 1: תצוגה בלבד — כל הפרופילים והמסלול הנוכחי שלהם ----
select d.id,
       coalesce(d.data->>'currentName', '')                                         as current_name,
       trim(coalesce(d.data->>'birthFirstName', '') || ' ' || coalesce(d.data->>'birthLastName', '')) as birth_name,
       public.hdm_plan_of(d.id)                                                     as plan_now
  from public.docs d
 where d.collection = 'profiles'
 order by d.updated_at desc nulls last;

-- ---- חלק 2: הגדרת מסלול פלוס (להסיר את -- ולהדביק מזהים) ----
-- select public.hdm_admin_set_plan('<מזהה שמוליק>', 'plus', 'test', 'חשבון בדיקה — שמוליק');
-- select public.hdm_admin_set_plan('<מזהה נועה>',   'plus', 'test', 'חשבון בדיקה — נועה');
-- select public.hdm_admin_set_plan('<מזהה לימור>',  'plus', 'test', 'חשבון בדיקה — לימור');
-- select public.hdm_admin_set_plan('<מזהה דני>',    'plus', 'test', 'חשבון בדיקה — דני');

-- ---- בדיקה: מה מוגדר עכשיו ----
-- select profile_id, plan, status, source, note, period_anchor from public.hdm_subscriptions order by created_at;
