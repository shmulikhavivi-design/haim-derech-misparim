-- מחיקה לצמיתות של 3 פרופילים — אישור הבעלים 22.10 11:25: reg_muwrknqi6g320q, reg_muv7ffi3345nmx, reg_musrb6jotbe85d
-- לפי מדיניות המחיקה (כמו hdm_delete_my_data): פרופיל, 🎯, התאמות, שיחות והודעות (גם אצל הצד השני), סימוני קריאה, חסימות,
-- אישורי מסמכים, מנוי, חשבון, החשבון מהגרסה הקודמת, ורשומת ההתחברות. לא נוגע בשום משתמש אחר. "הכול או כלום".
-- __FINAL__ מוחלף ב-commit (ביצוע) או ב-raise+rollback (חזרה).
begin;
create temp table del_ids (pid text primary key) on commit drop;
insert into del_ids values ('reg_muwrknqi6g320q'), ('reg_muv7ffi3345nmx'), ('reg_musrb6jotbe85d');
create temp table del_uids on commit drop as select a.auth_user_id uid from public.hdm_accounts a join del_ids d on d.pid = a.profile_id where a.auth_user_id is not null;
create temp table rep (t text, n int) on commit drop;
create temp table keep_before on commit drop as
  select (select count(*) from auth.users where id not in (select uid from del_uids)) au,
         (select count(*) from public.docs where collection = 'profiles' and id not in (select pid from del_ids)) pr,
         (select md5(string_agg(row_to_json(s)::text, ',' order by profile_id)) from public.hdm_subscriptions s where profile_id not in (select pid from del_ids)) subs,
         (select md5(string_agg(data::text, ',' order by id)) from public.docs where collection = 'profiles' and id not in (select pid from del_ids)) profs;
do $$
declare n int; t record; pass int; left_ int; ids text[] := (select array_agg(pid) from del_ids); uids uuid[] := (select coalesce(array_agg(uid), '{}') from del_uids);
begin
  if (select count(*) from public.docs where collection = 'profiles' and id = any(ids)) <> 3 then raise exception 'עצירה: לא נמצאו בדיוק 3 הפרופילים'; end if;
  if 'reg_mupj1bkt75rzke' = any(ids) then raise exception 'עצירה: שמוליק ברשימה'; end if;
  -- מסמכי האפליקציה
  delete from public.docs d where d.collection = 'profiles' and d.id = any(ids); get diagnostics n = row_count; insert into rep values ('docs:profiles', n);
  delete from public.docs d using unnest(ids) x(me)
   where (d.collection in ('interests', 'matches', 'chats', 'blocks') and public.hdm_pair_has(d.id, x.me))
      or (d.collection = 'chatReads' and public.hdm_pair_has(split_part(d.id, '___', 2), x.me))
      or (d.collection = '__lease' and d.id like 'chats/%' and public.hdm_pair_has(substr(d.id, 7), x.me));
  get diagnostics n = row_count; insert into rep values ('docs:pairs', n);
  delete from public.docs d where d.collection like 'data/users/%' and d.data->>'profileId' = any(ids); get diagnostics n = row_count; insert into rep values ('docs:legacy_account', n);
  -- כל טבלה ב-public שמפנה לפרופיל או למשתמש (כמה סבבים, בגלל קשרי גומלין)
  for pass in 1..6 loop
    left_ := 0;
    for t in select c.table_name, c.column_name, c.data_type from information_schema.columns c join information_schema.tables tb on tb.table_schema = c.table_schema and tb.table_name = c.table_name and tb.table_type = 'BASE TABLE'
              where c.table_schema = 'public' and c.table_name <> 'docs'
                and c.column_name in ('profile_id', 'peer_id', 'other_profile_id', 'target_profile_id', 'user_id', 'auth_user_id', 'reporter_id')
    loop
      begin
        if t.data_type = 'uuid' then execute format('delete from public.%I where %I = any($1)', t.table_name, t.column_name) using uids;
        else execute format('delete from public.%I where %I = any($1)', t.table_name, t.column_name) using ids; end if;
        get diagnostics n = row_count; if n > 0 then insert into rep values (t.table_name || '.' || t.column_name, n); end if;
      exception when foreign_key_violation then left_ := left_ + 1; end;
    end loop;
    exit when left_ = 0;
  end loop;
  if left_ > 0 then raise exception 'עצירה: נשארו קשרים שלא נמחקו'; end if;
  -- רשומת ההתחברות (נועה כהן)
  delete from auth.users where id = any(uids); get diagnostics n = row_count; insert into rep values ('auth.users', n);
  -- אימות
  if exists (select 1 from public.docs where collection = 'profiles' and id = any(ids)) then raise exception 'עצירה: פרופיל נשאר'; end if;
  if (select count(*) from auth.users) <> (select au from keep_before) then raise exception 'עצירה: מספר משתמשי ההתחברות האחרים השתנה'; end if;
  if (select count(*) from public.docs where collection = 'profiles') <> (select pr from keep_before) then raise exception 'עצירה: פרופיל אחר השתנה'; end if;
  if (select md5(string_agg(row_to_json(s)::text, ',' order by profile_id)) from public.hdm_subscriptions s) is distinct from (select subs from keep_before) then raise exception 'עצירה: מנוי של משתמש אחר השתנה'; end if;
  if (select md5(string_agg(data::text, ',' order by id)) from public.docs where collection = 'profiles') is distinct from (select profs from keep_before) then raise exception 'עצירה: פרטי פרופיל אחר השתנו'; end if;
  if not exists (select 1 from public.hdm_accounts where profile_id = 'reg_mupj1bkt75rzke') then raise exception 'עצירה: החשבון של שמוליק'; end if;
end $$;
__FINAL__
