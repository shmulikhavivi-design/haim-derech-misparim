-- =====================================================================
-- חיים דרך מספרים — ביטול מערכת המנויים (חזרה למצב שלפני ההתקנה)
--
-- חלק 1 מבטל רק את האכיפה: האפליקציה חוזרת לעבוד כמו קודם, ורשומות המנויים נשמרות.
-- חלק 2 (בהערה) מוחק גם את טבלאות המנויים. משתמשים בו רק אם רוצים להסיר הכול.
-- אף אחד מהחלקים לא נוגע בטבלת docs — פרופילים, התאמות ושיחות נשארים כמו שהם.
-- =====================================================================

-- ---- חלק 1: ביטול האכיפה ----
drop trigger  if exists hdm_docs_subscription_guard on public.docs;
drop function if exists public.hdm_docs_subscription_guard();
drop function if exists public.hdm_open_pair(text, text[]);

-- ---- חלק 2: הסרה מלאה (להסיר את -- רק אם בטוחים) ----
-- drop function if exists public.hdm_my_entitlements(text);
-- drop function if exists public.hdm_admin_set_plan(text, text, text, text);
-- drop function if exists public.hdm_chats_used(text);
-- drop function if exists public.hdm_chat_limit(text);
-- drop function if exists public.hdm_plan_of(text);
-- drop function if exists public.hdm_period_start(timestamptz, timestamptz);
-- drop table    if exists public.hdm_chat_openings;
-- drop table    if exists public.hdm_subscriptions;
