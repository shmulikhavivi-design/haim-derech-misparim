-- מחיקה לצמיתות — אישור הבעלים 22.10 11:58: הפרופיל של דינה (p_ba0f9653eca8436c9e68) ו-4 רשומות התחברות
-- (דינה + 3 יתומות). זיהוי לפי מזהה משתמש וגם טביעת md5 של האימייל (האימיילים עצמם לא בקובץ — הריפו ציבורי).
-- בלי מיזוג חשבונות. שמוליק (9f1f6992-… / reg_mupj1bkt75rzke) מוגן ונבדק לפני ואחרי. "הכול או כלום". __FINAL__ = commit / rollback.
begin;
create temp table del_u (uid uuid primary key, em_md5 text not null) on commit drop;
insert into del_u values
  ('7331385e-d6e0-4960-8215-db699b0087ad', 'd461514b8464c9d51cba339ce84d83a9'),   -- דינה
  ('af0712e6-a91c-42b4-be09-339c8af9ac2d', 'da05b7a8d3ede190b4628fe31dfd6ad7'),   -- יתום 1
  ('6e181c56-ad94-4bb4-bd84-29b6aa5dea13', '94a3841c90310cab430d20ea1678820c'),   -- יתום 2
  ('fa2fd1e9-fd25-4984-90e7-a5fe41671960', '6d6d7660519c55a12016e3e8b3d1e1f4');   -- יתום 3
create temp table rep (t text, n int) on commit drop;
create temp table owner_before on commit drop as
  select (select row_to_json(u)::text from (select id, email, encrypted_password, email_confirmed_at, banned_until, deleted_at from auth.users where id = '9f1f6992-d302-44c0-b133-7f6595de9c2a') u) au,
         (select row_to_json(a)::text from public.hdm_accounts a where profile_id = 'reg_mupj1bkt75rzke') acc,
         (select data::text from public.docs where collection = 'profiles' and id = 'reg_mupj1bkt75rzke') prof,
         (select row_to_json(s)::text from public.hdm_subscriptions s where profile_id = 'reg_mupj1bkt75rzke') sub,
         (select count(*) from public.docs where collection in ('interests','matches','chats','blocks','chatReads') and position('reg_mupj1bkt75rzke' in id) > 0) pairs;
do $$
declare n int; t record; pass int; left_ int; uids uuid[] := (select array_agg(uid) from del_u); pids text[];
begin
  -- שמירה על שמוליק
  if '9f1f6992-d302-44c0-b133-7f6595de9c2a'::uuid = any(uids) then raise exception 'עצירה: שמוליק ברשימה'; end if;
  if exists (select 1 from public.hdm_accounts where auth_user_id = any(uids) and profile_id = 'reg_mupj1bkt75rzke') then raise exception 'עצירה: אחד החשבונות משויך לפרופיל של שמוליק'; end if;
  -- כל מזהה תואם בדיוק לטביעת האימייל שאושרה
  if (select count(*) from auth.users u join del_u d on d.uid = u.id and md5(lower(u.email)) = d.em_md5) <> 4 then raise exception 'עצירה: מזהה/אימייל לא תואם'; end if;
  pids := (select coalesce(array_agg(profile_id), '{}') from public.hdm_accounts where auth_user_id = any(uids));
  if exists (select 1 from unnest(pids) p where p = 'reg_mupj1bkt75rzke') then raise exception 'עצירה: פרופיל של שמוליק'; end if;
  if (select count(*) from public.docs where collection = 'profiles' and id = any(pids)) <> 1 then raise exception 'עצירה: ציפיתי לפרופיל אחד בדיוק (דינה)'; end if;
  -- מסמכי האפליקציה של הפרופילים (של דינה; לחשבון היתום השלישי אין פרופיל)
  delete from public.docs d where d.collection = 'profiles' and d.id = any(pids); get diagnostics n = row_count; insert into rep values ('docs:profiles', n);
  delete from public.docs d using unnest(pids) x(me)
   where (d.collection in ('interests', 'matches', 'chats', 'blocks') and public.hdm_pair_has(d.id, x.me))
      or (d.collection = 'chatReads' and public.hdm_pair_has(split_part(d.id, '___', 2), x.me))
      or (d.collection = '__lease' and d.id like 'chats/%' and public.hdm_pair_has(substr(d.id, 7), x.me));
  get diagnostics n = row_count; insert into rep values ('docs:pairs', n);
  delete from public.docs d where d.collection like 'data/users/%' and d.data->>'profileId' = any(pids); get diagnostics n = row_count; insert into rep values ('docs:legacy_account', n);
  for pass in 1..6 loop
    left_ := 0;
    for t in select c.table_name, c.column_name, c.data_type from information_schema.columns c join information_schema.tables tb on tb.table_schema = c.table_schema and tb.table_name = c.table_name and tb.table_type = 'BASE TABLE'
              where c.table_schema = 'public' and c.table_name <> 'docs'
                and c.column_name in ('profile_id', 'peer_id', 'other_profile_id', 'target_profile_id', 'user_id', 'auth_user_id', 'reporter_id')
    loop
      begin
        if t.data_type = 'uuid' then execute format('delete from public.%I where %I = any($1)', t.table_name, t.column_name) using uids;
        else execute format('delete from public.%I where %I = any($1)', t.table_name, t.column_name) using pids; end if;
        get diagnostics n = row_count; if n > 0 then insert into rep values (t.table_name || '.' || t.column_name, n); end if;
      exception when foreign_key_violation then left_ := left_ + 1; end;
    end loop;
    exit when left_ = 0;
  end loop;
  if left_ > 0 then raise exception 'עצירה: נשארו קשרים שלא נמחקו'; end if;
  delete from auth.users where id = any(uids); get diagnostics n = row_count; insert into rep values ('auth.users', n);
  if n <> 4 then raise exception 'עצירה: נמחקו % רשומות התחברות במקום 4', n; end if;
  -- אחרי: נשאר רק שמוליק, ללא שינוי
  if (select count(*) from auth.users) <> 1 or (select count(*) from public.docs where collection = 'profiles') <> 1 then raise exception 'עצירה: לא נשאר רק שמוליק'; end if;
  if (select row_to_json(u)::text from (select id, email, encrypted_password, email_confirmed_at, banned_until, deleted_at from auth.users where id = '9f1f6992-d302-44c0-b133-7f6595de9c2a') u) is distinct from (select au from owner_before)
     or (select row_to_json(a)::text from public.hdm_accounts a where profile_id = 'reg_mupj1bkt75rzke') is distinct from (select acc from owner_before)
     or (select data::text from public.docs where collection = 'profiles' and id = 'reg_mupj1bkt75rzke') is distinct from (select prof from owner_before)
     or (select row_to_json(s)::text from public.hdm_subscriptions s where profile_id = 'reg_mupj1bkt75rzke') is distinct from (select sub from owner_before)
     or (select count(*) from public.docs where collection in ('interests','matches','chats','blocks','chatReads') and position('reg_mupj1bkt75rzke' in id) > 0) <> (select pairs from owner_before)
  then raise exception 'עצירה: החשבון של שמוליק השתנה'; end if;
end $$;
__FINAL__
