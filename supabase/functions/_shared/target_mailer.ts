// =====================================================================
// חיים דרך מספרים — שליחת התראות "קיבלת חץ 🎯" מהתור (hdm_target_email_outbox) דרך ה-API של Brevo.
// אותה תשתית מייל כמו מיילי הביטול (BREVO_API_KEY, MAIL_FROM, MAIL_REPLY_TO) — בלי שינוי בהגדרות SMTP.
// לב הלוגיקה, בלי Deno.serve — נבדק עם מסד ו-fetch מדומים.
// - מתג הפעלה: TARGET_EMAILS_LIVE=1. בלעדיו — לא נוגעים בתור בכלל (ברירת מחדל: כבוי). DRY_RUN=1: לא שולחים.
// - לכל היותר פעם אחת: claim (תפיסה) → begin (בדיקה אחרונה + "sending", נשמר לפני המסירה) → Brevo → done.
// - ביטול התראות מול מסירה: כל המסירה (begin + הקריאה ל-Brevo + done) מתבצעת בתוך נעילה של המשתמש
//   (pg_advisory_lock, חיבור ישיר אחד למסד). ביטול התראות לוקח את אותה נעילה — ולכן:
//   ביטול שנשמר לפני המסירה → begin מסרב ולא נשלח; ביטול שנשלח בזמן המסירה ממתין לסופה ונכנס לתוקף מיד אחריה.
// - במייל אין שום פרט על שולח החץ: הנושא והגוף מגיעים מהשרת (hdm_target_email_text), זהים לכולם.
// =====================================================================
import { BREVO_URL } from './email_worker.ts';

export type TargetMail = { id: number; kind: string; to_email: string; subject: string; body_text: string };
export const SITE = 'https://haimderechmisparim.com';

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string);

export function targetEmailHtml(subject: string, text: string): string {
  const paras = String(text ?? '').replace(/\r/g, '').trim().split(/\n{2,}/).map((p) => p.trim()).filter(Boolean);
  const body = paras.map((p) => {
    // שורה שהיא רק הקישור הראשי — כפתור
    if (p === SITE) {
      return `<p style="margin:4px 0 20px 0;text-align:center"><a href="${SITE}" dir="ltr" style="display:inline-block;background:#994F69;color:#ffffff;text-decoration:none;font-weight:bold;padding:12px 28px;border-radius:24px">כניסה לאפליקציה</a></p>`;
    }
    let h = esc(p).replace(/\n/g, '<br>');
    h = h.replace(/(https:\/\/haimderechmisparim\.com[^\s<]*)/g, '<a href="$1" style="color:#7a5a1e" dir="ltr">$1</a>');
    return `<p style="margin:0 0 16px 0">${h}</p>`;
  }).join('');
  return '<!doctype html><html lang="he" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    + `<title>${esc(subject)}</title></head>`
    + '<body style="margin:0;padding:0;background:#f4f1ec">'
    + '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f1ec"><tr><td align="center" style="padding:24px 12px">'
    + '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:12px">'
    + '<tr><td dir="rtl" style="padding:24px 22px 8px 22px;text-align:right;font-family:Arial,Helvetica,sans-serif;font-size:20px;font-weight:bold;color:#7a5a1e">חיים דרך מספרים</td></tr>'
    + `<tr><td dir="rtl" style="padding:8px 22px 8px 22px;text-align:right;font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:1.7;color:#1f1b16">${body}</td></tr>`
    + '<tr><td dir="rtl" style="padding:12px 22px 22px 22px;text-align:right;font-family:Arial,Helvetica,sans-serif;font-size:12px;line-height:1.6;color:#8a8076;border-top:1px solid #eee5d8">'
    + 'קיבלת את ההודעה כי מישהו סימן אותך 🎯 באפליקציה „חיים דרך מספרים”.</td></tr>'
    + '</table></td></tr></table></body></html>';
}

export function targetBrevoBody(m: TargetMail, from: string, replyTo: string) {
  const b: Record<string, unknown> = {
    sender: { name: 'חיים דרך מספרים', email: from },
    to: [{ email: m.to_email }],
    subject: m.subject,
    textContent: m.body_text,
    htmlContent: targetEmailHtml(m.subject, m.body_text),
    tags: ['hdm-target_received'],
    headers: { 'List-Unsubscribe': `<${SITE}/#notify>` },
  };
  if (replyTo) b.replyTo = { email: replyTo };
  return b;
}

export type Outcome = 'sent' | 'rejected' | 'uncertain';
// תשובה 2xx = נשלח. 4xx = Brevo דחה במפורש (לא נשלח) — מותר לנסות שוב. כל השאר (5xx, ניתוק, זמן קצוב) — לא ברור
// אם נשלח, ולכן לא שולחים שוב (עדיף מייל אחד שאולי לא הגיע על פני מייל כפול).
export function classify(status: number | null): Outcome {
  if (status !== null && status >= 200 && status < 300) return 'sent';
  if (status !== null && status >= 400 && status < 500) return 'rejected';
  return 'uncertain';
}

// המסד — מוזרק (במבחנים: מדומה). withUserLock מחזיק נעילת משתמש לכל אורך fn (כולל הקריאה ל-Brevo).
export interface QueueDb {
  claim(limit: number): Promise<number[]>;
  withUserLock<T>(id: number, fn: () => Promise<T>): Promise<T>;
  begin(id: number): Promise<TargetMail | null>;
  done(id: number, outcome: Outcome, error: string | null): Promise<void>;
}

export function brevoUrl(env: (k: string) => string): string {
  // כתובת בדיקה (שרת שמשהה תשובה) — רק ב-Staging, ולעולם לא ב-Production
  const t = env('BREVO_URL_TEST');
  return env('HDM_ENV') === 'staging' && /^https:\/\//.test(t) ? t : BREVO_URL;
}

export async function sendTargetEmails(env: (k: string) => string, db: QueueDb, fetchFn: typeof fetch) {
  if (env('TARGET_EMAILS_LIVE') !== '1') return { skipped: 'off' };
  const key = env('BREVO_API_KEY'), from = env('MAIL_FROM');
  if (!key || !from) return { skipped: 'not_configured' };
  if (env('DRY_RUN') === '1') return { skipped: 'dry_run' };
  const url = brevoUrl(env);
  const ids = await db.claim(20);
  let sent = 0, rejected = 0, uncertain = 0, skipped = 0;
  for (const id of ids) {
    const outcome = await db.withUserLock(id, async (): Promise<Outcome | 'skipped'> => {
      // בדיקה אחרונה בשרת (ביטול התראות / חסימה / חץ שבוטל / חשבון) — רק קריאה אחת מצליחה לכל מייל
      const m = await db.begin(id);
      if (!m || !m.to_email) return 'skipped';
      let status: number | null = null, err = '';
      try {
        const r = await fetchFn(url, {
          method: 'POST',
          headers: { 'api-key': key, 'content-type': 'application/json', accept: 'application/json' },
          body: JSON.stringify(targetBrevoBody({ ...m, kind: 'target_received' }, from, env('MAIL_REPLY_TO'))),
          signal: AbortSignal.timeout(15000),
        });
        status = r.status;
        if (!r.ok) err = `brevo ${r.status}`;
        await r.body?.cancel();
      } catch (e) { err = 'network: ' + String(e).slice(0, 150); }
      const o = classify(status);
      // סימון התוצאה. אם הסימון נכשל — השורה נשארת "sending" ולא תישלח שוב לעולם.
      for (let i = 0; i < 3; i++) {
        try { await db.done(id, o, o === 'sent' ? null : err); break; }
        catch (e) { console.error('target email done failed', id, i, String(e).slice(0, 120)); }
      }
      return o;
    });
    if (outcome === 'sent') sent++; else if (outcome === 'rejected') rejected++; else if (outcome === 'uncertain') uncertain++; else skipped++;
  }
  return { sent, rejected, uncertain, skipped };
}
