# מעבר לגרסה המאובטחת — מדריך הרצה (Production)

**שום שלב כאן לא מבוצע בלי אישור מפורש של הבעלים.** המעבר ל-Production והמיזוג נעשים יחד, בחלון זמן אחד (כ-10 דקות).

## מה נבדק לפני המדריך
- **Staging, על עותק מקומי:**
  - 74/74 בדיקות SQL.
  - 50/50 בדיקות דפדפן.
  - 36/36 בבדיקת e2e. ההרצה על Staging האמיתי ממתינה לסוד ב-GitHub.
- **חזרה גנרלית, על מסד שמדמה את Production של היום:**
  - **המצב שדומה:** `docs` פתוחה, הגבלת גיל ישנה, מנויים מ-PR #9, חשבונות קיימים, שיחות, 🎯, פרופיל בלי תאריך לידה וחשבון חסום-גיל.
  - **המעבר:** עבר בלי לאבד אף רשומה.
  - **בדפדפן:** 18/18 בדיקות של `index.html` החדש.
  - **ביטול (rollback):** החזיר את המסד בדיוק למצב הקודם.

## לפני חלון המעבר (בלי סיכון)
1. **בדיקה מקדימה, קריאה בלבד:** ב-Production מריצים את `supabase/production/00_production_preflight_readonly.sql`. כל השורות צריכות להיות ✅.
2. **Supabase ← Production ← Authentication:**
   - **URL Configuration:**
     - Site URL: `https://shmulikhavivi-design.github.io/haim-derech-misparim/`
     - Redirect URLs: אותה כתובת, וגם `https://shmulikhavivi-design.github.io/haim-derech-misparim/index.html?hdm_reset=1`
   - **Sign In / Providers ← Email:** להפעיל **Confirm email**.
   - **שליחת מיילים (SMTP):** חובה להגדיר שרת מיילים משלכם (Emails ← SMTP Settings). שירות המיילים המובנה של Supabase מוגבל מאוד, ובלעדיו מיילי אישור ואיפוס לא יגיעו למשתמשים.

## חלון המעבר
3. **ב-Production ← SQL Editor:** מריצים את `supabase/production/01_production_migration.sql`. אמורה להופיע השורה `✅ המעבר הושלם`.
   אם מופיעה שגיאה, שום דבר לא נשמר. עוצרים כאן.
4. **מיד אחר כך:** ממזגים את PR הגרסה. GitHub Pages מעדכן את האתר תוך 1–2 דקות.
5. **בדיקה קצרה באייפון:** פותחים את האתר ונכנסים לחשבון קיים דרך **"שכחתי סיסמה"** (ראו סעיף 6).

## אחרי המעבר
6. **חשבונות קיימים:**
   - כל אחד נכנס **פעם אחת** דרך "שכחתי סיסמה", כדי להוכיח שהמייל שלו.
   - כך החשבון מתחבר לפרופיל הקיים שלו, עם כל ההודעות, ה-🎯 והמנוי.
   - כניסה רגילה בסיסמה הישנה מציגה הסבר, ולא יוצרת פרופיל חדש.
7. **מי שאין לו תאריך לידה:** מתבקש להשלים אותו בכניסה, כמו היום.
8. **מנויים:**
   - אם מנויי PR #9 הותקנו ב-Production, הם הועתקו אוטומטית.
   - אחרת, מגדירים מסלול ב-SQL Editor:
     `select public.hdm_admin_set_plan('<מזהה פרופיל>', 'plus');`

## ביטול (חירום בלבד)
1. ב-SQL Editor: `supabase/production/99_production_rollback.sql`.
   **שימו לב:** מה שנכתב אחרי המעבר לא יחזור לטבלה, אבל נשמר עותק ב-`hdm_backup`.
2. אחר כך: `supabase/age_gate.sql` מ-main.
3. ב-GitHub: **Revert** ל-PR הגרסה.

## עדכון קוד בעתיד
- **האפליקציה:** כותבים את השינוי ב-`staging.html`, בודקים ב-Staging, ומריצים `python3 scripts/release/make_release_index.py`. כך נבנה `index.html` מאותו קוד.
- **השרת:** משנים את קובצי `supabase/staging_secure/*`, ומריצים `python3 scripts/release/build_production_sql.py`. כך נבנה קובץ המעבר.
