-- =====================================================================
-- חיים דרך מספרים — בדיקות אוטומטיות לסביבת הניסוי
-- להרצה אחרי 01_staging_setup.sql, רק בפרויקט Haim Derech Misparim Staging.
--
-- הבדיקה יוצרת משתמשים ופרופילים מומצאים, מתחברת בשם כל אחד מהם (כמו האפליקציה),
-- מנסה פעולות מותרות ואסורות בכל מסלול, ובסוף מבטלת הכול: שום דבר לא נשמר.
--
-- התוצאה: טבלה עם שורה לכל בדיקה. בעמודה "עבר" צריך להופיע ✅ בכל השורות.
-- השורה האחרונה היא סיכום.
-- =====================================================================

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט ניסוי שהוקם עם 01_staging_setup.sql. שום דבר לא הורץ.';
  end if;
end $$;

-- מריץ פקודה בשם משתמש מחובר (או אורח לא מחובר), ומחזיר 'ok:<תוצאה>' או 'err:<קוד שגיאה>'
create or replace function pg_temp.as_user(p_uid uuid, p_sql text)
returns text language plpgsql as $$
declare r text;
begin
  begin
    perform set_config('request.jwt.claims',
      case when p_uid is null then '{"role":"anon"}'
           else json_build_object('sub', p_uid, 'role', 'authenticated')::text end, true);
    perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
    perform set_config('role', case when p_uid is null then 'anon' else 'authenticated' end, true);
    execute p_sql into r;
    execute 'reset role';
    return 'ok:' || coalesce(r, '');
  exception when others then
    return 'err:' || sqlerrm;
  end;
end $$;

create or replace function pg_temp.hdm_run_tests()
returns table(n int, "תחום" text, "בדיקה" text, "צפוי" text, "התקבל" text, "עבר" text)
language plpgsql as $$
declare
  t_area text[] := '{}'; t_name text[] := '{}'; t_exp text[] := '{}'; t_got text[] := '{}';
  pfx text := 't' || substr(md5(random()::text), 1, 5);
  -- משתמשים: F=חינם B=בסיסי P=פלוס V=VIP, ושותפים לשיחות
  uF uuid := gen_random_uuid(); uB uuid := gen_random_uuid(); uP uuid := gen_random_uuid(); uV uuid := gen_random_uuid();
  uQ uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  F text; B text; P text; V text; Q text[] := '{}';
  r text; i int; pair text;
begin
  begin
    -- ---------- הכנה: משתמשי Auth מומצאים ופרופילים ----------
    insert into auth.users (id, email, aud, role)
    select u, pfx || '_' || k || '@example.invalid', 'authenticated', 'authenticated'
      from unnest(array[uF, uB, uP, uV] || uQ, array['f','b','p','v','q1','q2','q3','q4','q5','q6','q7']) as x(u, k);

    F := substr(pg_temp.as_user(uF, $q$ select public.hdm_claim_profile() $q$), 4);
    B := substr(pg_temp.as_user(uB, $q$ select public.hdm_claim_profile() $q$), 4);
    P := substr(pg_temp.as_user(uP, $q$ select public.hdm_claim_profile() $q$), 4);
    V := substr(pg_temp.as_user(uV, $q$ select public.hdm_claim_profile() $q$), 4);
    for i in 1 .. 7 loop
      Q := Q || substr(pg_temp.as_user(uQ[i], $q$ select public.hdm_claim_profile() $q$), 4);
    end loop;

    -- כל משתמש כותב את הפרופיל של עצמו, כמו האפליקציה
    r := pg_temp.as_user(uF, format($q$ insert into public.docs(collection,id,data) values ('profiles', %L,
           '{"currentName":"בדיקה חינם","birthdate":"1990-07-03","birthFirstName":"דנה","birthLastName":"כהן","photoUrl":"data:x","likes":["zzz"]}') returning id $q$, F));
    t_area := t_area || text 'הכנה'; t_name := t_name || text 'משתמש חינם יוצר פרופיל משלו';
    t_exp := t_exp || text 'ok'; t_got := t_got || case when r like 'ok:%' then 'ok' else r end;

    perform pg_temp.as_user(uB, format($q$ insert into public.docs values ('profiles', %L,
           '{"currentName":"בדיקה בסיסי","birthdate":"1986-04-12","birthFirstName":"אבי","birthLastName":"שלום"}') returning id $q$, B));
    perform pg_temp.as_user(uP, format($q$ insert into public.docs values ('profiles', %L,
           '{"currentName":"בדיקה פלוס","birthdate":"1993-03-08","birthFirstName":"גיל","birthLastName":"שקד"}') returning id $q$, P));
    perform pg_temp.as_user(uV, format($q$ insert into public.docs values ('profiles', %L,
           '{"currentName":"בדיקה VIP","birthdate":"1979-08-29","birthFirstName":"רונית","birthLastName":"אור"}') returning id $q$, V));
    for i in 1 .. 7 loop
      perform pg_temp.as_user(uQ[i], format($q$ insert into public.docs values ('profiles', %L,
             '{"currentName":"שותף %s","birthdate":"1985-0%s-1%s","birthFirstName":"יוסי","birthLastName":"לוי"}') returning id $q$, Q[i], i, i, i));
    end loop;

    perform public.hdm_admin_set_plan(B, 'basic');
    perform public.hdm_admin_set_plan(P, 'plus');
    perform public.hdm_admin_set_plan(V, 'vip');
    for i in 1 .. 7 loop perform public.hdm_admin_set_plan(Q[i], 'plus'); end loop;

    t_area := t_area || text 'הכנה'; t_name := t_name || text 'נוצרו 11 פרופילים מומצאים';
    t_exp := t_exp || text '11';
    t_got := t_got || (select count(*)::text from public.docs where collection = 'profiles' and id = any(array[F,B,P,V] || Q));

    -- ================= אבטחה והרשאות =================
    r := pg_temp.as_user(null, $q$ select count(*)::text from public.docs $q$);
    t_area := t_area || text 'אבטחה'; t_name := t_name || text 'אורח לא מחובר לא יכול לקרוא את docs';
    t_exp := t_exp || text 'נחסם'; t_got := t_got || case when r like 'err:%' or r = 'ok:0' then 'נחסם' else r end;

    r := pg_temp.as_user(null, format($q$ select public.hdm_send_target(%L)::text $q$, B));
    t_area := t_area || text 'אבטחה'; t_name := t_name || text 'אורח לא מחובר לא יכול לסמן 🎯';
    t_exp := t_exp || text 'נחסם'; t_got := t_got || case when r like 'err:%' then 'נחסם' else r end;

    r := pg_temp.as_user(uB, $q$ select count(*)::text from public.hdm_subscriptions $q$);
    t_area := t_area || text 'אבטחה'; t_name := t_name || text 'משתמש לא יכול לקרוא את טבלת המנויים';
    t_exp := t_exp || text 'נחסם'; t_got := t_got || case when r like 'err:%' then 'נחסם' else r end;

    r := pg_temp.as_user(uF, format($q$ insert into public.hdm_subscriptions(profile_id, plan) values (%L, 'vip') returning plan $q$, F));
    t_area := t_area || text 'אבטחה'; t_name := t_name || text 'משתמש חינם לא יכול לשדרג את עצמו ל-VIP דרך הטבלה';
    t_exp := t_exp || text 'נחסם'; t_got := t_got || case when r like 'err:%' then 'נחסם' else r end;

    r := pg_temp.as_user(uF, format($q$ select public.hdm_admin_set_plan(%L, 'vip') $q$, F));
    t_area := t_area || text 'אבטחה'; t_name := t_name || text 'משתמש לא יכול להפעיל את פונקציית המנהל';
    t_exp := t_exp || text 'נחסם'; t_got := t_got || case when r like 'err:%' then 'נחסם' else r end;

    r := pg_temp.as_user(uF, format($q$ insert into public.hdm_chat_openings(profile_id,pair_id,plan) values (%L,'a__b','basic') returning 1 $q$, B));
    t_area := t_area || text 'אבטחה'; t_name := t_name || text 'אי אפשר לזייף את יומן השיחות (מכסה)';
    t_exp := t_exp || text 'נחסם'; t_got := t_got || case when r like 'err:%' then 'נחסם' else r end;

    r := pg_temp.as_user(uF, $q$ select count(*)::text from public.hdm_profile_private $q$);
    t_area := t_area || text 'פרטיות'; t_name := t_name || text 'אי אפשר לקרוא את טבלת פרטי הלידה';
    t_exp := t_exp || text 'נחסם'; t_got := t_got || case when r like 'err:%' then 'נחסם' else r end;

    r := pg_temp.as_user(uF, format($q$ select coalesce(data->>'birthdate','—') || '/' || coalesce(data->>'birthFirstName','—') || '/' || coalesce(data->>'vowelNumber','—')
                                         from public.docs where collection='profiles' and id=%L $q$, B));
    t_area := t_area || text 'פרטיות'; t_name := t_name || text 'בפרופיל של אחר אין תאריך לידה, שם מלידה ומספרים פנימיים';
    t_exp := t_exp || text 'ok:—/—/—'; t_got := t_got || r;

    r := pg_temp.as_user(uF, format($q$ select (data->'likes')::text from public.docs where collection='profiles' and id=%L $q$, F));
    t_area := t_area || text 'פרטיות'; t_name := t_name || text 'רשימת likes בפרופיל מתאפסת (🎯 נשמר רק בשרת)';
    t_exp := t_exp || text 'ok:[]'; t_got := t_got || r;

    r := pg_temp.as_user(uB, $q$ select (public.hdm_my_private()->>'birthdate') $q$);
    t_area := t_area || text 'פרטיות'; t_name := t_name || text 'משתמש רואה את תאריך הלידה של עצמו';
    t_exp := t_exp || text 'ok:1986-04-12'; t_got := t_got || r;

    r := pg_temp.as_user(uF, format($q$ with u as (update public.docs set data = data || '{"bio":"נפרץ"}' where collection='profiles' and id=%L returning 1) select count(*)::text from u $q$, B));
    t_area := t_area || text 'אבטחה'; t_name := t_name || text 'אי אפשר לערוך פרופיל של משתמש אחר';
    t_exp := t_exp || text 'ok:0'; t_got := t_got || r;

    r := pg_temp.as_user(uF, $q$ insert into public.docs values ('profiles','someone_else','{"birthdate":"1990-01-01"}') returning id $q$);
    t_area := t_area || text 'אבטחה'; t_name := t_name || text 'אי אפשר ליצור פרופיל בשם מזהה אחר';
    t_exp := t_exp || text 'נחסם'; t_got := t_got || case when r like 'err:%' then 'נחסם' else r end;

    r := pg_temp.as_user(uQ[7], format($q$ select public.hdm_claim_profile(%L) $q$, B));
    t_area := t_area || text 'אבטחה'; t_name := t_name || text 'אי אפשר להשתלט על מזהה פרופיל קיים';
    t_exp := t_exp || (text 'ok:' || Q[7]); t_got := t_got || r;   -- מחזיר את הפרופיל שלו, לא של B

    r := pg_temp.as_user(uF, format($q$ insert into public.docs values ('profiles', %L, '{"birthdate":"2012-05-05"}') on conflict (collection,id) do update set data = excluded.data returning id $q$, F));
    t_area := t_area || text 'גיל 18+'; t_name := t_name || text 'שינוי תאריך לידה לגיל מתחת ל-18 נחסם';
    t_exp := t_exp || text 'err:HDM_UNDERAGE'; t_got := t_got || r;

    insert into public.docs values ('data/users/x', 'acct_1', '{"hash":"secret"}'), ('authSessions', 's1', '{"profileId":"x"}');
    r := pg_temp.as_user(uF, $q$ select count(*)::text from public.docs where collection like 'data/users/%' or collection = 'authSessions' $q$);
    t_area := t_area || text 'אבטחה'; t_name := t_name || text 'אין גישה לרשומות התחברות ישנות (data/users, authSessions)';
    t_exp := t_exp || text 'ok:0'; t_got := t_got || r;

    r := pg_temp.as_user(uB, format($q$ insert into public.docs values ('interests', %L, '{}') returning id $q$, B || '__' || P));
    t_area := t_area || text 'עקיפה'; t_name := t_name || text 'אי אפשר לכתוב 🎯 ישירות לטבלה (עוקף את הבדיקה)';
    t_exp := t_exp || text 'נחסם'; t_got := t_got || case when r like 'err:%' then 'נחסם' else r end;

    r := pg_temp.as_user(uB, format($q$ insert into public.docs values ('matches', %L, '{}') returning id $q$, public.hdm_pair_id(B, P)));
    t_area := t_area || text 'עקיפה'; t_name := t_name || text 'אי אפשר ליצור התאמה ישירות';
    t_exp := t_exp || text 'נחסם'; t_got := t_got || case when r like 'err:%' then 'נחסם' else r end;

    r := pg_temp.as_user(uB, format($q$ insert into public.docs values ('chats', %L, '{"messages":[]}') on conflict (collection,id) do update set data = excluded.data returning id $q$, public.hdm_pair_id(B, P)));
    t_area := t_area || text 'עקיפה'; t_name := t_name || text 'אי אפשר לפתוח צ׳אט ישירות בלי 🎯 הדדי';
    t_exp := t_exp || text 'err:HDM_CHAT_NOT_OPEN'; t_got := t_got || r;

    -- ================= חינם =================
    r := pg_temp.as_user(uF, $q$ select (count(*) >= 10)::text from public.docs where collection = 'profiles' and data ? 'photoUrl' or collection = 'profiles' $q$);
    t_area := t_area || text 'חינם'; t_name := t_name || text 'רואה פרופילים ותמונות';
    t_exp := t_exp || text 'ok:true'; t_got := t_got || r;

    r := pg_temp.as_user(uF, format($q$ select public.hdm_match_ratings(array[%L])::text $q$, B));
    t_area := t_area || text 'חינם'; t_name := t_name || text 'אין דירוג התאמה';
    t_exp := t_exp || text 'err:HDM_PLAN_REQUIRED'; t_got := t_got || r;

    r := pg_temp.as_user(uF, format($q$ select public.hdm_send_target(%L)::text $q$, B));
    t_area := t_area || text 'חינם'; t_name := t_name || text 'אין סימון 🎯';
    t_exp := t_exp || text 'err:HDM_PLAN_REQUIRED'; t_got := t_got || r;

    r := pg_temp.as_user(uF, $q$ select public.hdm_who_targeted_me()::text $q$);
    t_area := t_area || text 'חינם'; t_name := t_name || text 'אין צפייה במי שסימן 🎯';
    t_exp := t_exp || text 'err:HDM_PLAN_REQUIRED'; t_got := t_got || r;

    r := pg_temp.as_user(uF, format($q$ select public.hdm_extended_analysis(%L)::text $q$, B));
    t_area := t_area || text 'חינם'; t_name := t_name || text 'אין ניתוח מורחב';
    t_exp := t_exp || text 'err:HDM_PLAN_REQUIRED'; t_got := t_got || r;

    r := pg_temp.as_user(uF, $q$ select public.hdm_my_entitlements()->>'plan' $q$);
    t_area := t_area || text 'חינם'; t_name := t_name || text 'המסלול שמוחזר הוא free';
    t_exp := t_exp || text 'ok:free'; t_got := t_got || r;

    -- ================= בסיסי =================
    r := pg_temp.as_user(uB, format($q$ select (public.hdm_match_ratings(array[%L])->%L ? 'label')::text || '/' || (public.hdm_match_ratings(array[%L])->%L ? 'categories')::text $q$, P, P, P, P));
    t_area := t_area || text 'בסיסי'; t_name := t_name || text 'יש דירוג התאמה, בלי פירוט';
    t_exp := t_exp || text 'ok:true/false'; t_got := t_got || r;

    r := pg_temp.as_user(uB, format($q$ select (public.hdm_send_target(%L)->>'mutual') $q$, Q[1]));
    t_area := t_area || text 'בסיסי'; t_name := t_name || text '🎯 חד-צדדי נשמר בלי שיחה';
    t_exp := t_exp || text 'ok:false'; t_got := t_got || r;

    r := pg_temp.as_user(uB, format($q$ select count(*)::text from public.docs where collection='chats' and id=%L $q$, public.hdm_pair_id(B, Q[1])));
    t_area := t_area || text 'בסיסי'; t_name := t_name || text 'אין צ׳אט לפני הדדיות';
    t_exp := t_exp || text 'ok:0'; t_got := t_got || r;

    r := pg_temp.as_user(uQ[1], format($q$ select (public.hdm_send_target(%L)->>'chat') $q$, B));
    t_area := t_area || text 'בסיסי'; t_name := t_name || text '🎯 הדדי פותח צ׳אט';
    t_exp := t_exp || text 'ok:opened'; t_got := t_got || r;

    pair := public.hdm_pair_id(B, Q[1]);
    r := pg_temp.as_user(uB, format($q$ with u as (update public.docs set data = jsonb_set(data, '{messages}', (data->'messages') || jsonb_build_array(jsonb_build_object('senderId', %L, 'text', 'שלום!', 'ts', 1))) where collection='chats' and id=%L returning 1) select count(*)::text from u $q$, B, pair));
    t_area := t_area || text 'בסיסי'; t_name := t_name || text 'שולח הודעה בצ׳אט';
    t_exp := t_exp || text 'ok:1'; t_got := t_got || r;

    r := pg_temp.as_user(uB, format($q$ with u as (update public.docs set data = jsonb_set(data, '{messages}', (data->'messages') || jsonb_build_array(jsonb_build_object('senderId', %L, 'text', 'זיוף', 'ts', 2))) where collection='chats' and id=%L returning 1) select count(*)::text from u $q$, Q[1], pair));
    t_area := t_area || text 'עקיפה'; t_name := t_name || text 'אי אפשר לשלוח הודעה בשם הצד השני';
    t_exp := t_exp || text 'err:HDM_SENDER_MISMATCH'; t_got := t_got || r;

    r := pg_temp.as_user(uB, format($q$ with u as (update public.docs set data = jsonb_set(data, '{messages}', '[]') where collection='chats' and id=%L returning 1) select count(*)::text from u $q$, pair));
    t_area := t_area || text 'עקיפה'; t_name := t_name || text 'אי אפשר למחוק הודעות קיימות';
    t_exp := t_exp || text 'err:HDM_CHAT_HISTORY_LOCKED'; t_got := t_got || r;

    r := pg_temp.as_user(uP, format($q$ select count(*)::text from public.docs where collection='chats' and id=%L $q$, pair));
    t_area := t_area || text 'פרטיות'; t_name := t_name || text 'משתמש אחר לא רואה את הצ׳אט';
    t_exp := t_exp || text 'ok:0'; t_got := t_got || r;

    r := pg_temp.as_user(uB, $q$ select public.hdm_who_targeted_me()::text $q$);
    t_area := t_area || text 'בסיסי'; t_name := t_name || text 'אין צפייה במי שסימן 🎯';
    t_exp := t_exp || text 'err:HDM_PLAN_REQUIRED'; t_got := t_got || r;

    r := pg_temp.as_user(uB, format($q$ select public.hdm_extended_analysis(%L)::text $q$, Q[1]));
    t_area := t_area || text 'בסיסי'; t_name := t_name || text 'אין ניתוח מורחב (גם אחרי הדדיות)';
    t_exp := t_exp || text 'err:HDM_PLAN_REQUIRED'; t_got := t_got || r;

    -- מכסה: עוד 4 שיחות (סה"כ 5)
    for i in 2 .. 5 loop
      perform pg_temp.as_user(uB, format($q$ select public.hdm_send_target(%L)::text $q$, Q[i]));
      perform pg_temp.as_user(uQ[i], format($q$ select public.hdm_send_target(%L)::text $q$, B));
    end loop;
    r := pg_temp.as_user(uB, $q$ select (public.hdm_my_entitlements()->>'chatsUsed') || '/' || (public.hdm_my_entitlements()->>'chatsLeft') $q$);
    t_area := t_area || text 'בסיסי'; t_name := t_name || text 'אחרי 5 שיחות חדשות: נוצלו 5, נותרו 0';
    t_exp := t_exp || text 'ok:5/0'; t_got := t_got || r;

    perform pg_temp.as_user(uQ[6], format($q$ select public.hdm_send_target(%L)::text $q$, B));
    r := pg_temp.as_user(uB, format($q$ select (public.hdm_send_target(%L)->>'chat') $q$, Q[6]));
    t_area := t_area || text 'בסיסי'; t_name := t_name || text 'שיחה שישית בחודש לא נפתחת (🎯 נשמר)';
    t_exp := t_exp || text 'ok:my_limit'; t_got := t_got || r;

    r := pg_temp.as_user(uB, format($q$ select public.hdm_open_chat(%L) $q$, Q[6]));
    t_area := t_area || text 'עקיפה'; t_name := t_name || text 'ניסיון חוזר לפתוח את השיחה השישית נחסם';
    t_exp := t_exp || text 'err:HDM_CHAT_LIMIT'; t_got := t_got || r;

    r := pg_temp.as_user(uQ[6], format($q$ select public.hdm_open_chat(%L) $q$, B));
    t_area := t_area || text 'עקיפה'; t_name := t_name || text 'גם הצד השני לא יכול לפתוח אותה (המכסה של הבסיסי מלאה)';
    t_exp := t_exp || text 'err:HDM_OTHER_UNAVAILABLE'; t_got := t_got || r;

    r := pg_temp.as_user(uB, format($q$ insert into public.docs values ('chats', %L, '{"messages":[]}') on conflict (collection,id) do update set data = excluded.data returning id $q$, public.hdm_pair_id(B, Q[6])));
    t_area := t_area || text 'עקיפה'; t_name := t_name || text 'גם כתיבה ישירה לטבלה לא פותחת את השיחה השישית';
    t_exp := t_exp || text 'err:HDM_CHAT_NOT_OPEN'; t_got := t_got || r;

    r := pg_temp.as_user(uB, format($q$ select public.hdm_open_chat(%L) $q$, Q[1]));
    t_area := t_area || text 'בסיסי'; t_name := t_name || text 'שיחה קיימת ממשיכה לעבוד גם כשהמכסה מלאה';
    t_exp := t_exp || text 'ok:exists'; t_got := t_got || r;

    -- ================= פלוס =================
    perform pg_temp.as_user(uB, format($q$ select public.hdm_send_target(%L)::text $q$, P));
    r := pg_temp.as_user(uP, format($q$ select (public.hdm_match_ratings(array[%L])->%L ? 'categories')::text $q$, B, B));
    t_area := t_area || text 'פלוס'; t_name := t_name || text 'דירוג התאמה כולל פירוט';
    t_exp := t_exp || text 'ok:true'; t_got := t_got || r;

    r := pg_temp.as_user(uP, format($q$ select (public.hdm_who_targeted_me() @> jsonb_build_array(jsonb_build_object('id', %L)))::text $q$, B));
    t_area := t_area || text 'פלוס'; t_name := t_name || text 'רואה מי סימן אותו 🎯';
    t_exp := t_exp || text 'ok:true'; t_got := t_got || r;

    r := pg_temp.as_user(uP, format($q$ select public.hdm_extended_analysis(%L)::text $q$, B));
    t_area := t_area || text 'פלוס'; t_name := t_name || text 'ניתוח מורחב לא נפתח לפני הדדיות';
    t_exp := t_exp || text 'err:HDM_NOT_MUTUAL'; t_got := t_got || r;

    for i in 1 .. 7 loop
      perform pg_temp.as_user(uP, format($q$ select public.hdm_send_target(%L)::text $q$, Q[i]));
      perform pg_temp.as_user(uQ[i], format($q$ select public.hdm_send_target(%L)::text $q$, P));
    end loop;
    r := pg_temp.as_user(uP, $q$ select (public.hdm_my_entitlements()->>'chatsUsed') || '/' || coalesce(public.hdm_my_entitlements()->>'chatsLimit', 'ללא הגבלה') $q$);
    t_area := t_area || text 'פלוס'; t_name := t_name || text '7 שיחות חדשות בחודש — ללא הגבלה';
    t_exp := t_exp || text 'ok:7/ללא הגבלה'; t_got := t_got || r;

    r := pg_temp.as_user(uP, format($q$ select (public.hdm_extended_analysis(%L) ? 'categories')::text $q$, Q[1]));
    t_area := t_area || text 'פלוס'; t_name := t_name || text 'ניתוח מורחב נפתח אחרי 🎯 הדדי';
    t_exp := t_exp || text 'ok:true'; t_got := t_got || r;

    r := pg_temp.as_user(uP, format($q$ select (public.hdm_extended_analysis(%L)::text like '%%1979%%' or public.hdm_extended_analysis(%L)::text like '%%יוסי%%')::text $q$, Q[1], Q[1]));
    t_area := t_area || text 'פרטיות'; t_name := t_name || text 'הניתוח המורחב לא חושף תאריך לידה או שם מלידה';
    t_exp := t_exp || text 'ok:false'; t_got := t_got || r;

    -- ================= VIP =================
    r := pg_temp.as_user(uV, format($q$ select public.hdm_extended_analysis(%L)::text $q$, Q[7]));
    t_area := t_area || text 'VIP'; t_name := t_name || text 'בלי 🎯 — אין ניתוח מורחב';
    t_exp := t_exp || text 'err:HDM_TARGET_FIRST'; t_got := t_got || r;

    r := pg_temp.as_user(uV, format($q$ select (public.hdm_send_target(%L)->>'extendedAnalysis') || '/' || coalesce(public.hdm_send_target(%L)->>'chat', 'אין צ׳אט') $q$, F, F));
    t_area := t_area || text 'VIP'; t_name := t_name || text 'אחרי 🎯 שלו: ניתוח זמין, צ׳אט לא נפתח';
    t_exp := t_exp || text 'ok:true/אין צ׳אט'; t_got := t_got || r;

    r := pg_temp.as_user(uV, format($q$ select (public.hdm_extended_analysis(%L)->>'limorDiscountPct') $q$, F));
    t_area := t_area || text 'VIP'; t_name := t_name || text 'ניתוח מורחב מיד אחרי 🎯, עם הנחת 30% אצל לימור רון';
    t_exp := t_exp || text 'ok:30'; t_got := t_got || r;

    r := pg_temp.as_user(uV, $q$ select (public.hdm_my_entitlements()->>'limorDiscountPct') || '/' || (public.hdm_my_entitlements()->>'priceAgorot') $q$);
    t_area := t_area || text 'VIP'; t_name := t_name || text 'מסך המנוי: 30% הנחה, ₪79.90';
    t_exp := t_exp || text 'ok:30/7990'; t_got := t_got || r;

    r := pg_temp.as_user(uB, $q$ select (public.hdm_my_entitlements()->>'priceAgorot') $q$);
    t_area := t_area || text 'מחירים'; t_name := t_name || text 'בסיסי ₪29.90';
    t_exp := t_exp || text 'ok:2990'; t_got := t_got || r;

    r := pg_temp.as_user(uP, $q$ select (public.hdm_my_entitlements()->>'priceAgorot') $q$);
    t_area := t_area || text 'מחירים'; t_name := t_name || text 'פלוס ₪48.90';
    t_exp := t_exp || text 'ok:4890'; t_got := t_got || r;

    -- ================= שדרוג / שנמוך / ביטול / פקיעה =================
    perform public.hdm_admin_set_plan(B, 'plus');
    r := pg_temp.as_user(uB, format($q$ select public.hdm_open_chat(%L) $q$, Q[6]));
    t_area := t_area || text 'שדרוג'; t_name := t_name || text 'בסיסי → פלוס: השיחה השישית נפתחת מיד';
    t_exp := t_exp || text 'ok:opened'; t_got := t_got || r;

    r := pg_temp.as_user(uB, $q$ select (jsonb_typeof(public.hdm_who_targeted_me()))::text $q$);
    t_area := t_area || text 'שדרוג'; t_name := t_name || text 'אחרי שדרוג לפלוס: רואה מי סימן 🎯';
    t_exp := t_exp || text 'ok:array'; t_got := t_got || r;

    perform public.hdm_admin_set_plan(B, 'basic');
    r := pg_temp.as_user(uB, $q$ select (public.hdm_my_entitlements()->>'chatsLeft') $q$);
    t_area := t_area || text 'שנמוך'; t_name := t_name || text 'פלוס → בסיסי באותו חודש: המונה לא מתאפס';
    t_exp := t_exp || text 'ok:0'; t_got := t_got || r;

    -- חודש חיוב חדש: מזיזים את תחילת המנוי ואת השיחות הקודמות 32 יום אחורה
    update public.hdm_subscriptions set period_anchor = period_anchor - interval '32 days' where profile_id = B;
    update public.hdm_chat_openings set opened_at = opened_at - interval '32 days' where profile_id = B;
    r := pg_temp.as_user(uB, $q$ select (public.hdm_my_entitlements()->>'chatsLeft') $q$);
    t_area := t_area || text 'חודש חדש'; t_name := t_name || text 'בחודש חיוב חדש המכסה מתחדשת (5)';
    t_exp := t_exp || text 'ok:5'; t_got := t_got || r;

    perform public.hdm_admin_cancel(V);
    r := pg_temp.as_user(uV, $q$ select (public.hdm_my_entitlements()->>'plan') || '/' || (public.hdm_my_entitlements()->>'status') $q$);
    t_area := t_area || text 'ביטול'; t_name := t_name || text 'אחרי ביטול: VIP ממשיך עד סוף התקופה';
    t_exp := t_exp || text 'ok:vip/canceled'; t_got := t_got || r;

    perform public.hdm_admin_expire(Q[1]);
    r := pg_temp.as_user(uQ[1], $q$ select (public.hdm_my_entitlements()->>'plan') || '/' || (public.hdm_my_entitlements()->>'status') $q$);
    t_area := t_area || text 'פקיעה'; t_name := t_name || text 'מנוי שפג חוזר לחינם';
    t_exp := t_exp || text 'ok:free/expired'; t_got := t_got || r;

    r := pg_temp.as_user(uQ[1], format($q$ with u as (update public.docs set data = jsonb_set(data, '{messages}', (data->'messages') || jsonb_build_array(jsonb_build_object('senderId', %L, 'text', 'עדיין כאן?', 'ts', 3))) where collection='chats' and id=%L returning 1) select count(*)::text from u $q$, Q[1], pair));
    t_area := t_area || text 'פקיעה'; t_name := t_name || text 'מנוי שפג לא יכול לשלוח הודעות';
    t_exp := t_exp || text 'err:HDM_PLAN_INACTIVE'; t_got := t_got || r;

    r := pg_temp.as_user(uQ[1], format($q$ select jsonb_array_length(data->'messages')::text from public.docs where collection='chats' and id=%L $q$, pair));
    t_area := t_area || text 'פקיעה'; t_name := t_name || text 'מנוי שפג עדיין קורא את ההודעות הקיימות';
    t_exp := t_exp || text 'ok:1'; t_got := t_got || r;

    r := pg_temp.as_user(uQ[1], format($q$ select public.hdm_send_target(%L)::text $q$, V));
    t_area := t_area || text 'פקיעה'; t_name := t_name || text 'מנוי שפג לא יכול לסמן 🎯';
    t_exp := t_exp || text 'err:HDM_PLAN_REQUIRED'; t_got := t_got || r;

    perform public.hdm_admin_set_plan(Q[1], 'plus');
    r := pg_temp.as_user(uQ[1], $q$ select (public.hdm_my_entitlements()->>'plan') $q$);
    t_area := t_area || text 'חידוש'; t_name := t_name || text 'חידוש אחרי פקיעה מחזיר את ההרשאות';
    t_exp := t_exp || text 'ok:plus'; t_got := t_got || r;

    r := (select count(*)::text from public.hdm_subscription_events where profile_id = any(array[B, V, Q[1]]));
    t_area := t_area || text 'יומן'; t_name := t_name || text 'כל שינוי מסלול נרשם ביומן';
    t_exp := t_exp || text '8'; t_got := t_got || r;   -- B: start+upgrade+downgrade, V: start+cancel, Q1: start+expire+start

    -- ================= חסימה =================
    perform pg_temp.as_user(uQ[2], format($q$ insert into public.docs values ('blocks', %L, '{}') returning id $q$, Q[2] || '__' || B));
    r := pg_temp.as_user(uB, format($q$ with u as (update public.docs set data = jsonb_set(data, '{messages}', (data->'messages') || jsonb_build_array(jsonb_build_object('senderId', %L, 'text', 'היי', 'ts', 4))) where collection='chats' and id=%L returning 1) select count(*)::text from u $q$, B, public.hdm_pair_id(B, Q[2])));
    t_area := t_area || text 'חסימה'; t_name := t_name || text 'אחרי חסימה אי אפשר לשלוח הודעה';
    t_exp := t_exp || text 'err:HDM_NOT_AVAILABLE'; t_got := t_got || r;

    r := pg_temp.as_user(uB, format($q$ select count(*)::text from public.docs where collection='profiles' and id=%L $q$, Q[2]));
    t_area := t_area || text 'חסימה'; t_name := t_name || text 'מי שנחסם לא רואה את הפרופיל של החוסם';
    t_exp := t_exp || text 'ok:0'; t_got := t_got || r;

    r := pg_temp.as_user(uB, format($q$ select public.hdm_send_target(%L)::text $q$, B));
    t_area := t_area || text 'עקיפה'; t_name := t_name || text 'אי אפשר לסמן 🎯 את עצמך';
    t_exp := t_exp || text 'err:HDM_NOT_AVAILABLE'; t_got := t_got || r;

    r := pg_temp.as_user(uB, format($q$ select public.hdm_doc('profiles', %L)::text $q$, F));
    t_area := t_area || text 'אבטחה'; t_name := t_name || text 'פונקציות פנימיות לא מחזירות נתונים כשקוראים להן ישירות';
    t_exp := t_exp || text 'ok:'; t_got := t_got || r;

    raise exception 'HDM_TEST_ROLLBACK';
  exception when others then
    if sqlerrm <> 'HDM_TEST_ROLLBACK' then
      t_area := t_area || text 'שגיאה'; t_name := t_name || text 'שגיאה כללית בהרצת הבדיקה';
      t_exp := t_exp || text '—'; t_got := t_got || sqlerrm;
    end if;
  end;
  execute 'reset role';

  return query
    select s.i::int, t_area[s.i], t_name[s.i], t_exp[s.i], t_got[s.i],
           case when t_got[s.i] = t_exp[s.i] then '✅' else '❌' end
      from generate_subscripts(t_name, 1) s(i)
    union all
    select 999, 'סיכום', 'עברו ' || count(*) filter (where t_got[s.i] = t_exp[s.i]) || ' מתוך ' || count(*), '', '',
           case when bool_and(t_got[s.i] = t_exp[s.i]) then '✅' else '❌' end
      from generate_subscripts(t_name, 1) s(i)
    order by 1;
end $$;

select * from pg_temp.hdm_run_tests();
