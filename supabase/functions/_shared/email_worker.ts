// =====================================================================
// חיים דרך מספרים — שליחת מיילי הביטול מהתור (hdm_email_outbox) דרך ה-API של Brevo.
// לב הלוגיקה, בלי Deno.serve — כדי שאפשר לבדוק אותו עם fetch ו-rpc מדומים.
// - בלי BREVO_API_KEY או MAIL_FROM: לא נוגעים בתור בכלל ומחזירים "לא מוגדר".
// - DRY_RUN=1: לא שולחים ולא מסמנים.
// - מניעת שליחה כפולה: כל מייל נתפס בשרת (hdm_email_outbox_claim) לפני השליחה; הרצה מקבילה לא מקבלת אותו,
//   ומייל שסומן כנשלח לא נשלח שוב. סימון "נשלח" מנוסה עד 3 פעמים.
// - מייל שנכשל חוזר לתור אחרי 10 דקות (עד 5 ניסיונות); אחרי 30 דקות בלי שליחה — התראה לבעלים.
// - נשלח גם בגרסת HTML מעוצבת (מימין לשמאל, רווחים בין פסקאות) וגם כטקסט רגיל.
// =====================================================================
export const BREVO_URL = 'https://api.brevo.com/v3/smtp/email';
export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>;
export type Mail = { id: number; kind: string; to_email: string; subject: string; body_text: string };

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string);

export function emailHtml(subject: string, text: string): string {
  const paras = String(text ?? '').replace(/\r/g, '').trim().split(/\n{2,}/).map((p) => p.trim()).filter(Boolean);
  const body = paras.map((p) => {
    let h = esc(p).replace(/\n/g, '<br>');
    h = h.replace(/([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})/g, '<a href="mailto:$1" style="color:#7a5a1e" dir="ltr">$1</a>');
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
    + 'הודעה זו נשלחה אליך בעקבות פעולה בחשבון שלך באפליקציה „חיים דרך מספרים”.</td></tr>'
    + '</table></td></tr></table></body></html>';
}

export function brevoBody(m: Mail, from: string, replyTo: string) {
  const b: Record<string, unknown> = {
    sender: { name: 'חיים דרך מספרים', email: from },
    to: [{ email: m.to_email }],
    subject: m.subject,
    textContent: m.body_text,
    htmlContent: emailHtml(m.subject, m.body_text),
    tags: ['hdm-' + m.kind],
  };
  if (replyTo) b.replyTo = { email: replyTo };
  return b;
}

export async function sendQueuedEmails(env: (k: string) => string, rpc: Rpc, fetchFn: typeof fetch) {
  const key = env('BREVO_API_KEY'), from = env('MAIL_FROM');
  if (!key || !from) return { skipped: 'not_configured' };
  if (env('DRY_RUN') === '1') return { skipped: 'dry_run' };
  const { data, error } = await rpc('hdm_email_outbox_claim', { p_limit: 20 });
  if (error) throw new Error('outbox: ' + error.message);
  let sent = 0, failed = 0;
  for (const m of (data ?? []) as Mail[]) {
    let ok = false, err = '';
    try {
      const r = await fetchFn(BREVO_URL, {
        method: 'POST',
        headers: { 'api-key': key, 'content-type': 'application/json', accept: 'application/json' },
        body: JSON.stringify(brevoBody(m, from, env('MAIL_REPLY_TO'))),
        signal: AbortSignal.timeout(20000),
      });
      ok = r.ok;
      if (!ok) err = `brevo ${r.status}`;
      await r.body?.cancel();
    } catch (e) { err = 'network: ' + String(e).slice(0, 150); }
    let marked = false;
    for (let i = 0; i < 3 && !marked; i++) {
      const { error: e2 } = await rpc('hdm_email_outbox_done', { p_id: m.id, p_ok: ok, p_error: ok ? null : err });
      marked = !e2;
      if (e2) console.error('email done failed', m.id, i, e2.message);
    }
    if (ok) sent++; else failed++;
  }
  return { sent, failed };
}
