// =====================================================================
// חיים דרך מספרים — שליחת מיילי הביטול מהתור (hdm_email_outbox) דרך ה-API של Brevo.
// לב הלוגיקה, בלי Deno.serve — כדי שאפשר לבדוק אותו עם fetch ו-rpc מדומים.
// - בלי BREVO_API_KEY או MAIL_FROM: לא נוגעים בתור בכלל (שום מייל לא מסומן כנכשל) ומחזירים "לא מוגדר".
// - DRY_RUN=1: לא שולחים ולא מסמנים.
// - מייל שנכשל נשאר בתור (המסד מנסה עד 5 פעמים); אחרי 30 דקות בלי שליחה — התראה לבעלים (hdm_billing_scan_alerts).
// =====================================================================
export const BREVO_URL = 'https://api.brevo.com/v3/smtp/email';
export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>;
export type Mail = { id: number; kind: string; to_email: string; subject: string; body_text: string };

export function brevoBody(m: Mail, from: string, replyTo: string) {
  const b: Record<string, unknown> = {
    sender: { name: 'חיים דרך מספרים', email: from },
    to: [{ email: m.to_email }],
    subject: m.subject,
    textContent: m.body_text,
    tags: ['hdm-' + m.kind],
  };
  if (replyTo) b.replyTo = { email: replyTo };
  return b;
}

export async function sendQueuedEmails(env: (k: string) => string, rpc: Rpc, fetchFn: typeof fetch) {
  const key = env('BREVO_API_KEY'), from = env('MAIL_FROM');
  if (!key || !from) return { skipped: 'not_configured' };
  if (env('DRY_RUN') === '1') return { skipped: 'dry_run' };
  const { data, error } = await rpc('hdm_email_outbox_pending', { p_limit: 20 });
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
    const { error: e2 } = await rpc('hdm_email_outbox_done', { p_id: m.id, p_ok: ok, p_error: ok ? null : err });
    if (e2) console.error('email done failed', m.id, e2.message);
    ok ? sent++ : failed++;
  }
  return { sent, failed };
}
