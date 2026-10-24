# מעבר לכתובת הרשמית haimderechmisparim.com

הכתובת הרשמית מ-24.10.2026: **https://haimderechmisparim.com** (Cloudflare Pages, פעיל).
הכתובות הישנות נשארות פעילות ולא מפנות אוטומטית, כדי שמשתמשים קיימים, קישורים ישנים ואייקונים במסך הבית ימשיכו לעבוד:
- `https://haim-derech-misparim.pages.dev/`
- `https://shmulikhavivi-design.github.io/haim-derech-misparim/`

## מה כבר עובד בלי שינוי קוד
- כל הקישורים באפליקציה יחסיים (`manifest.webmanifest`: `start_url: ./`).
- קישורי ההרשמה ואיפוס הסיסמה נבנים מהכתובת שבה המשתמש נמצא (`location.origin + location.pathname`), כך שבכל כתובת המשתמש חוזר לאותה כתובת. בתנאי שהכתובת ברשימת Redirect URLs (למטה). אחרת Supabase מחזיר ל-Site URL.
- התחברות היא לכל כתובת בנפרד: משתמש שעובר מהכתובת הישנה לחדשה יתחבר פעם אחת מחדש. החשבון, הפרופיל, השיחות והמנוי לא משתנים.

## Supabase ← Authentication ← URL Configuration (Staging קודם, אחר כך Production ⛔ אישור)
- **Site URL:** `https://haimderechmisparim.com`
- **Redirect URLs** (שלוש שורות, הישנות נשארות):
  - `https://haimderechmisparim.com/**`
  - `https://haim-derech-misparim.pages.dev/**`
  - `https://shmulikhavivi-design.github.io/haim-derech-misparim/**`

ב-Staging ה-Site URL הוא `https://haimderechmisparim.com/staging.html` (העמוד מחובר לפרויקט Staging).

## סליקה (Morning/Grow) ⛔ אישור
סוד הפונקציות `HDM_APP_URL` קובע לאן הלקוח חוזר מדף התשלום. אפשר להשאיר אותו כמו שהוא (הכתובת הישנה ממשיכה לעבוד). כדי שהחזרה תהיה לכתובת החדשה: `HDM_APP_URL` = `https://haimderechmisparim.com`. השינוי לא נוגע בחיובים, בכרטיסים השמורים או בחידושים.

## בדיקה אחרי כל שלב
1. הרשמה חדשה בכתובת החדשה ← הקישור במייל חוזר ל-`haimderechmisparim.com`.
2. "שכחתי סיסמה" ← הקישור חוזר לכתובת החדשה עם `?hdm_reset=1`.
3. אותו דבר מהכתובת הישנה ← חוזר לכתובת הישנה.
