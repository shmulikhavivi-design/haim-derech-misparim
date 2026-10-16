-- =====================================================================
-- חיים דרך מספרים — Production: מסלול Plus ללא הגבלת זמן וללא חיוב ל-4 החשבונות הקיימים בלבד
-- אושר על ידי הבעלים ב-16.10.2026 20:47.
--
-- * רק ארבעת הפרופילים שמפורטים כאן (שמואל, לימור, נועה, דני). אף פרופיל אחר לא נוגע.
-- * current_period_end = NULL → פעיל ללא תאריך תפוגה. source = 'test' → אין חיוב.
-- * לא משנה פרופילים, הודעות, 🎯, התאמות, משתמשים, ולא את טבלת המסלולים או את ברירת המחדל למשתמשים חדשים.
-- * "הכול או כלום": אם משהו לא תקין — שום דבר לא נשמר.
-- =====================================================================
begin;

do $$
declare
  ids text[] := array['reg_mupj1bkt75rzke','reg_muwrknqi6g320q','reg_muv7ffi3345nmx','reg_musrb6jotbe85d'];
  i text;
begin
  if to_regclass('public.hdm_release_marker') is null then
    raise exception 'עצירה: המעבר עוד לא בוצע. שום דבר לא שונה.';
  end if;
  foreach i in array ids loop
    if not exists (select 1 from public.docs where collection = 'profiles' and id = i) then
      raise exception 'עצירה: לא נמצא פרופיל %. שום דבר לא שונה.', i;
    end if;
    if not exists (select 1 from public.hdm_legacy_accounts where profile_id = i) then
      raise exception 'עצירה: % אינו חשבון קיים. שום דבר לא שונה.', i;
    end if;
    perform public.hdm_admin_set_plan(i, 'plus', null, 'השקה: חשבון קיים — Plus ללא הגבלת זמן, ללא חיוב (אישור הבעלים 16.10)');
  end loop;

  -- אימות לפני שמירה: בדיוק 4 מנויים, כולם Plus פעיל, ללא תפוגה, ללא חיוב
  if (select count(*) from public.hdm_subscriptions) <> 4
     or exists (select 1 from public.hdm_subscriptions
                 where not (profile_id = any(ids)) or plan <> 'plus' or status <> 'active'
                    or current_period_end is not null or source <> 'test') then
    raise exception 'עצירה: תוצאה לא צפויה בטבלת המנויים. שום דבר לא נשמר.';
  end if;
end $$;

commit;
