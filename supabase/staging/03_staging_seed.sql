-- =====================================================================
-- סביבת בדיקות (Staging) — שלב 3: נתונים מומצאים
-- ⚠️ רק בפרויקט ה-Staging. אסור בפרויקט האמיתי.
--
-- 12 פרופילים מומצאים (שמות, תאריכי לידה וערים בדויים, תמונה ריקה), כמה 🎯 ושיחה אחת.
-- אין כאן שום מידע של משתמש אמיתי. כל הפרופילים מסומנים synthetic=true ומזהיהם מתחילים ב-stg_.
-- הקובץ בודק שהוא רץ בפרויקט שסומן כ-Staging, ואחרת נעצר בלי לשנות כלום.
-- =====================================================================

do $$
begin
  if to_regclass('public.hdm_staging_marker') is null then
    raise exception 'זה לא פרויקט Staging (חסר hdm_staging_marker). שום דבר לא שונה.';
  end if;
end $$;

insert into public.docs (collection, id, data) values
  ('profiles', 'stg_avi', $j${"birthFirstName": "אבי", "birthLastName": "שלום", "currentName": "אבי שלום", "location": "חיפה", "occupation": "מהנדס", "gender": "גבר", "lookingFor": "נשים", "interests": "טיולים, מוזיקה", "bio": "פרופיל בדיקה — משתמש מומצא", "birthdate": "1986-04-12", "lifePathNumber": 4, "expressionNumber": 2, "birthdayNumber": 3, "vowelNumber": 8, "consonantsNumber": 3, "photoUrl": "data:image/gif;base64,R0lGODlhAQABAIAAAAUEBAAAACwAAAAAAQABAAACAkQBADs=", "likes": [], "synthetic": true}$j$::jsonb),
  ('profiles', 'stg_dana', $j${"birthFirstName": "דנה", "birthLastName": "כהן", "currentName": "דנה כהן", "location": "תל אביב", "occupation": "מעצבת", "gender": "אישה", "lookingFor": "גברים", "interests": "טיולים, מוזיקה", "bio": "פרופיל בדיקה — משתמש מומצא", "birthdate": "1990-07-03", "lifePathNumber": 11, "expressionNumber": 8, "birthdayNumber": 3, "vowelNumber": 1, "consonantsNumber": 7, "photoUrl": "data:image/gif;base64,R0lGODlhAQABAIAAAAUEBAAAACwAAAAAAQABAAACAkQBADs=", "likes": [], "synthetic": true}$j$::jsonb),
  ('profiles', 'stg_yossi', $j${"birthFirstName": "יוסי", "birthLastName": "לוי", "currentName": "יוסי לוי", "location": "ירושלים", "occupation": "מורה", "gender": "גבר", "lookingFor": "נשים", "interests": "טיולים, מוזיקה", "bio": "פרופיל בדיקה — משתמש מומצא", "birthdate": "1984-11-25", "lifePathNumber": 4, "expressionNumber": 6, "birthdayNumber": 7, "vowelNumber": 6, "consonantsNumber": 9, "photoUrl": "data:image/gif;base64,R0lGODlhAQABAIAAAAUEBAAAACwAAAAAAQABAAACAkQBADs=", "likes": [], "synthetic": true}$j$::jsonb),
  ('profiles', 'stg_michal', $j${"birthFirstName": "מיכל", "birthLastName": "ברק", "currentName": "מיכל ברק", "location": "רמת גן", "occupation": "עורכת דין", "gender": "אישה", "lookingFor": "גברים", "interests": "טיולים, מוזיקה", "bio": "פרופיל בדיקה — משתמש מומצא", "birthdate": "1992-02-14", "lifePathNumber": 1, "expressionNumber": 6, "birthdayNumber": 5, "vowelNumber": 1, "consonantsNumber": 5, "photoUrl": "data:image/gif;base64,R0lGODlhAQABAIAAAAUEBAAAACwAAAAAAQABAAACAkQBADs=", "likes": [], "synthetic": true}$j$::jsonb),
  ('profiles', 'stg_omer', $j${"birthFirstName": "עומר", "birthLastName": "רז", "currentName": "עומר רז", "location": "באר שבע", "occupation": "צלם", "gender": "גבר", "lookingFor": "כולם", "interests": "טיולים, מוזיקה", "bio": "פרופיל בדיקה — משתמש מומצא", "birthdate": "1989-09-09", "lifePathNumber": 9, "expressionNumber": 1, "birthdayNumber": 9, "vowelNumber": 6, "consonantsNumber": 4, "photoUrl": "data:image/gif;base64,R0lGODlhAQABAIAAAAUEBAAAACwAAAAAAQABAAACAkQBADs=", "likes": [], "synthetic": true}$j$::jsonb),
  ('profiles', 'stg_noga', $j${"birthFirstName": "נוגה", "birthLastName": "פז", "currentName": "נוגה פז", "location": "הרצליה", "occupation": "סטודנטית", "gender": "אישה", "lookingFor": "כולם", "interests": "טיולים, מוזיקה", "bio": "פרופיל בדיקה — משתמש מומצא", "birthdate": "1995-05-30", "lifePathNumber": 5, "expressionNumber": 7, "birthdayNumber": 3, "vowelNumber": 2, "consonantsNumber": 5, "photoUrl": "data:image/gif;base64,R0lGODlhAQABAIAAAAUEBAAAACwAAAAAAQABAAACAkQBADs=", "likes": [], "synthetic": true}$j$::jsonb),
  ('profiles', 'stg_eitan', $j${"birthFirstName": "איתן", "birthLastName": "גל", "currentName": "איתן גל", "location": "נתניה", "occupation": "רואה חשבון", "gender": "גבר", "lookingFor": "נשים", "interests": "טיולים, מוזיקה", "bio": "פרופיל בדיקה — משתמש מומצא", "birthdate": "1981-01-17", "lifePathNumber": 1, "expressionNumber": 8, "birthdayNumber": 8, "vowelNumber": 2, "consonantsNumber": 6, "photoUrl": "data:image/gif;base64,R0lGODlhAQABAIAAAAUEBAAAACwAAAAAAQABAAACAkQBADs=", "likes": [], "synthetic": true}$j$::jsonb),
  ('profiles', 'stg_shira', $j${"birthFirstName": "שירה", "birthLastName": "טל", "currentName": "שירה טל", "location": "מודיעין", "occupation": "אחות", "gender": "אישה", "lookingFor": "גברים", "interests": "טיולים, מוזיקה", "bio": "פרופיל בדיקה — משתמש מומצא", "birthdate": "1988-12-02", "lifePathNumber": 4, "expressionNumber": 5, "birthdayNumber": 2, "vowelNumber": 6, "consonantsNumber": 8, "photoUrl": "data:image/gif;base64,R0lGODlhAQABAIAAAAUEBAAAACwAAAAAAQABAAACAkQBADs=", "likes": [], "synthetic": true}$j$::jsonb),
  ('profiles', 'stg_ronit', $j${"birthFirstName": "רונית", "birthLastName": "אור", "currentName": "רונית אור", "location": "כפר סבא", "occupation": "מאמנת", "gender": "אישה", "lookingFor": "גברים", "interests": "טיולים, מוזיקה", "bio": "פרופיל בדיקה — משתמש מומצא", "birthdate": "1979-08-21", "lifePathNumber": 1, "expressionNumber": 9, "birthdayNumber": 3, "vowelNumber": 5, "consonantsNumber": 4, "photoUrl": "data:image/gif;base64,R0lGODlhAQABAIAAAAUEBAAAACwAAAAAAQABAAACAkQBADs=", "likes": [], "synthetic": true}$j$::jsonb),
  ('profiles', 'stg_gil', $j${"birthFirstName": "גיל", "birthLastName": "שקד", "currentName": "גיל שקד", "location": "פתח תקווה", "occupation": "מתכנת", "gender": "גבר", "lookingFor": "נשים", "interests": "טיולים, מוזיקה", "bio": "פרופיל בדיקה — משתמש מומצא", "birthdate": "1993-03-08", "lifePathNumber": 33, "expressionNumber": 6, "birthdayNumber": 8, "vowelNumber": 1, "consonantsNumber": 5, "photoUrl": "data:image/gif;base64,R0lGODlhAQABAIAAAAUEBAAAACwAAAAAAQABAAACAkQBADs=", "likes": [], "synthetic": true}$j$::jsonb),
  ('profiles', 'stg_tamar', $j${"birthFirstName": "תמר", "birthLastName": "אלון", "currentName": "תמר אלון", "location": "אשדוד", "occupation": "מוזיקאית", "gender": "אישה", "lookingFor": "כולם", "interests": "טיולים, מוזיקה", "bio": "פרופיל בדיקה — משתמש מומצא", "birthdate": "1997-10-11", "lifePathNumber": 11, "expressionNumber": 7, "birthdayNumber": 2, "vowelNumber": 7, "consonantsNumber": 9, "photoUrl": "data:image/gif;base64,R0lGODlhAQABAIAAAAUEBAAAACwAAAAAAQABAAACAkQBADs=", "likes": [], "synthetic": true}$j$::jsonb),
  ('profiles', 'stg_beni', $j${"birthFirstName": "בני", "birthLastName": "דגן", "currentName": "בני דגן", "location": "רחובות", "occupation": "שף", "gender": "גבר", "lookingFor": "נשים", "interests": "טיולים, מוזיקה", "bio": "פרופיל בדיקה — משתמש מומצא", "birthdate": "1975-06-06", "lifePathNumber": 7, "expressionNumber": 2, "birthdayNumber": 6, "vowelNumber": 1, "consonantsNumber": 1, "photoUrl": "data:image/gif;base64,R0lGODlhAQABAIAAAAUEBAAAACwAAAAAAQABAAACAkQBADs=", "likes": [], "synthetic": true}$j$::jsonb)
on conflict (collection, id) do nothing;

-- 🎯 בין פרופילים מומצאים: אבי↔דנה הדדי (עם שיחה), יוסי→מיכל חד-צדדי, עומר→נוגה ונוגה→עומר הדדי בלי שיחה
insert into public.docs (collection, id, data) values
  ('interests', 'stg_avi__stg_dana',    '{"from":"stg_avi","to":"stg_dana","ts":1760000000000}'),
  ('interests', 'stg_dana__stg_avi',    '{"from":"stg_dana","to":"stg_avi","ts":1760000001000}'),
  ('interests', 'stg_yossi__stg_michal','{"from":"stg_yossi","to":"stg_michal","ts":1760000002000}'),
  ('interests', 'stg_omer__stg_noga',   '{"from":"stg_omer","to":"stg_noga","ts":1760000003000}'),
  ('interests', 'stg_noga__stg_omer',   '{"from":"stg_noga","to":"stg_omer","ts":1760000004000}'),
  ('matches',   'stg_avi__stg_dana',    '{"users":["stg_avi","stg_dana"],"ts":1760000001000}'),
  ('chats',     'stg_avi__stg_dana',    '{"participants":["stg_avi","stg_dana"],"createdBy":"stg_dana","createdAt":1760000001000,
     "messages":[{"senderId":"stg_dana","text":"היי, הודעת בדיקה","ts":1760000005000},{"senderId":"stg_avi","text":"היי! תשובת בדיקה","ts":1760000006000}]}')
on conflict (collection, id) do nothing;

select count(*) filter (where collection = 'profiles') as "פרופילים מומצאים",
       count(*) filter (where collection = 'interests') as "🎯",
       count(*) filter (where collection = 'chats')     as "שיחות"
  from public.docs where id like 'stg\_%';
