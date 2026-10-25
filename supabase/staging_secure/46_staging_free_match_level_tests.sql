-- =====================================================================
-- חיים דרך מספרים — בדיקות: מסלול חינם רואה רמת התאמה בלבד (אחרי 45_staging_free_match_level.sql).
-- משתמשים ופרופילים מומצאים בלבד, בלי מיילים ובלי חיובים. הכול מתבטל בסוף — שום דבר לא נשמר.
-- =====================================================================
begin;
do $$ begin if to_regclass('public.hdm_staging_marker') is null then raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא הורץ.'; end if; end $$;
create or replace function pg_temp.as_user(p_uid uuid, p_sql text) returns text language plpgsql as $$
declare r text; begin begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true); perform set_config('role', 'authenticated', true);
  execute p_sql into r; execute 'reset role'; return 'ok:' || coalesce(r, '');
exception when others then execute 'reset role'; return 'err:' || sqlerrm; end; end $$;
create temp table t_res (n serial, area text, name text, exp text, got text, ok boolean);
create or replace function pg_temp.chk(a text, nm text, e text, g text) returns void language sql as $$
  insert into t_res (area, name, exp, got, ok) values (a, nm, e, g, coalesce(g, '∅') like e) $$;
create or replace function pg_temp.perms(p text) returns text language sql as $$
  select price_agorot || ':' || can_rate || ':' || rating_details || ':' || can_target || ':' || can_chat || ':' || coalesce(monthly_new_chats::text, '∞')
         || ':' || see_who_targeted || ':' || extended_analysis || ':' || limor_discount_pct from public.hdm_plans where plan = p $$;
do $$
declare
  pfx text := 'fm' || substr(md5(random()::text), 1, 6);
  uF uuid := gen_random_uuid(); uF2 uuid := gen_random_uuid(); uB uuid := gen_random_uuid(); uP uuid := gen_random_uuid(); uV uuid := gen_random_uuid();
  uT uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  F text; F2 text; B text; P text; V text; T text[] := '{}'; r text; j jsonb; i int; labels text;
  req text := public.hdm_required_terms_version();
  bd text[] := array['1985-01-11','1987-02-12','1990-03-13','1992-04-14','1983-05-15','1995-06-16'];
  fn text[] := array['יוסי','מיכל','אבי','נועה','דני','רות'];
begin
  insert into auth.users (id, email, aud, role, created_at, raw_user_meta_data)
  select u, pfx || '_' || k || '@example.invalid', 'authenticated', 'authenticated', now(), '{}'::jsonb
    from unnest(array[uF, uF2, uB, uP, uV] || uT, array['f','f2','b','p','v','t1','t2','t3','t4','t5','t6']) as x(u, k);
  insert into public.hdm_consents (user_id, version, source) select u, req, 'signup' from unnest(array[uF, uF2, uB, uP, uV] || uT) u;
  F := substr(pg_temp.as_user(uF, 'select public.hdm_claim_profile()'), 4);  F2 := substr(pg_temp.as_user(uF2, 'select public.hdm_claim_profile()'), 4);
  B := substr(pg_temp.as_user(uB, 'select public.hdm_claim_profile()'), 4);  P := substr(pg_temp.as_user(uP, 'select public.hdm_claim_profile()'), 4);
  V := substr(pg_temp.as_user(uV, 'select public.hdm_claim_profile()'), 4);
  for i in 1 .. 6 loop T := T || substr(pg_temp.as_user(uT[i], 'select public.hdm_claim_profile()'), 4); end loop;
  perform pg_temp.as_user(uF,  format($q$ insert into public.docs values ('profiles', %L, '{"currentName":"חינם","birthdate":"1990-07-03","birthFirstName":"דנה","birthLastName":"כהן"}') returning id $q$, F));
  perform pg_temp.as_user(uF2, format($q$ insert into public.docs values ('profiles', %L, '{"currentName":"חינם 2","birthdate":"1988-09-21","birthFirstName":"עמית","birthLastName":"רז"}') returning id $q$, F2));
  perform pg_temp.as_user(uB,  format($q$ insert into public.docs values ('profiles', %L, '{"currentName":"בסיסי","birthdate":"1986-04-12","birthFirstName":"אבי","birthLastName":"שלום"}') returning id $q$, B));
  perform pg_temp.as_user(uP,  format($q$ insert into public.docs values ('profiles', %L, '{"currentName":"פלוס","birthdate":"1993-03-08","birthFirstName":"גיל","birthLastName":"שקד"}') returning id $q$, P));
  perform pg_temp.as_user(uV,  format($q$ insert into public.docs values ('profiles', %L, '{"currentName":"VIP","birthdate":"1979-08-29","birthFirstName":"רונית","birthLastName":"אור"}') returning id $q$, V));
  for i in 1 .. 6 loop
    perform pg_temp.as_user(uT[i], format($q$ insert into public.docs values ('profiles', %L, jsonb_build_object('currentName','מטרה','birthdate',%L,'birthFirstName',%L,'birthLastName','לוי')) returning id $q$, T[i], bd[i], fn[i]));
  end loop;
  perform public.hdm_admin_set_plan(B, 'basic'); perform public.hdm_admin_set_plan(P, 'plus'); perform public.hdm_admin_set_plan(V, 'vip');

  -- ---- הגדרות המסלולים (מחיר : דירוג : פירוט : 🎯 : צ'אט : שיחות : מי סימן : ניתוח מורחב : הנחה) ----
  perform pg_temp.chk('מסלולים', 'חינם — רמת התאמה בלבד, בלי פירוט/🎯/צ''אט', '0:true:false:false:false:0:false:none:0', pg_temp.perms('free'));
  perform pg_temp.chk('מסלולים', 'בסיסי לא השתנה', '2990:true:false:true:true:5:false:none:0', pg_temp.perms('basic'));
  perform pg_temp.chk('מסלולים', 'פלוס לא השתנה', '4890:true:true:true:true:∞:true:none:0', pg_temp.perms('plus'));
  perform pg_temp.chk('מסלולים', 'VIP לא השתנה', '7990:true:true:true:true:∞:true:after_my_target:30', pg_temp.perms('vip'));
  perform pg_temp.chk('מסלולים', 'פתוחים לרכישה לא השתנו', 'basic=true,plus=true,vip=false', (select string_agg(plan || '=' || on_sale, ',' order by plan) from public.hdm_plan_sale));
  perform pg_temp.chk('מסלולים', 'משתמש חדש — חינם', 'free', public.hdm_plan_of(F));

  -- ---- חינם: רואה רמת התאמה בשרת ----
  r := pg_temp.as_user(uF, format('select public.hdm_match_ratings(%L::text[])::text', T)); j := substr(r, 4)::jsonb;
  perform pg_temp.chk('חינם', 'מקבל דירוג מהשרת (לא נחסם)', 'ok:%', r);
  perform pg_temp.chk('חינם', 'דירוג לכל 6 הפרופילים', '6', (select count(*)::text from jsonb_object_keys(j)));
  perform pg_temp.chk('חינם', 'רק תווית + ציון — בלי פירוט/קטגוריות/goodCount', 'label,score', (select string_agg(distinct k, ',' order by k) from jsonb_each(j) e, jsonb_object_keys(e.value) k));
  labels := (select string_agg(distinct v->>'label', '|' order by v->>'label') from jsonb_each(j) e(k, v));
  perform pg_temp.chk('חינם', 'התוויות הן רמות התאמה מוכרות (' || coalesce(labels, '') || ')', 'ok', case when labels is not null and labels ~ '^(התאמה[^|]*)(\|התאמה[^|]*)*$' then 'ok' else coalesce(labels, '∅') end);
  r := pg_temp.as_user(uF, format('select public.hdm_my_entitlements()->>''canRate''')); perform pg_temp.chk('חינם', 'hdm_my_entitlements: canRate=true', 'ok:true', r);
  r := pg_temp.as_user(uF, format('select public.hdm_my_entitlements()->>''ratingDetails''')); perform pg_temp.chk('חינם', 'hdm_my_entitlements: ratingDetails=false', 'ok:false', r);

  -- ---- חינם: 🎯, צ'אט וניתוח עדיין חסומים ----
  perform pg_temp.chk('חינם', 'שליחת 🎯 חסומה', 'err:HDM_PLAN_REQUIRED%', pg_temp.as_user(uF, format('select public.hdm_send_target(%L)::text', T[1])));
  perform pg_temp.chk('חינם', 'לא נשמר עניין', '0', (select count(*)::text from public.docs where collection = 'interests' and data::text like '%' || F || '%' and data::text like '%' || T[1] || '%'));
  perform pg_temp.chk('חינם', '🎯 לחינם אחר חסום', 'err:HDM_PLAN_REQUIRED%', pg_temp.as_user(uF, format('select public.hdm_send_target(%L)::text', F2)));
  perform pg_temp.chk('חינם', 'ניתוח מורחב חסום', 'err:%', pg_temp.as_user(uF, format('select public.hdm_extended_analysis(%L)::text', T[1])));
  perform pg_temp.chk('חינם', 'אין שיחות פתוחות', '0', (select count(*)::text from public.docs where collection = 'chats' and data->'participants' ? F));
  r := pg_temp.as_user(uF, format($q$ insert into public.docs(collection,id,data) values ('chats', %L, jsonb_build_object('participants', jsonb_build_array(%L, %L))) returning id $q$, public.hdm_pair_id(F, B), F, B));
  perform pg_temp.chk('חינם', 'יצירת צ''אט ישירות במסד נחסמת', 'err:%', r);

  -- ---- המסלולים בתשלום: אותה צורה כמו קודם ----
  r := pg_temp.as_user(uB, format('select public.hdm_match_ratings(%L::text[])::text', T)); j := substr(r, 4)::jsonb;
  perform pg_temp.chk('בסיסי', 'תווית + ציון בלבד (כמו קודם)', 'label,score', (select string_agg(distinct k, ',' order by k) from jsonb_each(j) e, jsonb_object_keys(e.value) k));
  perform pg_temp.chk('בסיסי', '🎯 עובד', 'ok:%', pg_temp.as_user(uB, format('select public.hdm_send_target(%L)::text', T[2])));
  r := pg_temp.as_user(uP, format('select public.hdm_match_ratings(%L::text[])::text', T)); j := substr(r, 4)::jsonb;
  perform pg_temp.chk('פלוס', 'דירוג עם פירוט (כמו קודם)', 'categories,goodCount,karmicCount,label,score', (select string_agg(distinct k, ',' order by k) from jsonb_each(j) e, jsonb_object_keys(e.value) k));
  r := pg_temp.as_user(uV, format('select public.hdm_match_ratings(%L::text[])::text', T)); j := substr(r, 4)::jsonb;
  perform pg_temp.chk('VIP', 'דירוג עם פירוט (כמו קודם)', 'categories,goodCount,karmicCount,label,score', (select string_agg(distinct k, ',' order by k) from jsonb_each(j) e, jsonb_object_keys(e.value) k));

  -- ---- הרשמה ופרופיל: משתמש חדש עובד כרגיל ----
  perform pg_temp.chk('הרשמה', 'משתמש חדש מקבל פרופיל', 'ok', case when F <> '' and F2 <> '' then 'ok' else 'חסר' end);
  perform pg_temp.chk('הרשמה', 'כל 11 הפרופילים נשמרו', '11', (select count(*)::text from public.docs where collection = 'profiles' and id = any(array[F, F2, B, P, V] || T)));
end $$;
select n, area as "תחום", name as "בדיקה", exp as "צפוי", got as "התקבל", case when ok then '✅' else '❌' end as "עבר" from t_res order by n;
select 'סיכום: עברו ' || count(*) filter (where ok) || ' מתוך ' || count(*) as "סיכום" from t_res;
rollback;
