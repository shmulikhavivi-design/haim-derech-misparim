# תבניות מייל בעברית — Supabase (טיוטה לאישור, 24.10.2026)

**מצב היום ב-Production:** התבניות הן ברירת המחדל באנגלית של Supabase ("Confirm your email address", "Reset your password"). התבניות כאן עוד לא הוחלו.

**מקום:** Supabase ← Haim Derech Misparim ← Authentication ← Emails ← Templates. בכל תבנית מחליפים **Subject** ו-**Message body** ולוחצים Save. ⛔ רק באישור הבעלים, קודם Staging.

**השולח** (SMTP Settings): `noreply@haimderechmisparim.com`, בשם `חיים דרך מספרים` (מאומת ב-Brevo, DKIM + DMARC). Reply-To לתשובות: `life.through.numbers333@gmail.com`.

## עקרונות (מסירה טובה + נגישות)
- נושא בעברית, ספציפי, בלי סימני קריאה, בלי מילים "שיווקיות" (חינם, מבצע וכו').
- טקסט אמיתי לצד הכפתור. כפתור אחד בלבד, בלי תמונות, בלי קישורים נוספים (כל קישור עובר דרך מעקב Brevo).
- `{{ .ConfirmationURL }}` חייב להישאר בדיוק כך. הוא חוזר לכתובת שממנה המשתמש נרשם (חדשה או ישנה).
- פרטי העסק בתחתית (שקיפות לנמען ולמסנני ספאם).
- צבע הכפתור: ורוד עתיק `#994F69` כמו באפליקציה.

## Confirm signup (אישור הרשמה)
**Subject:** `אישור כתובת המייל שלך — חיים דרך מספרים`

```html
<div dir="rtl" lang="he" style="font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:1.7;color:#222;max-width:560px;margin:0 auto;text-align:right">
  <p style="font-size:20px;font-weight:bold;margin:0 0 12px">ברוכים הבאים ל"חיים דרך מספרים"</p>
  <p>תודה שנרשמת. כדי להשלים את ההרשמה ולהתחיל להכיר אנשים שמתאימים לך, יש לאשר את כתובת המייל שלך:</p>
  <p style="margin:24px 0"><a href="{{ .ConfirmationURL }}" style="background:#994F69;color:#ffffff;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:bold;display:inline-block">אישור כתובת המייל</a></p>
  <p>הקישור תקף לזמן מוגבל. אם הוא פג, אפשר לבקש קישור חדש במסך הכניסה לאפליקציה.</p>
  <p>אם לא נרשמת ל"חיים דרך מספרים", אפשר להתעלם מהמייל. לא ייפתח חשבון בלי אישור.</p>
  <hr style="border:none;border-top:1px solid #ddd;margin:24px 0">
  <p style="font-size:13px;color:#666;margin:0">חיים דרך מספרים · haimderechmisparim.com<br>אורן 3, קיסריה · 054-6628866 · life.through.numbers333@gmail.com<br>קיבלת מייל זה כי נרשמת לאפליקציה בכתובת הזו.</p>
</div>
```

## Reset Password (איפוס סיסמה)
**Subject:** `איפוס הסיסמה שלך — חיים דרך מספרים`

```html
<div dir="rtl" lang="he" style="font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:1.7;color:#222;max-width:560px;margin:0 auto;text-align:right">
  <p style="font-size:20px;font-weight:bold;margin:0 0 12px">איפוס סיסמה</p>
  <p>שלום,</p>
  <p>קיבלנו בקשה לאפס את הסיסמה של החשבון שלך ב"חיים דרך מספרים". לבחירת סיסמה חדשה:</p>
  <p style="margin:24px 0"><a href="{{ .ConfirmationURL }}" style="background:#994F69;color:#ffffff;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:bold;display:inline-block">בחירת סיסמה חדשה</a></p>
  <p>הקישור תקף לזמן מוגבל ולשימוש אחד.</p>
  <p>אם לא ביקשת לאפס סיסמה, אפשר להתעלם מהמייל. הסיסמה הנוכחית שלך לא תשתנה.</p>
  <hr style="border:none;border-top:1px solid #ddd;margin:24px 0">
  <p style="font-size:13px;color:#666;margin:0">חיים דרך מספרים · haimderechmisparim.com<br>אורן 3, קיסריה · 054-6628866 · life.through.numbers333@gmail.com<br>קיבלת מייל זה כי התבקש איפוס סיסמה לחשבון בכתובת הזו.</p>
</div>
```

## Change Email Address (שינוי מייל)
**Subject:** `אישור כתובת מייל חדשה — חיים דרך מספרים`

```html
<div dir="rtl" lang="he" style="font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:1.7;color:#222;max-width:560px;margin:0 auto;text-align:right">
  <p>שלום,</p>
  <p>התבקש שינוי של כתובת המייל בחשבון שלך ב"חיים דרך מספרים". לאישור הכתובת החדשה:</p>
  <p style="margin:24px 0"><a href="{{ .ConfirmationURL }}" style="background:#994F69;color:#ffffff;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:bold;display:inline-block">אישור הכתובת החדשה</a></p>
  <p>אם לא ביקשת זאת, אפשר להתעלם מהמייל. הכתובת הקיימת לא תשתנה.</p>
  <hr style="border:none;border-top:1px solid #ddd;margin:24px 0">
  <p style="font-size:13px;color:#666;margin:0">חיים דרך מספרים · haimderechmisparim.com<br>אורן 3, קיסריה · 054-6628866 · life.through.numbers333@gmail.com</p>
</div>
```
