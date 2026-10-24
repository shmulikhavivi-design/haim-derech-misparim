# ספק חלופי למיילי אימות ואיפוס: Resend (מוכן, לא מופעל)

מופעל **רק** אם בדיקת מסירה ל-Walla מהשולח החדש (`noreply@haimderechmisparim.com` דרך Brevo) תיכשל. ⛔ כל שלב רק באישור הבעלים. קודם Staging.

## למה זה יכול לפתור את Walla
שרתי Walla (Cisco) דוחים כשאחד הדומיינים שמשתתפים בהעברה הוא בעל מוניטין נמוך. ב-Brevo, גם אחרי ההחלפה, נשארים שני דומיינים משותפים של Brevo:
- כתובת ההחזרות (Return-Path).
- עטיפת הקישורים (מעקב קליקים). בחבילה החינמית אי אפשר לכבות אותה.

ב-Resend:
- כתובת ההחזרות על תת-דומיין שלנו (`send.haimderechmisparim.com`).
- מעקב קליקים/פתיחות כבוי, אלא אם מפעילים.
- כך כל הדומיינים במייל הם שלנו.

## מגבלות החבילה החינמית
3,000 מיילים בחודש, 100 ביום, עד 3 דומיינים. היום נשלחים כ-35 מיילים ביום (כולל בדיקות).

## שלבים
1. **חשבון Resend** (הבעלים, חינם) ← Domains ← Add domain ← `haimderechmisparim.com`. מעקב קליקים ופתיחות: **כבוי**.
2. **DNS ב-Cloudflare** ⛔ אישור: מעתיקים את הרשומות מ-Resend.
   - DKIM: `resend._domainkey`.
   - כתובת ההחזרות: `send` ו-`rsend` (או MX + TXT על `send`), **DNS only**.
   - כולן על תת-דומיינים, ולכן לא נוגעות ברשומות של Brevo ולא ב-SPF של השורש.
3. **מפתח API** ב-Resend (Sending access בלבד, לדומיין הזה). לא מדביקים בצ'אט.
4. **Staging קודם** — Supabase Staging ← Authentication ← Emails ← SMTP Settings:
   - Host `smtp.resend.com`, Port `465`, Username `resend`, Password = המפתח מ-Resend.
   - Sender `noreply@haimderechmisparim.com`, שם `חיים דרך מספרים`.
5. **בדיקת מסירה ל-Walla** מ-Staging (תיבת בדיקה). רק אם עברה:
6. **Production** ⛔ אישור: אותם ארבעה שדות ב-SMTP Settings. השולח, הקישורים, התבניות וההרשמות הקיימות לא משתנים.

## חזרה אחורה
מחזירים ב-SMTP Settings את ערכי Brevo:
- Host `smtp-relay.brevo.com`, Port `587`.
- Username ומפתח ה-SMTP של Brevo.
- החשבון ב-Brevo נשאר פעיל, ומיילי ביטול המנוי (`hdm-billing-worker`) ממשיכים ב-Brevo בלי שינוי.

## אחרי שהמסירה עובדת
קישור אימות חדש ל-4 לקוחות Walla שנדחו (22–24.10), דרך כפתור "שלחו לי מייל אימות חדש" (PR #42) או שליחה יזומה ⛔ אישור. בלי מחיקת חשבונות ובלי שינוי סטטוס.
