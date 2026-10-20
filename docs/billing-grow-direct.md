# סליקה ישירה דרך Grow — מצב, בדיקות ומה חסר

**מצב:** Staging בלבד. החיובים כבויים (`GROW_LIVE` לא מוגדר). עמוד התשלום הקיים באפליקציה **לא שונה**. אין שינוי ב-Production ושום דבר לא מוזג.

## איך זה עובד
| שלב | מה קורה | הגנה |
|---|---|---|
| הצטרפות | הלקוח מאשר תנאים → ניסיון תשלום במסד → `grow-checkout` יוצרת דף תשלום של Grow (`createPaymentProcess`, `saveCardToken=1`) | פרטי הכרטיס לא עוברים דרכנו; המחיר נקבע בשרת (29.90 / 48.90 / 79.90) |
| אישור תשלום | Grow שולחת הודעה ל-`grow-webhook` | ההודעה לא חתומה: טוקן סודי בכתובת + `getTransactionInfo` מול Grow; הסכום נלקח מ-Grow ונבדק מול המחיר; כל עסקה נקלטת פעם אחת; אחר כך `approveTransaction` |
| שמירת כרטיס | הטוקן, 4 ספרות, שם וטלפון המשלם (מהודעת Grow) | טבלה סגורה לשרת בלבד; נמחקת עם החשבון |
| חידוש חודשי | `grow-renewals` (פעם בשעה) מחייבת את הכרטיס השמור באותו תאריך בכל חודש (`createTransactionWithToken`) | חיוב אחד לכל תקופה גם בהרצה כפולה; מזהה ייחודי יציב לכל חיוב (Grow דוחה כפילות); הארכה רק אחרי תשובה חיובית |
| חיוב שנכשל | המנוי לא מוארך; עד 3 ניסיונות, 48 שעות ביניהם | אין תשובה מ-Grow → לא מנסים שוב (ייתכן שחויב), לבדיקה ידנית |
| שדרוג | חיוב יחסי מיידי על יתרת התקופה; המסלול מתעדכן רק אחרי אישור; תאריך החיוב לא משתנה | לחיצה כפולה לא מחייבת פעמיים |
| ביטול חידוש | מכבה את החידוש מיד; גישה עד סוף התקופה ששולמה; אישור במייל | Grow לא מחייבת לבד במודל הזה — ביטול מאושר רק כשהחידוש אצלנו כבר כבוי |
| ביטול עסקה לפי החוק | בתוך 14 יום: השירות מופסק וההחזר נפתח לטיפול | נפרד מביטול החידוש (מדיניות 19.10) |

## קבצים
- `supabase/functions/_shared/grow.ts` + `grow_test.ts` (14 בדיקות, בלי רשת)
- `supabase/functions/grow-checkout`, `grow-webhook`, `grow-renewals` — טרם נפרסו
- `supabase/functions/hdm-billing-worker` — אישור ביטולים במקום "לא מומש"
- `supabase/staging_secure/24_staging_billing_morning.sql` — פונקציות כלליות (פרטי ניסיון תשלום, "תפיסה" חד-פעמית); כבר מותקן ב-Staging
- `supabase/staging_secure/26_staging_billing_grow.sql` + `27_staging_billing_grow_tests.sql` (57 בדיקות לכל חיי המנוי)

## בדיקות
- יחידה: 14/14 ✅
- מסד מקומי: 18 (83/83), 20 (59/59), 22 (68/68), 27 (57/57) ✅
- Staging: install26 ✅ · tests27 57/57 ✅ (בוטל בסוף, לא נשמר כלום) · growsecrets: אין עדיין סודות Grow בסביבה staging

## איפה שומרים את המפתחות (בלי להדביק בצ'אט)
GitHub ← הריפו ← **Settings** ← **Environments** ← **staging** ← **Add environment secret**:

| שם הסוד | מה לשים | מקור |
|---|---|---|
| `GROW_SANDBOX_USER_ID` | UserId של סביבת הבדיקות | Grow |
| `GROW_SANDBOX_PAGE_CODE` | PageCode לכרטיס אשראי בסביבת הבדיקות | Grow |
| `GROW_SANDBOX_API_KEY` | API Key של סביבת הבדיקות (אם Grow נותנת) | Grow |
| `GROW_CLIENT_ID`, `GROW_API_KEY` | הפרטים שכבר קיבלתם — רק לבדיקת קיום ולשאלה ל-Grow מה הם | יש לכם |

הסודות נבדקים במצב `growsecrets` (קיים/חסר בלבד, בלי להדפיס ערכים). בפריסה ל-Staging הם יועברו לסודות של Supabase Staging בלבד.
פרטי Production של Grow לא נכנסים ל-Staging, והקוד חוסם חיוב בחשבון ה-Production של Grow מחוץ ל-Production.

## מה חסר כדי להתחיל בדיקות Sandbox
1. **פרטי Sandbox מ-Grow:** UserId, PageCode לאשראי, ו-API Key אם נדרש. (התיעוד: לכל סביבה מזהים משלה; המעבר ל-Production רק אחרי שהבדיקות הושלמו.)
2. **מה הם ה-"Client ID" וה-"API Key" שקיבלתם:** לפי התיעוד, עסק שסולק לעצמו מזדהה ב-UserId + PageCode, ו-API Key נדרש לפלטפורמות. לשאול אם Client ID = UserId.
3. **הרשאת Token ("Premium recurring — managed by you")** בסביבת הבדיקות ובהמשך באמת. בלעדיה `saveCardToken` לא מחזיר טוקן ואין חידוש אוטומטי.
4. **הפעלת הודעות שרת (notifyUrl)** לחשבון, ורישום כתובת הבדיקה (`updateMyUrl` ב-Sandbox).
5. **אישורים מ-Grow על פרטים שהתיעוד לא מכסה:**
   - האם דף התשלום אוסף שם מלא וטלפון בעצמו (האפליקציה לא אוספת טלפון), ושהם חוזרים בהודעת השרת.
   - בחיוב חוזר בכרטיס: `paymentType=2` עם `isRecurringDebitPayment=1` ואחר כך `recurringDebitId` — זה הנכון למודל "managed by you"?
   - טווח המספר של `transactionUniqueIdentifier` (אנחנו שולחים 9 ספרות).
   - שדות התשובה של `createTransactionWithToken` (שם השדה של מזהה העסקה ושל `recurringDebitId`).
6. **Supabase:** פריסת 3 הפונקציות ל-Staging (יש הרשאה ב-GitHub) — אחרי שסעיף 1 קיים.

## לא נעשה בלי אישור מפורש
חיבור עמוד התשלום הקיים לפונקציות, `GROW_LIVE=1` בסביבה אמיתית, כל שינוי ב-Production, מיזוג.
