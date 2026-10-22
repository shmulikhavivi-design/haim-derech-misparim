-- ניקוי שאריות טכניות — אישור הבעלים 22.10 12:06. נשמרים: שמוליק (פרופיל, חשבון, התחברות, מנוי, אירועי מנוי, תשלומים,
-- אישורי מסמכים, החשבון מהגרסה הקודמת) והדיווח. "הכול או כלום". __FINAL__ = commit / rollback.
begin;
create temp table rep (t text, n int) on commit drop;
create temp table keep_before on commit drop as select
  (select md5(string_agg(collection||'|'||id||'|'||data::text, ',' order by collection, id)) from public.docs where collection in ('profiles', 'reports') or collection like 'data/users/%') docs_keep,
  (select md5(coalesce(string_agg(t, ',' order by t), '')) from (
      select 'acc:'||row_to_json(a)::text t from public.hdm_accounts a union all select 'sub:'||row_to_json(s)::text from public.hdm_subscriptions s
      union all select 'ev:'||row_to_json(e)::text from public.hdm_subscription_events e union all select 'pay:'||row_to_json(p)::text from public.hdm_payments p
      union all select 'ck:'||row_to_json(k)::text from public.hdm_checkouts k union all select 'con:'||row_to_json(c)::text from public.hdm_consents c
      union all select 'priv:'||row_to_json(v)::text from public.hdm_profile_private v union all select 'leg:'||row_to_json(l)::text from public.hdm_legacy_accounts l
      union all select 'tok:'||row_to_json(b)::text from public.hdm_billing_tokens b) z) tables_keep,
  (select md5(string_agg(row_to_json(u)::text, ',')) from (select id, email, encrypted_password, email_confirmed_at, banned_until from auth.users order by id) u) auth_keep,
  (select count(*) from auth.sessions) sessions;
create temp table live on commit drop as select id from public.docs where collection = 'profiles';
create or replace function pg_temp.is_live_pair(p text) returns boolean language sql as $$
  select split_part(p, '__', 1) in (select id from live) and split_part(p, '__', 2) in (select id from live) $$;
do $$ declare n int; begin
  if (select count(*) from live) <> 1 or not exists (select 1 from live where id = 'reg_mupj1bkt75rzke') then raise exception 'עצירה: צפוי פרופיל פעיל אחד (שמוליק)'; end if;
  -- אין קשר לנתונים פעילים: אף רשומה למחיקה אינה בין שני פרופילים קיימים
  if exists (select 1 from public.docs where collection in ('chats','matches','interests','blocks') and pg_temp.is_live_pair(id))
     or exists (select 1 from public.docs where collection = 'chatReads' and pg_temp.is_live_pair(split_part(id, '___', 2)))
     or exists (select 1 from public.docs where collection = '__lease' and id like 'chats/%' and pg_temp.is_live_pair(substr(id, 7)))
     or exists (select 1 from public.hdm_chat_openings where pg_temp.is_live_pair(pair_id))
  then raise exception 'עצירה: נמצאה שיחה/התאמה פעילה'; end if;
  delete from public.docs where collection in ('chats','matches','interests','blocks'); get diagnostics n = row_count; insert into rep values ('docs:chats_matches_interests_blocks', n);
  delete from public.docs where collection = 'chatReads'; get diagnostics n = row_count; insert into rep values ('docs:chatReads', n);
  delete from public.docs where collection = '__lease'; get diagnostics n = row_count; insert into rep values ('docs:__lease', n);
  delete from public.docs where collection = 'chatReadsDebug'; get diagnostics n = row_count; insert into rep values ('docs:chatReadsDebug', n);
  delete from public.docs where collection = 'authSessions'; get diagnostics n = row_count; insert into rep values ('docs:authSessions(old)', n);
  delete from public.hdm_chat_openings where not pg_temp.is_live_pair(pair_id); get diagnostics n = row_count; insert into rep values ('hdm_chat_openings', n);
  -- אחרי: נשמרו בדיוק הדברים שצריך
  if (select md5(string_agg(collection||'|'||id||'|'||data::text, ',' order by collection, id)) from public.docs where collection in ('profiles', 'reports') or collection like 'data/users/%') is distinct from (select docs_keep from keep_before)
     or (select md5(coalesce(string_agg(t, ',' order by t), '')) from (
      select 'acc:'||row_to_json(a)::text t from public.hdm_accounts a union all select 'sub:'||row_to_json(s)::text from public.hdm_subscriptions s
      union all select 'ev:'||row_to_json(e)::text from public.hdm_subscription_events e union all select 'pay:'||row_to_json(p)::text from public.hdm_payments p
      union all select 'ck:'||row_to_json(k)::text from public.hdm_checkouts k union all select 'con:'||row_to_json(c)::text from public.hdm_consents c
      union all select 'priv:'||row_to_json(v)::text from public.hdm_profile_private v union all select 'leg:'||row_to_json(l)::text from public.hdm_legacy_accounts l
      union all select 'tok:'||row_to_json(b)::text from public.hdm_billing_tokens b) z) is distinct from (select tables_keep from keep_before)
     or (select md5(string_agg(row_to_json(u)::text, ',')) from (select id, email, encrypted_password, email_confirmed_at, banned_until from auth.users order by id) u) is distinct from (select auth_keep from keep_before)
     or (select count(*) from auth.sessions) <> (select sessions from keep_before)
  then raise exception 'עצירה: נתון שצריך להישמר השתנה'; end if;
  if (select string_agg(distinct case when collection like 'data/users/%' then 'data/users' else collection end, ',' order by case when collection like 'data/users/%' then 'data/users' else collection end) from public.docs) <> 'data/users,profiles,reports'
    then raise exception 'עצירה: נשארו סוגי רשומות לא צפויים'; end if;
end $$;
__FINAL__
