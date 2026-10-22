-- שמוליק חביבי (reg_mupj1bkt75rzke) עובר ממסלול פלוס ללא הגבלה למסלול חינם — אישור הבעלים 22.10 11:16. לא נוגע באף משתמש אחר.
begin;
create temp table pre on commit drop as select count(*) n, count(*) filter (where profile_id <> 'reg_mupj1bkt75rzke') others,
  md5(string_agg(row_to_json(s)::text, ',' order by profile_id) filter (where profile_id <> 'reg_mupj1bkt75rzke')) h from public.hdm_subscriptions s;
update public.hdm_subscriptions
   set plan = 'free', source = 'manual', status = 'active', current_period_end = null, auto_renew = false, updated_at = now(),
       note = 'מסלול חינם לפי בקשת הבעלים 22.10 (לפני כן: פלוס ללא הגבלה מההשקה)'
 where profile_id = 'reg_mupj1bkt75rzke' and plan = 'plus' and source = 'test';
do $$ begin
  if public.hdm_plan_of('reg_mupj1bkt75rzke') <> 'free' then raise exception 'עצירה: לא עבר לחינם'; end if;
  if (select md5(string_agg(row_to_json(s)::text, ',' order by profile_id)) from public.hdm_subscriptions s where profile_id <> 'reg_mupj1bkt75rzke') <> (select h from pre)
     then raise exception 'עצירה: מנוי של משתמש אחר השתנה'; end if;
end $$;
commit;
