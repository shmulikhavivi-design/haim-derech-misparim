-- =====================================================================
-- חיים דרך מספרים — Production: מסלול Plus לחשבונות הקיימים (אחרי המעבר בלבד, באישור הבעלים)
-- נותן Plus ל-30 יום לכל פרופיל שקושר לחשבון קיים (hdm_legacy_accounts) ושאין לו עדיין מנוי.
-- לא משנה פרופילים, הודעות, 🎯 או משתמשים. הרצה חוזרת לא עושה כלום.
-- =====================================================================
begin;
do $$
begin
  if to_regclass('public.hdm_release_marker') is null then
    raise exception 'עצירה: המעבר עוד לא בוצע. שום דבר לא שונה.';
  end if;
end $$;
select public.hdm_admin_set_plan(a.profile_id, 'plus', 30, 'השקה: חשבון קיים מתחיל ב-Plus')
from public.hdm_legacy_accounts a
where not exists (select 1 from public.hdm_subscriptions s where s.profile_id = a.profile_id);
commit;
select count(*) as "מנויים פעילים" from public.hdm_subscriptions;
