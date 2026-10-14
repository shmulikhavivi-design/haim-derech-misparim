// =====================================================================
// חיים דרך מספרים — ממסר מיילים (Google Apps Script)
// רץ בחשבון Google של האפליקציה (life.through.numbers333@gmail.com) ושולח את מיילי ההרשמה והאיפוס
// מהחשבון עצמו. בלי סיסמת אפליקציה, בלי SMTP ובלי דומיין.
//
// מי קורא לו: רק Supabase (הפונקציה hdm_send_email_hook), עם מפתח סודי שנשמר ב-Vault.
// מכסה של Google לחשבון Gmail רגיל: עד 100 נמענים ביום.
//
// התקנה: ראו docs/email-gmail-relay.md. בשורה הבאה מדביקים את המפתח שהחזירה hdm_mail_setup —
// רק כאן, בעורך של Google. לא בצ'אט ולא ב-GitHub.
// =====================================================================
const KEY = 'PASTE_KEY_HERE';
const SENDER_NAME = 'חיים דרך מספרים';
const REPLY_TO = 'life.through.numbers333@gmail.com';

function doPost(e) {
  try {
    if (KEY === 'PASTE_KEY_HERE' || KEY.length < 32) return reply_('not-configured');
    const d = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    if (!safeEqual_(String(d.key || ''), KEY)) return reply_('denied');
    const to = String(d.to || '').trim();
    if (!/^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$/.test(to)) return reply_('bad-recipient');
    MailApp.sendEmail({
      to: to,
      subject: String(d.subject || '').slice(0, 200),
      htmlBody: String(d.html || ''),
      body: String(d.text || ''),
      name: SENDER_NAME,
      replyTo: REPLY_TO
    });
    return reply_('sent');
  } catch (err) {
    console.error(err);
    return reply_('error');
  }
}

// להרצה ידנית פעם אחת מהעורך (▶ Run): מאשר הרשאת שליחה, ומראה כמה מיילים נשארו היום.
function authorize() {
  console.log('נשארו היום: ' + MailApp.getRemainingDailyQuota() + ' מיילים');
}

function safeEqual_(a, b) {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

function reply_(s) {
  return ContentService.createTextOutput(s);
}
