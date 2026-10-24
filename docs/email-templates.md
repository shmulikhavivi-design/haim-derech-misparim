# תבניות מייל בעברית — Supabase Production

מקום: Supabase ← Haim Derech Misparim ← Authentication ← Emails ← Templates.
בכל תבנית מחליפים את **Subject** ואת **Message body**, ולוחצים Save. הקישור `{{ .ConfirmationURL }}` חייב להישאר בדיוק כך.
השולח (Sender) נקבע ב-SMTP Settings דרך Brevo (`smtp-relay.brevo.com`), בשם `חיים דרך מספרים`. כרגע: `life.through.numbers333@gmail.com` (Brevo מחליף אותו בדומיין משותף, וחלק מהשרתים דוחים אותו). היעד: `noreply@<הדומיין>` מאומת. ראו [email-sender-domain.md](email-sender-domain.md).

## Reset Password (שכחתי סיסמה — גם הכניסה הראשונה של חשבונות קיימים אחרי המעבר)
**Subject:** `איפוס סיסמה — חיים דרך מספרים`

```html
<div dir="rtl" style="font-family:Arial,sans-serif;font-size:16px;line-height:1.6">
  <p>שלום,</p>
  <p>קיבלנו בקשה להגדיר סיסמה לחשבון שלך ב"חיים דרך מספרים".</p>
  <p><a href="{{ .ConfirmationURL }}" style="background:#6b4fa0;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none">להגדרת סיסמה</a></p>
  <p>אם לא ביקשת זאת, אפשר להתעלם מהמייל. החשבון לא ישתנה.</p>
  <p>חיים דרך מספרים · life.through.numbers333@gmail.com</p>
</div>
```

## Confirm signup (אישור הרשמה)
**Subject:** `אישור הרשמה — חיים דרך מספרים`

```html
<div dir="rtl" style="font-family:Arial,sans-serif;font-size:16px;line-height:1.6">
  <p>ברוכים הבאים ל"חיים דרך מספרים"!</p>
  <p>כדי להשלים את ההרשמה, יש לאשר את כתובת המייל:</p>
  <p><a href="{{ .ConfirmationURL }}" style="background:#6b4fa0;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none">אישור המייל</a></p>
  <p>אם לא נרשמת, אפשר להתעלם מהמייל.</p>
  <p>חיים דרך מספרים · life.through.numbers333@gmail.com</p>
</div>
```

## Change Email Address (שינוי מייל)
**Subject:** `אישור כתובת מייל חדשה — חיים דרך מספרים`

```html
<div dir="rtl" style="font-family:Arial,sans-serif;font-size:16px;line-height:1.6">
  <p>כדי לאשר את כתובת המייל החדשה בחשבון שלך:</p>
  <p><a href="{{ .ConfirmationURL }}" style="background:#6b4fa0;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none">אישור הכתובת</a></p>
  <p>אם לא ביקשת זאת, אפשר להתעלם מהמייל.</p>
</div>
```
