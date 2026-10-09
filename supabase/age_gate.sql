-- =====================================================================
-- חיים דרך מספרים — הגבלת גיל 18+ באכיפה של מסד הנתונים
-- להרצה פעם אחת ב-Supabase: SQL Editor ← New query ← להדביק ← Run
--
-- מה זה עושה:
--   * כל כתיבה של פרופיל (טבלת docs, collection = 'profiles') נבדקת במסד עצמו,
--     גם אם מישהו עוקף את האפליקציה ופונה ישירות ל-API.
--   * פרופיל חדש חייב תאריך לידה תקין, והגיל המחושב ממנו חייב להיות 18 ומעלה.
--   * הגיל (data.age) נקבע במסד לפי תאריך הלידה, לפי התאריך בישראל.
--   * אי אפשר למחוק תאריך לידה קיים או לשנות אותו לגיל מתחת ל-18.
--   * חשבון שסומן ageBlocked נשאר חסום: אי אפשר להסיר את הסימון או להוסיף לו תאריך לידה.
--   * פרופילים קיימים בלי תאריך לידה ממשיכים לעבוד במסד, והאפליקציה מבקשת מהם
--     להשלים תאריך לידה לפני המשך השימוש.
--
-- מה זה לא עושה:
--   * לא מוחק ולא משנה שום נתון קיים. הסקריפט יוצר רק פונקציות וטריגר.
--   * לא נוגע בהתאמות, בהודעות, בשיחות או בהתחברות.
--   * תאריך לידה שהמשתמש מזין הוא הצהרה, לא אימות זהות.
-- =====================================================================

-- גיל בשנים מלאות מתאריך בפורמט YYYY-MM-DD, או NULL אם התאריך חסר / לא תקין / עתידי
create or replace function public.hdm_age_from_birthdate(b text)
returns integer
language plpgsql
stable
set search_path = public
as $$
declare
  d date;
  today date := (now() at time zone 'Asia/Jerusalem')::date;
begin
  if b is null or btrim(b) !~ '^\d{4}-\d{2}-\d{2}$' then
    return null;
  end if;
  begin
    d := btrim(b)::date;          -- תאריך כמו 2000-02-31 נכשל כאן
  exception when others then
    return null;
  end;
  if d > today or d < date '1900-01-01' then
    return null;
  end if;
  return extract(year from age(today, d))::int;
end;
$$;

create or replace function public.hdm_profiles_age_gate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  b        text := nullif(btrim(coalesce(new.data->>'birthdate', '')), '');
  old_data jsonb;
  old_b    text;
  a        integer;
begin
  if new.collection is distinct from 'profiles' then
    return new;
  end if;

  -- הנתונים הקודמים של אותו פרופיל (גם ב-upsert: טריגר ה-INSERT רץ לפני שמתברר שהשורה קיימת)
  if tg_op = 'UPDATE' then
    old_data := old.data;
  else
    select t.data into old_data from public.docs t
     where t.collection = new.collection and t.id = new.id;
  end if;
  old_b := nullif(btrim(coalesce(old_data->>'birthdate', '')), '');

  -- חשבון חסום נשאר חסום
  if coalesce(old_data->>'ageBlocked', '') = 'true' then
    if b is not null then
      raise exception 'HDM_AGE_BLOCKED' using errcode = 'P0001',
        hint = 'הכניסה לאפליקציית חיים דרך מספרים מותרת מגיל 18 ומעלה בלבד.';
    end if;
    new.data := coalesce(new.data, '{}'::jsonb) || '{"ageBlocked": true}'::jsonb;
    return new;
  end if;

  if b is null then
    -- רישום סימון חסימה (בלי תאריך לידה) מותר
    if coalesce(new.data->>'ageBlocked', '') = 'true' then
      return new;
    end if;
    -- פרופיל חדש חייב תאריך לידה; תאריך לידה קיים לא נמחק
    if old_data is null or old_b is not null then
      raise exception 'HDM_BIRTHDATE_REQUIRED' using errcode = 'P0001',
        hint = 'נדרש תאריך לידה.';
    end if;
    -- פרופיל קיים שעוד לא השלים תאריך לידה: ממשיך לעבוד, האפליקציה מבקשת להשלים
    return new;
  end if;

  a := public.hdm_age_from_birthdate(b);
  if a is null then
    raise exception 'HDM_BIRTHDATE_INVALID' using errcode = 'P0001',
      hint = 'תאריך הלידה אינו תקין.';
  end if;
  if a < 18 then
    raise exception 'HDM_UNDERAGE' using errcode = 'P0001',
      hint = 'הכניסה לאפליקציית חיים דרך מספרים מותרת מגיל 18 ומעלה בלבד.';
  end if;

  new.data := jsonb_set(new.data, '{age}', to_jsonb(a::text), true);
  return new;
end;
$$;

drop trigger if exists hdm_profiles_age_gate on public.docs;
create trigger hdm_profiles_age_gate
  before insert or update on public.docs
  for each row
  when (new.collection = 'profiles')
  execute function public.hdm_profiles_age_gate();

-- ---------------------------------------------------------------------
-- בדיקה בלבד (לא משנה כלום): כמה פרופילים קיימים לפי מצב הגיל
-- ---------------------------------------------------------------------
-- select
--   case
--     when data->>'ageBlocked' = 'true' then 'חסום'
--     when public.hdm_age_from_birthdate(data->>'birthdate') is null then 'חסר / לא תקין — יתבקש להשלים'
--     when public.hdm_age_from_birthdate(data->>'birthdate') < 18 then 'מתחת ל-18 — לא יוכל להיכנס'
--     else 'תקין (18+)'
--   end as status,
--   count(*)
-- from public.docs
-- where collection = 'profiles'
-- group by 1;

-- ---------------------------------------------------------------------
-- ביטול (אם צריך לחזור אחורה):
-- ---------------------------------------------------------------------
-- drop trigger if exists hdm_profiles_age_gate on public.docs;
-- drop function if exists public.hdm_profiles_age_gate();
-- drop function if exists public.hdm_age_from_birthdate(text);
