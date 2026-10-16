-- =====================================================================
-- חיים דרך מספרים — Staging בלבד: הקשחת פרופיל ומחיקת חשבון מלאה
-- להרצה פעם אחת, אחרי 01, 03 ו-04, רק בפרויקט Haim Derech Misparim Staging
-- ⚠️ לפני ההרצה: בשורת הכתובת צריך להופיע ousepgdvzammgkxkweze
--
-- 1. פרופיל: נשמרים רק השדות שהאפליקציה משתמשת בהם. שדה אחר (למשל "plan":"vip" או "isVerified":true)
--    נמחק בשרת לפני השמירה, כך שאי אפשר "להשתיל" במסמך הגלוי נתון שנראה רשמי.
--    בנוסף: אורך מקסימלי לכל שדה טקסט, ותמונה רק כ-data:image או https (אחרת לא נשמרת), עד 800KB.
-- 2. מחיקת חשבון (hdm_delete_my_data): מוחקת גם את משתמש ההתחברות עצמו (האימייל והסיסמה).
--    אם אין לשרת הרשאה לכך — הנתונים נמחקים כרגיל, והתשובה מציינת שמשתמש ההתחברות לא נמחק.
--
-- לא מוחק ולא משנה נתונים קיימים. משפיע רק על כתיבות מכאן והלאה. "הכול או כלום".
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'עצירה: זה לא פרויקט הניסוי. שום דבר לא שונה.';
  end if;
  if not exists (select 1 from public.hdm_staging_marker where version = 'staging_secure_v1_fixes2') then
    raise exception 'עצירה: צריך להריץ קודם את 04_staging_profile_id_fix.sql. שום דבר לא שונה.';
  end if;
  if exists (select 1 from public.hdm_staging_marker where version = 'staging_secure_v1_fixes3') then
    raise exception 'עצירה: התיקון כבר הותקן. שום דבר לא שונה.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. ניקוי הפרופיל הגלוי — רץ אחרי hdm_docs_guard (טריגרים רצים לפי סדר השמות)
-- ---------------------------------------------------------------------
create function public.hdm_profile_clean()
returns trigger language plpgsql set search_path = '' as $$
declare
  d    jsonb := '{}'::jsonb;
  k    text;
  v    jsonb;
  lim  int;
  -- שדה ← אורך מקסימלי (0 = מספר/בוליאני, -1 = רשימה)
  allowed constant jsonb := '{
    "currentName": 60, "age": 3, "location": 80, "occupation": 80, "gender": 20, "lookingFor": 20,
    "interests": 500, "bio": 1500, "height": 3, "maritalStatus": 30, "hasChildren": 10, "childrenCount": 3,
    "smoking": 30, "ageMin": 3, "ageMax": 3, "photoAssetId": 100, "photoUrl": 819200,
    "createdAt": 0, "ageCheckedAt": 0, "ageBlockedAt": 0, "lifePathNumber": 0, "ageBlocked": 0, "likes": -1
  }';
begin
  if new.collection <> 'profiles' then return new; end if;
  for k, v in select * from jsonb_each(coalesce(new.data, '{}'::jsonb)) loop
    continue when not (allowed ? k);
    lim := (allowed->>k)::int;
    if lim = -1 then
      d := d || jsonb_build_object(k, case when jsonb_typeof(v) = 'array' then v else '[]'::jsonb end);
    elsif lim = 0 then
      continue when jsonb_typeof(v) not in ('number', 'boolean', 'string');
      d := d || jsonb_build_object(k, v);
    else
      continue when jsonb_typeof(v) not in ('string', 'number');
      if k = 'photoUrl' then
        continue when v #>> '{}' = '';
        continue when (v #>> '{}') !~ '^(data:image/(jpeg|png|webp|gif);base64,|https://)';   -- פורמט לא נתמך: לא נשמר
        if length(v #>> '{}') > lim then
          raise exception 'HDM_PHOTO_TOO_LARGE' using errcode = 'P0001', hint = 'התמונה גדולה מדי.';
        end if;
        d := d || jsonb_build_object(k, v #>> '{}');
      else
        d := d || jsonb_build_object(k, left(v #>> '{}', lim));
      end if;
    end if;
  end loop;
  new.data := d;
  return new;
end $$;
revoke all on function public.hdm_profile_clean() from public, anon, authenticated;

create trigger hdm_docs_profile_clean
  before insert or update on public.docs
  for each row when (new.collection = 'profiles')
  execute function public.hdm_profile_clean();

-- ---------------------------------------------------------------------
-- 2. מחיקת חשבון: גם משתמש ההתחברות
-- ---------------------------------------------------------------------
create or replace function public.hdm_delete_my_data()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me  text := public.hdm_require_me();
  uid uuid := auth.uid();
  n   int;
  auth_deleted boolean := false;
begin
  delete from public.docs d
   where (d.collection = 'profiles'  and d.id = me)
      or (d.collection in ('interests', 'matches', 'chats', 'blocks') and public.hdm_pair_has(d.id, me))
      or (d.collection = 'chatReads' and public.hdm_pair_has(split_part(d.id, '___', 2), me))
      or (d.collection = '__lease'   and d.id like 'chats/%' and public.hdm_pair_has(substr(d.id, 7), me));
  get diagnostics n = row_count;
  delete from public.hdm_profile_private where profile_id = me;
  delete from public.hdm_chat_openings   where profile_id = me;
  delete from public.hdm_subscriptions   where profile_id = me;
  delete from public.hdm_accounts        where profile_id = me;
  begin
    delete from auth.users where id = uid;
    auth_deleted := found;
  exception when insufficient_privilege then
    auth_deleted := false;
  end;
  return jsonb_build_object('deletedDocs', n, 'authUserDeleted', auth_deleted);
end $$;
revoke all on function public.hdm_delete_my_data() from public, anon;
grant execute on function public.hdm_delete_my_data() to authenticated;

insert into public.hdm_staging_marker (version, note)
values ('staging_secure_v1_fixes3', 'הקשחת פרופיל (שדות מותרים בלבד) ומחיקת משתמש ההתחברות במחיקת חשבון');

commit;

select '✅ הקשחת הפרופיל הותקנה' as "סטטוס",
       (select string_agg(version, ' · ' order by installed_at) from public.hdm_staging_marker) as "מה מותקן";
