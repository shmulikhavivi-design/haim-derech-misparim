# בדיקות SQL אוטומטיות על Staging (GitHub Actions)

הרצה **ידנית בלבד**, ורק על פרויקט **Haim Derech Misparim Staging** (`ousepgdvzammgkxkweze`).
אין הרצה בפתיחת PR, ב-push רגיל או לפי שעון. אין בקוד סיסמאות או מפתחות.

## הגדרה חד-פעמית (באייפון)
הסוד נשמר **רק בסביבת GitHub בשם `staging`** (Environment Secret), לא כסוד כללי של הריפו.
1. ב-Supabase: פרויקט **Haim Derech Misparim Staging** ← **Connect** ← **Session pooler** ← מעתיקים את ה-URI.
   (Session pooler ולא Direct, כי שרתי GitHub לא תומכים ב-IPv6.)
   בכתובת מופיע `postgres.ousepgdvzammgkxkweze`. בלי זה ההרצה נעצרת.
   במקום `[YOUR-PASSWORD]` שמים את סיסמת המסד של Staging. לא זוכרים? Database ← Settings ← Reset database password. האפליקציה לא מושפעת.
2. ב-GitHub (Safari): הריפו ← Settings ← **Environments** ← **staging**. אם הסביבה לא קיימת, New environment בשם `staging`.
   - **Deployment branches and tags** ← Selected branches ← מוסיפים `staging-tests/run`. מומלץ: כך רק הענף הייעודי יכול לקבל את הסוד.
   - **Environment secrets** ← Add secret ← שם `STAGING_DB_URL`, ערך: הכתובת המלאה.
   - **לא** מוסיפים אותו כ-Repository secret.
   - לבדיקת הדפדפן (`e2e`): **Environment variables** ← Add variable ← שם `STAGING_PUBLISHABLE_KEY`, ערך: המפתח הציבורי של Staging (`sb_publishable_…`, מ-Project Settings ← API Keys). זה לא סוד.

## מצבים
| מצב | מה קורה | משנה משהו? |
|---|---|---|
| `check` (ברירת מחדל) | זהות, מה מותקן, טבלאות ו-RLS, מסלולים ומחירים, הרשאות | **לא.** טרנזקציה לקריאה בלבד |
| `install03` | מריץ את `03_staging_fixes.sql` | כללי הרשאה בלבד. נעצר אם כבר הותקן |
| `install04` | מריץ את `04_staging_profile_id_fix.sql` | כלל על מזהה פרופיל. נעצר אם כבר הותקן |
| `install05` | מריץ את `05_staging_profile_hardening.sql` | הקשחת פרופיל ומחיקת חשבון מלאה. נעצר אם כבר הותקן |
| `tests02` | 74 בדיקות של `02_staging_tests.sql` | יוצר נתוני בדיקה ומבטל אותם בסוף. ההרצה מוודאת שלא נשאר כלום |
| `e2e` | בדיקת דפדפן של `staging.html` מול Staging: התחברות, מסלולים, 🎯, צ׳אט, מכסה, מחיקה ועקיפות | יוצר משתמשי בדיקה זמניים (`hdm-e2e-…@example.invalid`) ומוחק אותם בסוף. ההרצה מוודאת שלא נשאר כלום. בלי מיילים |

## הגנות (ב-`run.sh`, לפני כל פעולה)
1. הכתובת חייבת לכלול את `ousepgdvzammgkxkweze`. אם היא כוללת את מזהה הפרויקט הפעיל, ההרצה נעצרת.
2. במסד חייבת להיות `hdm_staging_marker`. בפרויקט הפעיל אין אותה, ולכן שם ההרצה נעצרת לפני כל כתיבה.
3. כל מצב מתחיל בבדיקת מצב לקריאה בלבד.
4. הכתובת והסיסמה מוסתרות ביומן (add-mask), ושגיאות חיבור לא מודפסות. ה-job רץ רק מהריפו הזה ורק מהענף הייעודי או מכפתור ידני.

## הפעלה
Push לענף `staging-tests/run`, כשבשורת הנושא של ה-commit מופיע `[staging:<מצב>]`. בלי סימון ההרצה היא `check`.
התוצאה מופיעה בלשונית **Actions**. הריפו ציבורי, ולכן היומן גלוי. מודפסים בו רק שמות בדיקות ונתוני בדיקה מומצאים. הסוד לא מודפס.
