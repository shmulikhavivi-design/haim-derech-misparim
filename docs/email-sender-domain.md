# דומיין שולח מאומת למיילים של "חיים דרך מספרים" (Brevo + Cloudflare)

## למה
היום השולח הוא `life.through.numbers333@gmail.com` דרך Brevo. Brevo לא רשאי לשלוח בשם כתובת Gmail, ולכן הוא מחליף את השולח בכתובת על דומיין משותף שלו (`…t-sender-sib.com`). לחלק משרתי המייל יש מוניטין נמוך לדומיין המשותף הזה, והם דוחים את המייל. כך קרה ב-24.10, כשמייל אישור ההרשמה של משתמשת חדשה נדחה בשגיאה 554 ("poor reputation of a domain used in message transfer"). אי אפשר לתקן מוניטין של דומיין משותף. הפתרון הוא דומיין משלנו, מאומת ב-Brevo.

## ממצאים (24.10, Brevo, 30 יום, קריאה בלבד)
- Gmail: 39 מתוך 39 נמסרו. maxxspace.com: 4 מתוך 4.
- Walla: 0 מתוך 5. walla.com 3 החזרות, walla.co.il 2. אלה 4 כתובות שונות, כולן במייל אישור הרשמה, כולן 554.
- השולח בפועל: `12475065.brevosend.com`. אין ב-Brevo שולח או דומיין מאומתים.
- שרתי הדואר של Walla הם Cisco Secure Email (`iphmx.com`). הם בודקים מוניטין של כל דומיין שמשתתף בהעברה, ודוחים את הדומיין המשותף של Brevo.

## מה נשאר כמו שהוא
- חשבון Brevo, שרת ה-SMTP (`smtp-relay.brevo.com`, פורט 587) ושם המשתמש/המפתח של ה-SMTP.
- תבניות המייל וכתובת הקשר בתוכן (`life.through.numbers333@gmail.com`).
- רק **כתובת השולח** משתנה, ל-`noreply@<הדומיין>`, והתשובות (Reply-To) ממשיכות להגיע ל-Gmail.

## שלבים — כל אחד רק באישור הבעלים

### 1. קניית הדומיין ⛔ אישור
Cloudflare ← Domain Registration ← Register Domains. הצעה: `haimderechmisparim.com`, כ-10–12$ לשנה (לוודא מחיר וזמינות בזמן הקנייה). ה-DNS מנוהל אוטומטית ב-Cloudflare. לא צריך אתר או תיבת מייל על הדומיין.

### 2. הוספת הדומיין ב-Brevo
Brevo ← Senders, Domains & Dedicated IPs ← **Domains** ← Add a domain ← מקלידים את הדומיין.
Brevo מציג 4 רשומות. אם מוצע **Authenticate automatically** מול Cloudflare, משתמשים בו (מתחברים ל-Cloudflare ומאשרים). אחרת מוסיפים ידנית בשלב 3.

### 3. רשומות ה-DNS ב-Cloudflare ⛔ אישור
Cloudflare ← הדומיין ← DNS ← Records ← Add record. את הערכים **מעתיקים מ-Brevo**. הצורה הצפויה:

| סוג | שם | ערך | הערה |
|---|---|---|---|
| TXT | `@` | `brevo-code:…` | קוד אימות הבעלות |
| CNAME | `brevo1._domainkey` | `b1.<הדומיין>.dkim.brevo.com` | **Proxy: DNS only** (ענן אפור) |
| CNAME | `brevo2._domainkey` | `b2.<הדומיין>.dkim.brevo.com` | **Proxy: DNS only** (ענן אפור) |
| TXT | `_dmarc` | `v=DMARC1; p=none; rua=mailto:rua@dmarc.brevo.com` | חובה למסירה ל-Outlook/Hotmail |

- **SPF:** לא נדרש ל-Brevo, כי כתובת ההחזרות היא של Brevo וההתאמה ל-DMARC נעשית דרך DKIM. אם יום אחד יתווסף עוד שירות ששולח מהדומיין, צריכה להיות רשומת SPF **אחת** בלבד.
- **ענן אפור:** רשומות CNAME עם Proxy כתום לא יעבדו ל-DKIM.

בדיקה (קריאה בלבד): `bash scripts/email/check_sender_dns.sh <הדומיין>`.

### 4. אימות ב-Brevo ושולח חדש
- Brevo ← Domains ← **Authenticate**. ממתינים לסימן ירוק ב-Brevo code, DKIM ו-DMARC.
- Brevo ← **Senders** ← Add a sender: שם `חיים דרך מספרים`, כתובת `noreply@<הדומיין>`. היא מאומתת אוטומטית דרך הדומיין.

### 5. Staging קודם
Supabase ← **Haim Derech Misparim Staging** ← Authentication ← Emails ← SMTP Settings ← **Sender email** = `noreply@<הדומיין>` ← Save.
בדיקה: הרצת `scripts/email/e2e_resend_staging.py` דרך GitHub Actions (רק כתובות כינוי של תיבת האפליקציה), ובדיקה בתיבה ובכותרות המייל (Show original): `DKIM: PASS` עם הדומיין שלנו, `DMARC: PASS`.
**בדיקת Walla (חובה):** מייל אישור אחד מ-Staging לתיבת Walla של הבעלים. אם הוא עדיין נדחה, Cisco חוסם גם את כתובת ההחזרות של Brevo. במקרה כזה עוברים לספק שגם כתובת ההחזרות שלו על הדומיין שלנו (למשל Resend, `send.<הדומיין>`), עם אותו דומיין ובלי השפעה על משתמשים רשומים.

### 6. Production ⛔ אישור
- Supabase ← **Haim Derech Misparim** ← Authentication ← Emails ← SMTP Settings ← **Sender email** = `noreply@<הדומיין>` ← Save. שאר השדות נשארים.
- סודות הפונקציות (Edge Function Secrets): `MAIL_FROM` = `noreply@<הדומיין>`, `MAIL_REPLY_TO` = `life.through.numbers333@gmail.com`.
- בדיקה אחת: "שכחתי סיסמה" למייל של הבעלים בלבד.

### 7. אחרי 2–4 שבועות תקינים
להחמיר את DMARC ל-`p=quarantine` (לפי דוחות DMARC ב-Brevo).

## משתמש שמייל האישור שלו נדחה
1. **רק אחרי שלב 6:** Brevo ← Transactional ← Logs ← לחפש את הכתובת. אם היא ב-**Blocked contacts** עם סיבה Hard/Soft bounce, אפשר לשחרר. אם הסיבה Unsubscribed או Spam complaint, לא משחררים.
2. המשתמש נכנס למסך ההתחברות עם האימייל והסיסמה. מופיעה הודעת "צריך לאשר" וכפתור **"לא קיבלתם מייל אימות? שלחו לי מייל חדש"**. הכפתור שולח דרך Supabase (`auth.resend`) קישור אימות **חדש**, במקום הקודם שאולי פג. בלי מחיקת חשבון ובלי עקיפת האימות.
3. לחלופין (⛔ אישור), הבעלים מפעילים את אותה בקשה עבור הכתובת: `POST /auth/v1/resend` עם `type: signup`.
