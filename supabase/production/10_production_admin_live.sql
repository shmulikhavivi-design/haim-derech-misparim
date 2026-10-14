-- =====================================================================
-- חיים דרך מספרים — Production: לוח הניהול — רשומים ומחוברים כרגע
-- ⛔ לא להריץ בלי אישור הבעלים. להריץ רק אחרי 06_production_admin_dashboard.sql.
-- נבנה מתוך supabase/staging_secure/10_staging_admin_live.sql — אותו קוד שרת בדיוק, ונבדק ב-Staging.
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_staging_marker') is not null then
    raise exception 'עצירה: זה פרויקט הניסוי — לשם יש את 10_staging_admin_live.sql. שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_admins') is null then
    raise exception 'עצירה: צריך להריץ קודם את 06_production_admin_dashboard.sql. שום דבר לא שונה.';
  end if;
  if to_regprocedure('public.hdm_admin_live()') is not null then
    raise exception 'עצירה: "מחוברים כרגע" כבר הותקן. שום דבר לא שונה.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- רשומים ומחוברים כרגע — מספרים בלבד
-- מחובר כרגע = משתמש עם session פעיל (לא התנתק) שהייתה בו כניסה או רענון התחברות ב-60 הדקות האחרונות.
-- (האפליקציה מרעננת את ההתחברות לפחות פעם בשעה כל עוד היא פתוחה.)
-- ---------------------------------------------------------------------
create function public.hdm_admin_live()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare win constant int := 60;
begin
  if not public.hdm_am_i_admin() then
    raise exception 'HDM_NOT_ADMIN' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'generatedAt', now(),
    'windowMinutes', win,
    'registered', (select count(*) from public.docs p where p.collection = 'profiles'),
    'onlineNow', (select count(distinct a.profile_id)
                    from public.hdm_accounts a
                    join auth.sessions s on s.user_id = a.auth_user_id
                    join public.docs p on p.collection = 'profiles' and p.id = a.profile_id
                   where greatest(s.created_at, s.updated_at,
                                  (to_jsonb(s)->>'refreshed_at')::timestamp at time zone 'UTC') >= now() - make_interval(mins => win)
                     and coalesce((to_jsonb(s)->>'not_after')::timestamptz, 'infinity') > now()));
end $$;
revoke all on function public.hdm_admin_live() from public, anon;
grant execute on function public.hdm_admin_live() to authenticated;   -- הבדיקה שהמשתמש מנהל נמצאת בתוך הפונקציה

commit;

select '✅ "מחוברים כרגע" הותקן' as "סטטוס";
