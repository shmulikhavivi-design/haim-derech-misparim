# מיילים בלי SMTP ובלי סיסמת אפליקציה — ממסר Gmail (Apps Script)

**למה:** Google לא מאפשר כרגע ליצור סיסמת אפליקציה בחשבון `life.through.numbers333@gmail.com`, ובלעדיה Gmail SMTP דוחה את Supabase (שגיאה 535, נבדק ב-Staging ב-14.10).

**הפתרון:** Supabase לא מתחבר ל-Gmail בכלל. במקום SMTP הוא קורא לפונקציה במסד (Send Email Hook), והיא מעבירה את המייל לסקריפט קטן שרץ בתוך חשבון ה-Google של האפליקציה. הסקריפט שולח בעצמו, מהחשבון — כמו מייל רגיל מ-Gmail.

| | |
|---|---|
| עלות | ₪0, בלי דומיין |
| שולח | `life.through.numbers333@gmail.com`, בשם `חיים דרך מספרים` |
| הגעה לתיבה | המייל נשלח מתוך Gmail עצמו, עם החתימה של Google |
| מכסה | עד 100 נמענים ביום (מגבלה של Google לחשבון רגיל) |
| סודות | מפתח אקראי — נשמר רק ב-Vault של Supabase ובעורך של Google. לא בצ'אט ולא ב-GitHub |
| ביטול | מכבים את ה-Hook ב-Supabase. שום נתון לא משתנה |

**מתי לשדרג:** מעל ~100 מיילים ביום, או כשיהיה דומיין — עוברים ל-Resend (`docs/smtp-setup.md`).

---

## שלב א — Staging (בדיקה)

הקבצים `12_staging_mail_hook.sql` (התקנה) ו-`13_staging_mail_hook_tests.sql` (28 בדיקות) רצים מ-GitHub Actions, בלי מגע ידני.

### 1. יצירת הסקריפט ב-Google (מהאייפון, ב-Safari)
1. מתחברים ל-Google בחשבון `life.through.numbers333@gmail.com` (לא בחשבון הפרטי).
2. נכנסים ל-`script.google.com` ← **New project**. אם האתר מבקש — **"Request Desktop Website"** בתפריט ה-**aA** של Safari.
3. מוחקים את כל מה שכתוב בעורך, ומדביקים את כל התוכן של `scripts/mail_relay/Code.gs`.
4. שם הפרויקט (למעלה): `HDM mail relay`. שומרים (💾).

### 2. אישור הרשאת שליחה
1. בתפריט הפונקציות למעלה בוחרים **authorize** ← **Run**.
2. Google מבקש אישור. אם מופיע "Google hasn't verified this app": **Advanced** ← **Go to HDM mail relay** ← **Allow**.
   (זה הסקריפט שלכם, בחשבון שלכם. האזהרה מופיעה לכל סקריפט פרטי.)

### 3. פרסום כ-Web app
1. **Deploy** ← **New deployment** ← גלגל השיניים ← **Web app**.
2. **Execute as:** `Me`. **Who has access:** `Anyone`.
3. **Deploy** ← מעתיקים את **Web app URL** (מתחיל ב-`https://script.google.com/macros/s/` ונגמר ב-`/exec`).

### 4. שמירת הכתובת ב-Supabase Staging
Supabase ← **Haim Derech Misparim Staging** ← **SQL Editor**:
```sql
select public.hdm_mail_setup('<Web app URL משלב 3>');
```
התוצאה: מפתח באורך 48 תווים. **מעתיקים אותו.**

### 5. הדבקת המפתח בסקריפט
1. חוזרים לעורך של Google. בשורה `const KEY = 'PASTE_KEY_HERE';` מחליפים את `PASTE_KEY_HERE` במפתח (בין הגרשיים).
2. שומרים (💾).
3. **Deploy** ← **Manage deployments** ← ✏️ ← **Version: New version** ← **Deploy**.
   (בלי זה הכתובת ממשיכה להריץ את הגרסה הקודמת, בלי המפתח.)

### 6. הפעלת ה-Hook ב-Staging
Supabase Staging ← **Authentication** ← **Hooks** ← **Add hook** ← **Send Email hook**:
- **Hook type:** `Postgres`
- **Schema:** `public` · **Function:** `hdm_send_email_hook`
- **Create / Save**

### 7. כתובות האתר ב-Staging (התגלה בבדיקה — כרגע חסר)
Authentication ← **URL Configuration**:
- Site URL: `https://shmulikhavivi-design.github.io/haim-derech-misparim/`
- Redirect URLs ← Add: `https://shmulikhavivi-design.github.io/haim-derech-misparim/**`

**מכאן Claude ממשיך לבד:** בדיקת שליחה אמיתית ב-Staging (אישור הרשמה, שכחתי סיסמה, קישור כניסה) לכתובות `life.through.numbers333+...@gmail.com`. המיילים מגיעים לתיבה של האפליקציה, ואפשר לראות אותם גם בתיקיית **Sent**.

---

## שלב ב — Production (רק אחרי שהבדיקה ב-Staging עברה, ובאישור)

אותו סקריפט משמש את שתי הסביבות? **לא** — כל סביבה עם מפתח משלה. הכי פשוט: פרויקט Apps Script שני (`HDM mail relay — prod`), אותם שלבים 1–5.

1. אחרי `01_production_migration.sql`: ב-SQL Editor של Production מריצים את `supabase/production/12_production_mail_hook.sql`.
2. שלבים 1–5 עם פרויקט Apps Script חדש, ו-`hdm_mail_setup` ב-SQL Editor של **Production**.
3. Production ← Authentication ← Hooks ← Send Email ← Postgres ← `public.hdm_send_email_hook`.
4. Production ← Authentication ← Emails ← SMTP Settings: אם **Enable Custom SMTP** דלוק עם פרטי Gmail — מכבים (ה-Hook מחליף אותו ממילא).
5. בדיקה: "שכחתי סיסמה" באתר עם המייל שלכם. המייל צריך להגיע תוך דקה.
6. **רק אחרי שהמייל הגיע:** Sign In / Providers ← Email ← **Confirm email** דלוק.

## בדיקת מצב (SQL Editor)
```sql
select * from public.hdm_mail_status();
```
- `queued` + `relay_http = {302}` — המייל הגיע ל-Google והסקריפט רץ.
- `relay_not_configured` — לא הורץ `hdm_mail_setup` (שלב 4).
- ב-Google: script.google.com ← הפרויקט ← **Executions** מראה כל הרצה, ו-`denied` אם המפתח לא תואם.

## אם המפתח דלף
מריצים שוב `hdm_mail_setup('<אותה כתובת>')` — נוצר מפתח חדש והישן מפסיק לעבוד מיד. מדביקים את החדש בסקריפט (שלב 5).
