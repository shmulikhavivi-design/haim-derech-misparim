-- =====================================================================
-- חיים דרך מספרים — סביבת ניסוי (Staging): הקמה מלאה ומאובטחת
-- גרסה 1 · להרצה פעם אחת, רק בפרויקט Haim Derech Misparim Staging
--
-- ⚠️ לפני ההרצה: בראש המסך ב-Supabase צריך להיות כתוב
--    Haim Derech Misparim Staging   (ולא Haim Derech Misparim)
--
-- הגנות מובנות:
--   * אם כבר קיימת טבלת docs (כמו בפרויקט הפעיל) — הקובץ נעצר ולא משנה כלום.
--   * אם הקובץ כבר הורץ בפרויקט הזה — הקובץ נעצר ולא משנה כלום.
--   * הכול רץ "הכול או כלום": שגיאה אחת = שום דבר לא נשמר.
--
-- מה נוצר:
--   * docs — אותו מבנה כמו בפרויקט הפעיל, אבל עם RLS: כל משתמש מזוהה לפי
--     ההתחברות שלו ב-Supabase Auth ורואה / כותב רק את מה שמותר לו.
--   * hdm_accounts        — קישור קבוע בין משתמש Auth לבין פרופיל (נקבע בשרת בלבד).
--   * hdm_profile_private — תאריך לידה, שם מלידה ומספרים נומרולוגיים (סגור לגמרי).
--   * hdm_plans           — ארבעת המסלולים, המחירים וההרשאות.
--   * hdm_subscriptions   — המסלול של כל פרופיל (שינוי רק מה-SQL Editor).
--   * hdm_subscription_events — יומן שדרוגים / ביטולים / פקיעות.
--   * hdm_chat_openings   — יומן שיחות חדשות (מכסת 5 בחודש במסלול בסיסי).
--   * פונקציות שרת (RPC) לכל פעולה שמוגבלת לפי מסלול.
--
-- מה לא נוצר / לא נעשה:
--   * שום חיוב ושום פרטי תשלום.
--   * שום נתון אמיתי. אין כאן משתמשים בכלל.
--   * לא נוגע בפרויקט הפעיל.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. הגנה: רק בפרויקט ניסוי ריק
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.docs') is not null then
    raise exception 'עצירה: קיימת כבר טבלת docs — ייתכן שזה הפרויקט הפעיל. שום דבר לא שונה.';
  end if;
  if to_regclass('public.hdm_staging_marker') is not null then
    raise exception 'עצירה: ההקמה כבר בוצעה בפרויקט הזה. שום דבר לא שונה.';
  end if;
end $$;

create table public.hdm_staging_marker (
  installed_at timestamptz not null default now(),
  version      text not null default 'staging_secure_v1',
  note         text not null default 'פרויקט ניסוי — אין כאן משתמשים אמיתיים'
);
insert into public.hdm_staging_marker default values;

-- ---------------------------------------------------------------------
-- 1. טבלאות
-- ---------------------------------------------------------------------
create table public.docs (
  collection text        not null,
  id         text        not null,
  data       jsonb       not null default '{}'::jsonb,
  updated_at timestamptz default now(),
  primary key (collection, id)
);

create table public.hdm_accounts (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  profile_id   text not null unique check (profile_id ~ '^[A-Za-z0-9_-]{3,64}$' and position('__' in profile_id) = 0),
  created_at   timestamptz not null default now()
);

create table public.hdm_profile_private (
  profile_id         text primary key,
  birthdate          date,
  birth_first_name   text,
  birth_last_name    text,
  life_path          int,
  birthday_number    int,
  vowel_number       int,
  consonants_number  int,
  expression_number  int,
  age_blocked        boolean not null default false,
  updated_at         timestamptz not null default now()
);

create table public.hdm_plans (
  plan                     text primary key,
  sort_order               int  not null,
  name_he                  text not null,
  price_agorot             int  not null,              -- 2990 = ₪29.90
  can_rate                 boolean not null,           -- דירוג התאמה
  rating_details           boolean not null,           -- הסבר / פירוט הדירוג
  can_target               boolean not null,           -- סימון 🎯
  can_chat                 boolean not null,           -- צ'אט אחרי 🎯 הדדי
  monthly_new_chats        int,                        -- NULL = ללא הגבלה
  see_who_targeted         boolean not null,           -- מי סימן אותי 🎯
  extended_analysis        text not null check (extended_analysis in ('none', 'after_mutual', 'after_my_target')),
  limor_discount_pct       int  not null default 0
);
insert into public.hdm_plans values
  ('free',  1, 'חינם',  0,    false, false, false, false, 0,    false, 'none',            0),
  ('basic', 2, 'בסיסי', 2990, true,  false, true,  true,  5,    false, 'none',            0),
  ('plus',  3, 'פלוס',  4890, true,  true,  true,  true,  null, true,  'after_mutual',    0),
  ('vip',   4, 'VIP',   7990, true,  true,  true,  true,  null, true,  'after_my_target', 30);

create table public.hdm_subscriptions (
  profile_id         text primary key,
  plan               text not null references public.hdm_plans(plan),
  status             text not null default 'active' check (status in ('active', 'canceled', 'expired')),
  period_anchor      timestamptz not null default now(),  -- תחילת המנוי; ממנו נגזר חודש החיוב
  current_period_end timestamptz,                          -- עד מתי המנוי בתוקף
  canceled_at        timestamptz,
  source             text not null default 'test' check (source in ('test', 'manual', 'payment')),
  note               text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table public.hdm_subscription_events (
  id         bigint generated always as identity primary key,
  profile_id text not null,
  action     text not null,           -- start / upgrade / downgrade / renew / cancel / expire
  from_plan  text,
  to_plan    text,
  at         timestamptz not null default now(),
  note       text
);

create table public.hdm_chat_openings (
  profile_id text not null,
  pair_id    text not null,
  plan       text not null,
  opened_at  timestamptz not null default now(),
  primary key (profile_id, pair_id)
);
create index hdm_chat_openings_by_time on public.hdm_chat_openings (profile_id, opened_at);

-- ---------------------------------------------------------------------
-- 2. פונקציות עזר (פנימיות — לא נגישות לאפליקציה)
-- ---------------------------------------------------------------------

-- הפרופיל של המשתמש המחובר (לפי ההתחברות ב-Supabase Auth, לא לפי מה שהאפליקציה שולחת)
create function public.hdm_me()
returns text language sql stable security definer set search_path = '' as $$
  select a.profile_id from public.hdm_accounts a where a.auth_user_id = auth.uid()
$$;

create function public.hdm_require_me()
returns text language plpgsql stable security definer set search_path = '' as $$
declare v text := public.hdm_me();
begin
  if v is null then
    raise exception 'HDM_NOT_SIGNED_IN' using errcode = 'P0001', hint = 'נדרשת התחברות.';
  end if;
  return v;
end $$;

-- האם המשתמש p הוא אחד משני הצדדים במזהה זוג "a__b"
create function public.hdm_pair_has(p_pair text, p text)
returns boolean language sql immutable set search_path = '' as $$
  select p is not null and p <> ''
     and split_part(p_pair, '__', 3) = ''
     and (split_part(p_pair, '__', 1) = p or split_part(p_pair, '__', 2) = p)
$$;

create function public.hdm_pair_id(a text, b text)
returns text language sql immutable set search_path = '' as $$
  select case when a < b then a || '__' || b else b || '__' || a end
$$;

-- נקראת רק מתוך הטריגר (pg_trigger_depth > 0); קריאה ישירה מהאפליקציה מחזירה NULL
create function public.hdm_doc(p_col text, p_id text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select d.data from public.docs d where d.collection = p_col and d.id = p_id and pg_trigger_depth() > 0
$$;

create function public.hdm_profile_exists(p text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.docs d where d.collection = 'profiles' and d.id = p)
$$;

-- חסימה בכל אחד מהכיוונים
create function public.hdm_blocked_between(a text, b text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.docs d where d.collection = 'blocks' and d.id in (a || '__' || b, b || '__' || a))
$$;

-- האם p_owner חסם אותי (המשתמש המחובר)
create function public.hdm_blocked_me(p_owner text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.docs d where d.collection = 'blocks' and d.id = p_owner || '__' || public.hdm_me())
$$;

create function public.hdm_is_age_blocked(p text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select pp.age_blocked from public.hdm_profile_private pp where pp.profile_id = p), false)
$$;

create function public.hdm_has_interest(p_from text, p_to text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.docs d where d.collection = 'interests' and d.id = p_from || '__' || p_to)
$$;

create function public.hdm_is_mutual(a text, b text)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.hdm_has_interest(a, b) and public.hdm_has_interest(b, a)
$$;

-- ---- נומרולוגיה: העתקה מדויקת של החישובים שבאפליקציה ----
create function public.hdm_digit_sum(s text)
returns int language sql immutable set search_path = '' as $$
  select coalesce(sum(c::int), 0)::int
    from regexp_split_to_table(regexp_replace(coalesce(s, ''), '[^0-9]', '', 'g'), '') c
   where c <> ''
$$;

create function public.hdm_reduce(n int)
returns int language plpgsql immutable set search_path = '' as $$
begin
  if n is null then return null; end if;
  while n > 9 loop n := public.hdm_digit_sum(n::text); end loop;
  return n;
end $$;

create function public.hdm_life_path(b date)
returns int language plpgsql immutable set search_path = '' as $$
declare s int;
begin
  if b is null then return null; end if;
  s := public.hdm_digit_sum(to_char(b, 'YYYYMMDD'));
  while s > 9 and s not in (11, 22, 33) loop s := public.hdm_digit_sum(s::text); end loop;
  return s;
end $$;

create function public.hdm_birthday_number(b date)
returns int language sql immutable set search_path = '' as $$
  select case when b is null then null else public.hdm_reduce(public.hdm_digit_sum(extract(day from b)::int::text)) end
$$;

-- kind: 'all' = שם מלא, 'vowels' = א/ה/ו/י, 'consonants' = כל השאר
create function public.hdm_name_number(p_name text, kind text)
returns int language plpgsql immutable set search_path = '' as $$
declare
  ch  text;
  v   int;
  tot int := 0;
begin
  if p_name is null then return null; end if;
  foreach ch in array regexp_split_to_array(p_name, '') loop
    v := case ch
      when 'א' then 1 when 'ב' then 2 when 'ג' then 3 when 'ד' then 4 when 'ה' then 5
      when 'ו' then 6 when 'ז' then 7 when 'ח' then 8 when 'ט' then 9 when 'י' then 10
      when 'כ' then 20 when 'ך' then 20 when 'ל' then 30 when 'מ' then 40 when 'ם' then 40
      when 'נ' then 50 when 'ן' then 50 when 'ס' then 60 when 'ע' then 70 when 'פ' then 80
      when 'ף' then 80 when 'צ' then 90 when 'ץ' then 90 when 'ק' then 100 when 'ר' then 200
      when 'ש' then 300 when 'ת' then 400 else 0 end;
    if v = 0 then continue; end if;
    if kind = 'vowels'     and ch not in ('א', 'ה', 'ו', 'י') then continue; end if;
    if kind = 'consonants' and ch     in ('א', 'ה', 'ו', 'י') then continue; end if;
    tot := tot + v;
  end loop;
  if tot = 0 then return null; end if;
  return public.hdm_reduce(public.hdm_digit_sum(tot::text));
end $$;

create function public.hdm_age_years(b date)
returns int language sql stable set search_path = '' as $$
  select extract(year from age((now() at time zone 'Asia/Jerusalem')::date, b))::int
$$;

-- שילוב שני מספרים בקטגוריה (כמו combineCategory באפליקציה)
create function public.hdm_combine(a int, b int)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare r int;
begin
  if a is null or b is null or a = 0 or b = 0 then return null; end if;
  r := public.hdm_reduce(a + b);
  return jsonb_build_object('a', a, 'b', b, 'rawSum', a + b, 'reduced', r,
                            'karmic', (a + b) in (13, 14, 16, 19), 'good', r in (2, 4, 6));
end $$;

-- חישוב התאמה מלא בין שני פרופילים (כמו overallCompatibility). פנימי בלבד.
create function public.hdm_compat(p_me text, p_other text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  m public.hdm_profile_private%rowtype;
  o public.hdm_profile_private%rowtype;
  cats jsonb := '[]'::jsonb;
  c jsonb;
  good int := 0;
  karmic int := 0;
  k text; lbl text;
  pairs text[][] := array[
    ['lifePath',   'מספר דרך חיים'],
    ['birthday',   'מספר יום לידה'],
    ['vowels',     'אותיות הנשמה (א-ה-ו-י)'],
    ['consonants', 'עיצורים'],
    ['fullName',   'שם מלא']];
  i int;
begin
  select * into m from public.hdm_profile_private where profile_id = p_me;
  select * into o from public.hdm_profile_private where profile_id = p_other;
  if m.profile_id is null or m.life_path is null then
    raise exception 'HDM_PROFILE_INCOMPLETE' using errcode = 'P0001', hint = 'נדרש להשלים תאריך לידה ושם מלידה.';
  end if;
  if o.profile_id is null or o.life_path is null then
    return null;
  end if;
  for i in 1 .. 5 loop
    k := pairs[i][1]; lbl := pairs[i][2];
    c := case k
      when 'lifePath'   then public.hdm_combine(m.life_path,         o.life_path)
      when 'birthday'   then public.hdm_combine(m.birthday_number,   o.birthday_number)
      when 'vowels'     then public.hdm_combine(m.vowel_number,      o.vowel_number)
      when 'consonants' then public.hdm_combine(m.consonants_number, o.consonants_number)
      when 'fullName'   then public.hdm_combine(m.expression_number, o.expression_number) end;
    continue when c is null;
    c := c || jsonb_build_object('key', k, 'label', lbl);
    if (c->>'good')::boolean then good := good + 1; end if;
    if (c->>'karmic')::boolean then karmic := karmic + 1; end if;
    cats := cats || jsonb_build_array(c);
  end loop;
  return jsonb_build_object(
    'goodCount',   good,
    'karmicCount', karmic,
    'score',       case good when 0 then 55 when 1 then 75 when 2 then 88 when 3 then 92 when 4 then 96 when 5 then 99 else 60 end,
    'label',       case when good >= 2 then 'התאמה מצוינת' when good = 1 then 'התאמה טובה' else 'התאמה חלשה' end,
    'categories',  cats);
end $$;

-- ---- מנויים ----
-- תחילת חודש החיוב הנוכחי לפי יום תחילת המנוי
create function public.hdm_period_start(anchor timestamptz, at_time timestamptz default now())
returns timestamptz language plpgsql stable set search_path = '' as $$
declare n int;
begin
  if anchor is null then return null; end if;
  if at_time <= anchor then return anchor; end if;
  n := (extract(year from age(at_time, anchor)) * 12 + extract(month from age(at_time, anchor)))::int;
  return anchor + make_interval(months => n);
end $$;

-- המסלול בפועל: מנוי שבוטל ממשיך עד סוף התקופה; מנוי שפג = חינם
create function public.hdm_plan_of(p text)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce((
    select s.plan from public.hdm_subscriptions s
     where s.profile_id = p
       and s.status in ('active', 'canceled')
       and (s.current_period_end is null or s.current_period_end > now())
  ), 'free')
$$;

create function public.hdm_plan_row(p text)
returns public.hdm_plans language sql stable security definer set search_path = '' as $$
  select pl.* from public.hdm_plans pl where pl.plan = public.hdm_plan_of(p)
$$;

create function public.hdm_chats_used(p text)
returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int
    from public.hdm_chat_openings o
    join public.hdm_subscriptions s on s.profile_id = o.profile_id
   where o.profile_id = p
     and o.opened_at >= public.hdm_period_start(s.period_anchor)
$$;

create function public.hdm_plan_error(p_feature text)
returns void language plpgsql set search_path = '' as $$
begin
  raise exception 'HDM_PLAN_REQUIRED' using errcode = 'P0001',
    hint = case p_feature
      when 'rate'     then 'דירוג התאמה זמין מהמסלול הבסיסי ומעלה.'
      when 'target'   then 'סימון 🎯 זמין מהמסלול הבסיסי ומעלה.'
      when 'chat'     then 'שיחות זמינות מהמסלול הבסיסי ומעלה.'
      when 'who'      then 'צפייה במי שסימן אותך 🎯 זמינה במסלול פלוס ומעלה.'
      when 'extended' then 'ניתוח נומרולוגי מורחב זמין במסלול פלוס ומעלה.'
      else 'הפעולה אינה כלולה במסלול הנוכחי.' end;
end $$;

-- ---------------------------------------------------------------------
-- 3. הכתיבה לטבלת docs: בדיקות בשרת (טריגר)
-- ---------------------------------------------------------------------

-- פרופיל: הגבלת גיל 18+, העברת פרטי לידה לטבלה הסגורה, חישוב המספרים בשרת
create function public.hdm_normalize_profile(p_id text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  d      jsonb := coalesce(p_data, '{}'::jsonb);
  prv    public.hdm_profile_private%rowtype;
  b_txt  text  := nullif(btrim(coalesce(d->>'birthdate', '')), '');
  b      date;
  fn     text;
  ln     text;
  a      int;
  existed boolean;
begin
  if pg_trigger_depth() = 0 then raise exception 'HDM_INTERNAL_ONLY' using errcode = 'P0001'; end if;
  select * into prv from public.hdm_profile_private where profile_id = p_id;
  existed := prv.profile_id is not null;

  -- חשבון חסום נשאר חסום
  if existed and prv.age_blocked then
    if b_txt is not null then
      raise exception 'HDM_AGE_BLOCKED' using errcode = 'P0001',
        hint = 'הכניסה לאפליקציית חיים דרך מספרים מותרת מגיל 18 ומעלה בלבד.';
    end if;
    d := d - array['birthdate','birthFirstName','birthLastName','lifePathNumber','expressionNumber',
                   'birthdayNumber','vowelNumber','consonantsNumber','age'];
    return d || '{"ageBlocked": true, "likes": []}'::jsonb;
  end if;

  if b_txt is null then
    if coalesce(d->>'ageBlocked', '') = 'true' then
      insert into public.hdm_profile_private (profile_id, age_blocked) values (p_id, true)
      on conflict (profile_id) do update set age_blocked = true, updated_at = now();
      d := d - array['birthdate','birthFirstName','birthLastName','lifePathNumber','expressionNumber',
                     'birthdayNumber','vowelNumber','consonantsNumber','age'];
      return d || '{"ageBlocked": true, "likes": []}'::jsonb;
    end if;
    if not existed or prv.birthdate is null then
      raise exception 'HDM_BIRTHDATE_REQUIRED' using errcode = 'P0001', hint = 'נדרש תאריך לידה.';
    end if;
    b := prv.birthdate;
  else
    if b_txt !~ '^\d{4}-\d{2}-\d{2}$' then
      raise exception 'HDM_BIRTHDATE_INVALID' using errcode = 'P0001', hint = 'תאריך הלידה אינו תקין.';
    end if;
    begin
      b := b_txt::date;
    exception when others then
      raise exception 'HDM_BIRTHDATE_INVALID' using errcode = 'P0001', hint = 'תאריך הלידה אינו תקין.';
    end;
    if b > (now() at time zone 'Asia/Jerusalem')::date or b < date '1900-01-01' then
      raise exception 'HDM_BIRTHDATE_INVALID' using errcode = 'P0001', hint = 'תאריך הלידה אינו תקין.';
    end if;
  end if;

  a := public.hdm_age_years(b);
  if a < 18 then
    raise exception 'HDM_UNDERAGE' using errcode = 'P0001',
      hint = 'הכניסה לאפליקציית חיים דרך מספרים מותרת מגיל 18 ומעלה בלבד.';
  end if;

  fn := coalesce(nullif(btrim(coalesce(d->>'birthFirstName', '')), ''), prv.birth_first_name);
  ln := coalesce(nullif(btrim(coalesce(d->>'birthLastName',  '')), ''), prv.birth_last_name);

  insert into public.hdm_profile_private as t
    (profile_id, birthdate, birth_first_name, birth_last_name,
     life_path, birthday_number, vowel_number, consonants_number, expression_number, updated_at)
  values
    (p_id, b, fn, ln,
     public.hdm_life_path(b), public.hdm_birthday_number(b),
     public.hdm_name_number(coalesce(fn, '') || coalesce(ln, ''), 'vowels'),
     public.hdm_name_number(coalesce(fn, '') || coalesce(ln, ''), 'consonants'),
     public.hdm_name_number(coalesce(fn, '') || coalesce(ln, ''), 'all'),
     now())
  on conflict (profile_id) do update set
     birthdate = excluded.birthdate, birth_first_name = excluded.birth_first_name,
     birth_last_name = excluded.birth_last_name, life_path = excluded.life_path,
     birthday_number = excluded.birthday_number, vowel_number = excluded.vowel_number,
     consonants_number = excluded.consonants_number, expression_number = excluded.expression_number,
     updated_at = now();

  -- מה שנשאר גלוי בפרופיל: גיל ומספר דרך החיים (כמו בכרטיס היום). כל השאר נמחק מהמסמך הגלוי.
  d := d - array['birthdate','birthFirstName','birthLastName','expressionNumber','birthdayNumber',
                 'vowelNumber','consonantsNumber','ageBlocked'];
  return d || jsonb_build_object('age', a::text, 'lifePathNumber', public.hdm_life_path(b), 'likes', '[]'::jsonb);
end $$;

-- שיחה: אפשר רק להוסיף הודעות חדשות בשמך, עם מנוי פעיל ובלי חסימה
create function public.hdm_check_chat_write(p_id text, p_old jsonb, p_new jsonb, p_me text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  old_msgs jsonb := case when jsonb_typeof(p_old->'messages') = 'array' then p_old->'messages' else '[]'::jsonb end;
  new_msgs jsonb := case when jsonb_typeof(p_new->'messages') = 'array' then p_new->'messages' else null end;
  n_old int; n_new int; i int;
  m jsonb;
  other text;
begin
  if pg_trigger_depth() = 0 then raise exception 'HDM_INTERNAL_ONLY' using errcode = 'P0001'; end if;
  if new_msgs is null then
    -- שינוי שלא נוגע בהודעות (למשל updatedAt): נשמרים רק הנתונים הקיימים
    return p_old || jsonb_build_object('updatedAt', (extract(epoch from now()) * 1000)::bigint);
  end if;
  n_old := jsonb_array_length(old_msgs);
  n_new := jsonb_array_length(new_msgs);
  if n_new < n_old then
    raise exception 'HDM_CHAT_HISTORY_LOCKED' using errcode = 'P0001', hint = 'אי אפשר למחוק הודעות קיימות.';
  end if;
  for i in 0 .. n_old - 1 loop
    if new_msgs->i is distinct from old_msgs->i then
      raise exception 'HDM_CHAT_HISTORY_LOCKED' using errcode = 'P0001', hint = 'אי אפשר לשנות הודעות קיימות.';
    end if;
  end loop;
  if n_new > n_old then
    other := case when split_part(p_id, '__', 1) = p_me then split_part(p_id, '__', 2) else split_part(p_id, '__', 1) end;
    if public.hdm_blocked_between(p_me, other) then
      raise exception 'HDM_NOT_AVAILABLE' using errcode = 'P0001', hint = 'לא ניתן לשלוח הודעה למשתמש הזה.';
    end if;
    if not (public.hdm_plan_row(p_me)).can_chat then
      raise exception 'HDM_PLAN_INACTIVE' using errcode = 'P0001',
        hint = 'שליחת הודעות זמינה למנויים פעילים. השיחה שמורה.';
    end if;
    if n_new - n_old > 20 then
      raise exception 'HDM_TOO_MANY_MESSAGES' using errcode = 'P0001', hint = 'יותר מדי הודעות בבת אחת.';
    end if;
    for i in n_old .. n_new - 1 loop
      m := new_msgs->i;
      if jsonb_typeof(m) <> 'object' or (m->>'senderId') is distinct from p_me then
        raise exception 'HDM_SENDER_MISMATCH' using errcode = 'P0001', hint = 'אפשר לשלוח הודעות רק בשמך.';
      end if;
      if jsonb_typeof(m->'text') <> 'string' or length(m->>'text') = 0 or length(m->>'text') > 2000 then
        raise exception 'HDM_MESSAGE_INVALID' using errcode = 'P0001', hint = 'הודעה ריקה או ארוכה מדי.';
      end if;
    end loop;
  end if;
  -- המשתתפים, יוצר השיחה ותאריך הפתיחה נשמרים מהשרת בלבד
  return p_old || jsonb_build_object('messages', new_msgs, 'updatedAt', (extract(epoch from now()) * 1000)::bigint);
end $$;

-- הטריגר עצמו. פעולות שמגיעות מפונקציות השרת (RPC) או מה-SQL Editor נחשבות מהימנות;
-- פעולות שמגיעות ישירות מהאפליקציה (anon / authenticated) נבדקות.
create function public.hdm_docs_guard()
returns trigger language plpgsql set search_path = '' as $$
declare
  trusted boolean := current_user not in ('anon', 'authenticated');
  me      text;
  old_data jsonb;
begin
  if tg_op = 'UPDATE' and new.id is distinct from old.id or tg_op = 'UPDATE' and new.collection is distinct from old.collection then
    raise exception 'HDM_READONLY_KEY' using errcode = 'P0001';
  end if;
  new.updated_at := now();

  if new.collection = 'profiles' then
    new.data := public.hdm_normalize_profile(new.id, new.data);
    return new;
  end if;

  if trusted then
    return new;
  end if;
  me := public.hdm_require_me();

  if tg_op = 'UPDATE' then
    old_data := old.data;
  else
    old_data := public.hdm_doc(new.collection, new.id);   -- upsert: ייתכן שהמסמך כבר קיים
  end if;

  if new.collection = 'chats' then
    if old_data is null then
      raise exception 'HDM_CHAT_NOT_OPEN' using errcode = 'P0001',
        hint = 'שיחה נפתחת רק אחרי 🎯 הדדי (דרך hdm_send_target / hdm_open_chat).';
    end if;
    new.data := public.hdm_check_chat_write(new.id, old_data, new.data, me);
    return new;
  end if;

  if new.collection = 'blocks' then
    if split_part(new.id, '__', 2) = '' or split_part(new.id, '__', 2) = me
       or not public.hdm_profile_exists(split_part(new.id, '__', 2)) then
      raise exception 'HDM_INVALID_TARGET' using errcode = 'P0001';
    end if;
    new.data := jsonb_build_object('by', me, 'target', split_part(new.id, '__', 2),
                                   'ts', (extract(epoch from now()) * 1000)::bigint);
    return new;
  end if;

  if new.collection = 'reports' then
    if old_data is not null then
      raise exception 'HDM_READONLY' using errcode = 'P0001';
    end if;
    new.data := jsonb_build_object(
      'by', me,
      'target', left(coalesce(new.data->>'target', ''), 64),
      'reason', left(coalesce(new.data->>'reason', ''), 100),
      'details', left(coalesce(new.data->>'details', ''), 500),
      'context', left(coalesce(new.data->>'context', ''), 100),
      'ts', (extract(epoch from now()) * 1000)::bigint,
      'status', 'new');
    return new;
  end if;

  if new.collection = 'chatReads' then
    new.data := jsonb_build_object('lastRead', new.data->'lastRead');
    return new;
  end if;

  return new;
end $$;

create trigger hdm_docs_guard
  before insert or update on public.docs
  for each row execute function public.hdm_docs_guard();

-- ---------------------------------------------------------------------
-- 4. RLS על docs — מה מותר לאפליקציה לקרוא ולכתוב ישירות
--    (interests, matches וכל השאר נכתבים רק דרך פונקציות השרת)
-- ---------------------------------------------------------------------
alter table public.docs enable row level security;

-- פרופילים: כל משתמש מחובר רואה פרופילים ותמונות (גם בחינם), חוץ ממי שחסם אותו ומחשבונות חסומי גיל
create policy profiles_read on public.docs for select to authenticated
  using (collection = 'profiles'
         and (id = public.hdm_me()
              or (public.hdm_me() is not null
                  and not public.hdm_blocked_me(id)
                  and coalesce(data->>'ageBlocked', '') <> 'true')));
create policy profiles_insert on public.docs for insert to authenticated
  with check (collection = 'profiles' and id = public.hdm_me());
create policy profiles_update on public.docs for update to authenticated
  using (collection = 'profiles' and id = public.hdm_me())
  with check (collection = 'profiles' and id = public.hdm_me());

-- התאמות: קריאה בלבד, רק של עצמי
create policy matches_read on public.docs for select to authenticated
  using (collection = 'matches' and public.hdm_pair_has(id, public.hdm_me()));

-- שיחות: קריאה וכתיבה רק למשתתפים (הוספת הודעות נבדקת בטריגר; שיחה חדשה רק דרך השרת)
create policy chats_read on public.docs for select to authenticated
  using (collection = 'chats' and public.hdm_pair_has(id, public.hdm_me()));
create policy chats_insert on public.docs for insert to authenticated
  with check (collection = 'chats' and public.hdm_pair_has(id, public.hdm_me()));
create policy chats_update on public.docs for update to authenticated
  using (collection = 'chats' and public.hdm_pair_has(id, public.hdm_me()))
  with check (collection = 'chats' and public.hdm_pair_has(id, public.hdm_me()));

-- סימוני קריאה: "<אני>___<שיחה>". קריאה גם של הצד השני באותה שיחה (וי כחול)
create policy chatreads_read on public.docs for select to authenticated
  using (collection = 'chatReads' and public.hdm_pair_has(split_part(id, '___', 2), public.hdm_me()));
create policy chatreads_insert on public.docs for insert to authenticated
  with check (collection = 'chatReads' and split_part(id, '___', 1) = public.hdm_me()
              and public.hdm_pair_has(split_part(id, '___', 2), public.hdm_me()));
create policy chatreads_update on public.docs for update to authenticated
  using (collection = 'chatReads' and split_part(id, '___', 1) = public.hdm_me())
  with check (collection = 'chatReads' and split_part(id, '___', 1) = public.hdm_me());

-- חסימות: "<חוסם>__<נחסם>"
create policy blocks_read on public.docs for select to authenticated
  using (collection = 'blocks' and public.hdm_pair_has(id, public.hdm_me()));
create policy blocks_insert on public.docs for insert to authenticated
  with check (collection = 'blocks' and split_part(id, '__', 1) = public.hdm_me());
create policy blocks_update on public.docs for update to authenticated
  using (collection = 'blocks' and split_part(id, '__', 1) = public.hdm_me())
  with check (collection = 'blocks' and split_part(id, '__', 1) = public.hdm_me());
create policy blocks_delete on public.docs for delete to authenticated
  using (collection = 'blocks' and split_part(id, '__', 1) = public.hdm_me());

-- דיווחים: שליחה בלבד, בלי קריאה
create policy reports_insert on public.docs for insert to authenticated
  with check (collection = 'reports' and public.hdm_me() is not null);

-- נעילה קצרה בזמן כתיבת הודעה (__lease של האפליקציה) — רק לשיחה שלי
create policy lease_all on public.docs for all to authenticated
  using (collection = '__lease' and id like 'chats/%' and public.hdm_pair_has(substr(id, 7), public.hdm_me()))
  with check (collection = '__lease' and id like 'chats/%' and public.hdm_pair_has(substr(id, 7), public.hdm_me()));

-- שאר הטבלאות: RLS בלי policies = סגור לגמרי לאפליקציה
alter table public.hdm_accounts            enable row level security;
alter table public.hdm_profile_private     enable row level security;
alter table public.hdm_subscriptions       enable row level security;
alter table public.hdm_subscription_events enable row level security;
alter table public.hdm_chat_openings       enable row level security;
alter table public.hdm_staging_marker      enable row level security;
alter table public.hdm_plans               enable row level security;
create policy plans_read on public.hdm_plans for select to anon, authenticated using (true);

-- ---------------------------------------------------------------------
-- 5. פונקציות שרת שהאפליקציה קוראת (RPC)
-- ---------------------------------------------------------------------

-- קישור משתמש Auth לפרופיל. פעם אחת לכל משתמש; אי אפשר לתפוס פרופיל קיים של מישהו אחר.
create function public.hdm_claim_profile(p_proposed text default null)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  v   text;
begin
  if uid is null then
    raise exception 'HDM_NOT_SIGNED_IN' using errcode = 'P0001', hint = 'נדרשת התחברות.';
  end if;
  select profile_id into v from public.hdm_accounts where auth_user_id = uid;
  if v is not null then return v; end if;
  if p_proposed is not null then
    if p_proposed !~ '^[A-Za-z0-9_-]{3,64}$' or position('__' in p_proposed) > 0
       or exists (select 1 from public.hdm_accounts where profile_id = p_proposed)
       or exists (select 1 from public.docs where collection = 'profiles' and id = p_proposed)
       or exists (select 1 from public.hdm_profile_private where profile_id = p_proposed) then
      raise exception 'HDM_PROFILE_ID_TAKEN' using errcode = 'P0001', hint = 'מזהה הפרופיל אינו זמין.';
    end if;
    v := p_proposed;
  else
    v := 'p_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 20);
  end if;
  insert into public.hdm_accounts (auth_user_id, profile_id) values (uid, v);
  return v;
end $$;

-- המסלול שלי בלבד (אין פרמטר — אי אפשר לבדוק מסלול של אחרים)
create function public.hdm_my_entitlements()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me   text := public.hdm_require_me();
  pl   public.hdm_plans := public.hdm_plan_row(me);
  s    public.hdm_subscriptions%rowtype;
  used int := 0;
  st   text := 'none';
begin
  select * into s from public.hdm_subscriptions where profile_id = me;
  if s.profile_id is not null then
    used := public.hdm_chats_used(me);
    st := case when pl.plan = 'free' then 'expired' else s.status end;
  end if;
  return jsonb_build_object(
    'profileId',        me,
    'plan',             pl.plan,
    'planName',         pl.name_he,
    'priceAgorot',      pl.price_agorot,
    'status',           st,
    'periodEnd',        case when pl.plan = 'free' then null else s.current_period_end end,
    'periodReset',      case when s.profile_id is null or pl.plan = 'free' then null
                             else public.hdm_period_start(s.period_anchor) + interval '1 month' end,
    'canRate',          pl.can_rate,
    'ratingDetails',    pl.rating_details,
    'canTarget',        pl.can_target,
    'canChat',          pl.can_chat,
    'seeWhoTargeted',   pl.see_who_targeted,
    'extendedAnalysis', pl.extended_analysis,
    'limorDiscountPct', pl.limor_discount_pct,
    'chatsLimit',       pl.monthly_new_chats,
    'chatsUsed',        used,
    'chatsLeft',        case when pl.monthly_new_chats is null then null else greatest(pl.monthly_new_chats - used, 0) end);
end $$;

-- פרטי הלידה והמספרים שלי (למסך הפרופיל שלי)
create function public.hdm_my_private()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'birthdate', pp.birthdate, 'birthFirstName', pp.birth_first_name, 'birthLastName', pp.birth_last_name,
    'lifePathNumber', pp.life_path, 'birthdayNumber', pp.birthday_number, 'vowelNumber', pp.vowel_number,
    'consonantsNumber', pp.consonants_number, 'expressionNumber', pp.expression_number)
  from public.hdm_profile_private pp where pp.profile_id = public.hdm_require_me()
$$;

-- דירוג התאמה לרשימת פרופילים (עד 100 בבקשה). בסיסי: דירוג בלבד; פלוס/VIP: גם פירוט.
create function public.hdm_match_ratings(p_targets text[])
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me  text := public.hdm_require_me();
  pl  public.hdm_plans := public.hdm_plan_row(me);
  out jsonb := '{}'::jsonb;
  t   text;
  c   jsonb;
begin
  if not pl.can_rate then perform public.hdm_plan_error('rate'); end if;
  if coalesce(array_length(p_targets, 1), 0) > 100 then
    raise exception 'HDM_TOO_MANY' using errcode = 'P0001';
  end if;
  foreach t in array coalesce(p_targets, '{}') loop
    continue when t is null or t = me or out ? t;
    continue when not public.hdm_profile_exists(t) or public.hdm_blocked_between(t, me) or public.hdm_is_age_blocked(t);
    c := public.hdm_compat(me, t);
    continue when c is null;
    if pl.rating_details then
      -- הפירוט כולל אם כל קטגוריה טובה / קארמתית, בלי המספרים של הצד השני
      out := out || jsonb_build_object(t, jsonb_build_object(
        'label', c->'label', 'score', c->'score', 'goodCount', c->'goodCount', 'karmicCount', c->'karmicCount',
        'categories', (select coalesce(jsonb_agg(jsonb_build_object('key', x->'key', 'label', x->'label',
                                                   'good', x->'good', 'karmic', x->'karmic')), '[]'::jsonb)
                         from jsonb_array_elements(c->'categories') x)));
    else
      out := out || jsonb_build_object(t, jsonb_build_object('label', c->'label', 'score', c->'score'));
    end if;
  end loop;
  return out;
end $$;

-- פתיחת שיחה (פנימי): בודק מסלול ומכסה לכל צד, נועל, רושם ביומן ויוצר match + chat
create function public.hdm_open_chat_internal(p_me text, p_other text)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare
  pair  text := public.hdm_pair_id(p_me, p_other);
  u     text;
  pl    public.hdm_plans;
begin
  -- נעילה לפי סדר קבוע (מונע עקיפת מכסה בשתי בקשות במקביל)
  foreach u in array array[least(p_me, p_other), greatest(p_me, p_other)] loop
    perform pg_advisory_xact_lock(hashtext('hdm_user:' || u));
  end loop;

  if exists (select 1 from public.docs where collection = 'chats' and id = pair) then
    return 'exists';
  end if;
  if not public.hdm_is_mutual(p_me, p_other) then
    raise exception 'HDM_NOT_MUTUAL' using errcode = 'P0001', hint = 'שיחה נפתחת רק אחרי 🎯 הדדי.';
  end if;
  if public.hdm_blocked_between(p_me, p_other) then
    raise exception 'HDM_NOT_AVAILABLE' using errcode = 'P0001', hint = 'לא ניתן לפתוח שיחה עם המשתמש הזה.';
  end if;

  foreach u in array array[p_me, p_other] loop
    continue when exists (select 1 from public.hdm_chat_openings o where o.profile_id = u and o.pair_id = pair);
    pl := public.hdm_plan_row(u);
    if not pl.can_chat then
      if u = p_me then perform public.hdm_plan_error('chat'); end if;
      raise exception 'HDM_OTHER_UNAVAILABLE' using errcode = 'P0001',
        hint = 'השיחה תיפתח כשהצד השני יוכל לפתוח שיחות.';
    end if;
    if pl.monthly_new_chats is not null and public.hdm_chats_used(u) >= pl.monthly_new_chats then
      if u = p_me then
        raise exception 'HDM_CHAT_LIMIT' using errcode = 'P0001',
          hint = 'נוצלו כל השיחות החדשות לחודש החיוב הנוכחי.';
      end if;
      raise exception 'HDM_OTHER_UNAVAILABLE' using errcode = 'P0001',
        hint = 'השיחה תיפתח כשהצד השני יוכל לפתוח שיחות.';
    end if;
  end loop;

  foreach u in array array[p_me, p_other] loop
    insert into public.hdm_chat_openings (profile_id, pair_id, plan)
    values (u, pair, public.hdm_plan_of(u))
    on conflict (profile_id, pair_id) do nothing;
  end loop;
  insert into public.docs (collection, id, data) values
    ('matches', pair, jsonb_build_object('users', jsonb_build_array(least(p_me, p_other), greatest(p_me, p_other)),
                                         'ts', (extract(epoch from now()) * 1000)::bigint))
  on conflict (collection, id) do nothing;
  insert into public.docs (collection, id, data) values
    ('chats', pair, jsonb_build_object('participants', jsonb_build_array(least(p_me, p_other), greatest(p_me, p_other)),
                                       'createdBy', p_me, 'createdAt', (extract(epoch from now()) * 1000)::bigint,
                                       'messages', '[]'::jsonb))
  on conflict (collection, id) do nothing;
  return 'opened';
end $$;

-- סימון 🎯. אם יש הדדיות — מנסה לפתוח שיחה.
create function public.hdm_send_target(p_target text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me     text := public.hdm_require_me();
  pl     public.hdm_plans := public.hdm_plan_row(me);
  mutual boolean;
  chat   text := null;
begin
  if not pl.can_target then perform public.hdm_plan_error('target'); end if;
  if p_target is null or p_target = me or not public.hdm_profile_exists(p_target)
     or public.hdm_is_age_blocked(p_target) or public.hdm_blocked_between(me, p_target) then
    raise exception 'HDM_NOT_AVAILABLE' using errcode = 'P0001', hint = 'לא ניתן לסמן את המשתמש הזה.';
  end if;

  insert into public.docs (collection, id, data)
  values ('interests', me || '__' || p_target,
          jsonb_build_object('from', me, 'to', p_target, 'ts', (extract(epoch from now()) * 1000)::bigint))
  on conflict (collection, id) do nothing;

  mutual := public.hdm_has_interest(p_target, me);
  if mutual then
    begin
      chat := public.hdm_open_chat_internal(me, p_target);
    exception when sqlstate 'P0001' then
      chat := case sqlerrm when 'HDM_CHAT_LIMIT' then 'my_limit'
                           when 'HDM_OTHER_UNAVAILABLE' then 'other_unavailable'
                           else lower(sqlerrm) end;
    end;
  end if;

  return jsonb_build_object(
    'targeted', true,
    'mutual', mutual,
    'chat', chat,                     -- opened / exists / my_limit / other_unavailable / null
    'extendedAnalysis', case pl.extended_analysis
                          when 'after_my_target' then true
                          when 'after_mutual' then mutual
                          else false end);
end $$;

-- פתיחה חוזרת של שיחה אחרי 🎯 הדדי (למשל אחרי שדרוג או חודש חיוב חדש)
create function public.hdm_open_chat(p_target text)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare me text := public.hdm_require_me();
begin
  return public.hdm_open_chat_internal(me, p_target);
end $$;

-- ביטול 🎯 שלי (רק אם עוד לא נפתחה שיחה)
create function public.hdm_remove_target(p_target text)
returns boolean language plpgsql volatile security definer set search_path = '' as $$
declare me text := public.hdm_require_me();
begin
  if exists (select 1 from public.docs where collection = 'chats' and id = public.hdm_pair_id(me, p_target)) then
    return false;
  end if;
  delete from public.docs where collection = 'interests' and id = me || '__' || p_target;
  return found;
end $$;

-- את מי סימנתי 🎯
create function public.hdm_my_targets()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.data->>'to', 'ts', d.data->'ts',
           'mutual', public.hdm_has_interest(d.data->>'to', public.hdm_me())) order by d.data->>'ts' desc), '[]'::jsonb)
    from public.docs d
   where d.collection = 'interests' and d.data->>'from' = public.hdm_require_me()
$$;

-- מי סימן אותי 🎯 — פלוס ו-VIP בלבד
create function public.hdm_who_targeted_me()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me text := public.hdm_require_me();
  r  jsonb;
begin
  if not (public.hdm_plan_row(me)).see_who_targeted then perform public.hdm_plan_error('who'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', d.data->>'from', 'ts', d.data->'ts') order by d.data->>'ts' desc), '[]'::jsonb)
    into r
    from public.docs d
   where d.collection = 'interests' and d.data->>'to' = me
     and not public.hdm_blocked_between(me, d.data->>'from')
     and not public.hdm_is_age_blocked(d.data->>'from');
  return r;
end $$;

-- ניתוח נומרולוגי מורחב. פלוס: אחרי 🎯 הדדי. VIP: מיד אחרי 🎯 שלי.
create function public.hdm_extended_analysis(p_target text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me text := public.hdm_require_me();
  pl public.hdm_plans := public.hdm_plan_row(me);
  c  jsonb;
begin
  if pl.extended_analysis = 'none' then perform public.hdm_plan_error('extended'); end if;
  if p_target is null or p_target = me or not public.hdm_profile_exists(p_target)
     or public.hdm_blocked_between(me, p_target) or public.hdm_is_age_blocked(p_target) then
    raise exception 'HDM_NOT_AVAILABLE' using errcode = 'P0001';
  end if;
  if pl.extended_analysis = 'after_mutual' and not public.hdm_is_mutual(me, p_target) then
    raise exception 'HDM_NOT_MUTUAL' using errcode = 'P0001',
      hint = 'במסלול פלוס הניתוח המורחב נפתח אחרי 🎯 הדדי.';
  end if;
  if pl.extended_analysis = 'after_my_target' and not public.hdm_has_interest(me, p_target) then
    raise exception 'HDM_TARGET_FIRST' using errcode = 'P0001',
      hint = 'הניתוח המורחב נפתח מיד אחרי שמסמנים 🎯.';
  end if;
  c := public.hdm_compat(me, p_target);
  if c is null then
    raise exception 'HDM_NOT_AVAILABLE' using errcode = 'P0001';
  end if;
  -- רק מספרים נומרולוגיים — בלי תאריך לידה ובלי שם מלידה של הצד השני
  return c || jsonb_build_object('limorDiscountPct', pl.limor_discount_pct, 'plan', pl.plan);
end $$;

-- מחיקת כל הנתונים שלי (לכפתור "מחיקת חשבון"). משתמש ה-Auth עצמו נמחק בנפרד.
create function public.hdm_delete_my_data()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  me text := public.hdm_require_me();
  n  int;
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
  return jsonb_build_object('deletedDocs', n);
end $$;

-- ---------------------------------------------------------------------
-- 6. ניהול מנויים — רק מה-SQL Editor (אין הרשאה לאפליקציה)
-- ---------------------------------------------------------------------

-- הגדרת מסלול / שדרוג / שנמוך / חידוש. p_days = לכמה ימים המנוי בתוקף (ברירת מחדל 30).
create function public.hdm_admin_set_plan(p_profile text, p_plan text, p_days int default 30, p_note text default null)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare
  cur  text := public.hdm_plan_of(p_profile);
  ord_old int; ord_new int;
  act text;
begin
  if not exists (select 1 from public.hdm_plans where plan = p_plan) then
    raise exception 'מסלול לא מוכר: %', p_plan;
  end if;
  if not exists (select 1 from public.docs where collection = 'profiles' and id = p_profile) then
    raise exception 'לא נמצא פרופיל עם המזהה %', p_profile;
  end if;
  if p_plan = 'free' then
    return public.hdm_admin_expire(p_profile);
  end if;
  select sort_order into ord_old from public.hdm_plans where plan = cur;
  select sort_order into ord_new from public.hdm_plans where plan = p_plan;
  act := case when cur = 'free' then 'start' when ord_new > ord_old then 'upgrade'
              when ord_new < ord_old then 'downgrade' else 'renew' end;

  insert into public.hdm_subscriptions as s (profile_id, plan, status, period_anchor, current_period_end, source, note)
  values (p_profile, p_plan, 'active', now(),
          case when p_days is null then null else now() + make_interval(days => p_days) end, 'test', p_note)
  on conflict (profile_id) do update set
    plan               = excluded.plan,
    status             = 'active',
    canceled_at        = null,
    -- מנוי חדש (אחרי חינם / פקיעה) פותח חודש חיוב חדש; שדרוג או שנמוך באמצע — אותו חודש חיוב
    period_anchor      = case when cur = 'free' then now() else s.period_anchor end,
    current_period_end = excluded.current_period_end,
    note               = coalesce(excluded.note, s.note),
    updated_at         = now();
  insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan, note)
  values (p_profile, act, cur, p_plan, p_note);
  return p_profile || ': ' || act || ' ' || cur || ' → ' || p_plan;
end $$;

-- ביטול: המנוי ממשיך עד סוף התקופה ששולמה, ואז חוזר לחינם
create function public.hdm_admin_cancel(p_profile text)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare cur text := public.hdm_plan_of(p_profile);
begin
  update public.hdm_subscriptions
     set status = 'canceled', canceled_at = now(), updated_at = now(),
         current_period_end = coalesce(current_period_end, now())
   where profile_id = p_profile and status = 'active';
  if not found then return p_profile || ': אין מנוי פעיל לביטול'; end if;
  insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan)
  values (p_profile, 'cancel', cur, cur);
  return p_profile || ': בוטל — בתוקף עד ' || (select current_period_end from public.hdm_subscriptions where profile_id = p_profile);
end $$;

-- פקיעה מיידית (לבדיקה): חוזר לחינם מיד
create function public.hdm_admin_expire(p_profile text)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare cur text := public.hdm_plan_of(p_profile);
begin
  update public.hdm_subscriptions
     set status = 'expired', current_period_end = now() - interval '1 second', updated_at = now()
   where profile_id = p_profile;
  insert into public.hdm_subscription_events (profile_id, action, from_plan, to_plan)
  values (p_profile, 'expire', cur, 'free');
  return p_profile || ': פג — ' || cur || ' → free';
end $$;

-- ---------------------------------------------------------------------
-- 7. הרשאות: קודם סוגרים הכול, ואז פותחים רק את מה שצריך
-- ---------------------------------------------------------------------
revoke all on all tables    in schema public from public, anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;

grant select, insert, update, delete on public.docs to authenticated;
grant select on public.hdm_plans to anon, authenticated;

grant execute on function
  public.hdm_claim_profile(text),
  public.hdm_my_entitlements(),
  public.hdm_my_private(),
  public.hdm_match_ratings(text[]),
  public.hdm_send_target(text),
  public.hdm_open_chat(text),
  public.hdm_remove_target(text),
  public.hdm_my_targets(),
  public.hdm_who_targeted_me(),
  public.hdm_extended_analysis(text),
  public.hdm_delete_my_data()
to authenticated;

-- פונקציות עזר שה-RLS והטריגר משתמשים בהן. מחזירות רק כן/לא או את המזהה שלי;
-- הפונקציות שנוגעות בנתונים (normalize / check_chat / doc) עובדות רק מתוך הטריגר.
grant execute on function
  public.hdm_me(),
  public.hdm_require_me(),
  public.hdm_doc(text, text),
  public.hdm_profile_exists(text),
  public.hdm_normalize_profile(text, jsonb),
  public.hdm_check_chat_write(text, jsonb, jsonb, text),
  public.hdm_pair_has(text, text),
  public.hdm_blocked_me(text)
to authenticated;

-- עדכונים חיים (האפליקציה מאזינה לשינויים). Realtime מכבד את ה-RLS.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.docs;
  end if;
end $$;

commit;

select '✅ סביבת הניסוי הוקמה (staging_secure_v1)' as "סטטוס",
       (select count(*) from public.hdm_plans) as "מסלולים",
       (select count(*) from pg_policies where schemaname = 'public') as "כללי RLS";
