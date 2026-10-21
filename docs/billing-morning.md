# סליקה דרך Morning (חשבונית ירוקה) + Grow — מצב והפעלה

**מצב (21.10.2026):** הכול מוכן ונבדק ב-Staging. הסליקה כבויה (`HDM_BILLING_LIVE = false`, `MORNING_LIVE=0`).
אין חיובים, אין שינוי ב-Production, ושום דבר לא מוזג.

## איך זה עובד (לפי התיעוד הרשמי — developers.morning.co)
| שלב | מה קורה | איפה |
|---|---|---|
| הצטרפות | עמוד התשלום הקיים (אישור תקנון חובה) → `hdm_billing_start_checkout` → `morning-checkout` → `POST /payments/form` → דף התשלום המאובטח של Grow | פרטי הכרטיס לא עוברים דרכנו |
| אישור תשלום | Morning מודיעה ל-`morning-webhook` (notifyUrl עם טוקן סודי, או Webhook חתום HMAC-SHA256 מממשק Morning). בכל מקרה המסמך נשלף מחדש מ-Morning (`GET /documents/{id}`) ומושווה: סוג, מטבע, מייל, זמן, סכום, לא מבוטל | המנוי מופעל **רק** אחרי האימות, פעם אחת לכל מסמך |
| שמירת כרטיס | אחרי תשלום ראשון: `POST /payments/tokens/search` לפי `externalKey` (מזהה הלקוח), טוקן בסטטוס תקף | לחידושים |
| חידוש חודשי | `morning-renewals` (משימה מתוזמנת) תופסת חיוב אחד לכל תקופה ומחייבת `POST /payments/tokens/{id}/charge` | הארכה רק אחרי תשובה חיובית; כישלון = עד 3 ניסיונות, 48 שעות ביניהם |
| שדרוג | חיוב יחסי מיידי בכרטיס השמור; המסלול מתעדכן רק אחרי אישור; תאריך החיוב לא משתנה | נגד לחיצה כפולה |
| ביטול חידוש | `hdm_billing_cancel` מכבה את החידוש; המנוי פעיל עד סוף התקופה ששולמה | ב-API של Morning אין "הוראת קבע" ואין API לביטול/החזר — השרת פשוט לא מחייב. החזר לפי החוק — ידנית בממשק Morning/Grow |

## קבצים
- `supabase/functions/_shared/morning.ts` + `morning-checkout`, `morning-webhook`, `morning-renewals` — **פרוסות ב-Staging** (כבויות).
- `supabase/production/08_production_billing.sql` — המעבר ל-Production, נבנה אוטומטית מ-17+19+21+23+24 (`scripts/release/build_production_billing_sql.py`). "הכול או כלום"; לא משנה מסלולים, מחירים או משתמשים.
- `scripts/release/test_billing_local.sh` — בודק את 08 על מסד מקומי שמדמה את Production (רץ אוטומטית ב-PR).

## בדיקות (21.10.2026)
- יחידה: 17/17 · שמירה על הפונקציות החיות ב-Staging: 12/12 (כולל Webhook חתום)
- מסד Staging: 18 (83/83), 20 (59/59), 22 (68/68), 25 (41/41)
- דפדפן מול Staging: כפתור "המשך לתשלום מאובטח" — 24/24 (שלושת המסלולים, לחיצה כפולה, חזרה מעמוד התשלום)
- 08 על מסד מקומי בדמות Production: 20/20 (כולל 251 בדיקות המנויים)
- Morning אמיתי, בלי חיוב: אימות, תצוגת חשבונית 29.90/48.90/79.90 כולל מע"מ 18%, דפי תשלום לשלושת המסלולים, חיפוש כרטיסים

## הפעלה (כל שלב רק באישור מפורש)
1. חיוב בדיקה אחד קטן בכרטיס של הבעלים (סכום, אמצעי, החזר — מוצגים לאישור לפני).
2. טוקן Supabase זמני לפרויקט ה-Production בלבד: Database read-write + Edge Functions (+ Secrets). נשמר כ-`PRODUCTION_SUPABASE_TOKEN` בסביבה production, ונמחק אחרי ההפעלה.
3. גיבוי מלא של Production → 08 → בדיקה.
4. פריסת הפונקציות ל-Production עם המפתחות שכבר שמורים (`MORNING_CLIENT_ID/SECRET`), `HDM_ENV=production`, משימת חידוש מתוזמנת.
5. `HDM_BILLING_LIVE = true` ומיזוג PR #38.

## לא נעשה בלי אישור מפורש
חיוב אמיתי, כל שינוי ב-Production, מיזוג.
