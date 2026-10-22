import { assertEquals } from 'jsr:@std/assert@1';
import { BREVO_URL, brevoBody, sendQueuedEmails, type Mail, type Rpc } from './email_worker.ts';

const mail = (id: number): Mail => ({ id, kind: 'cancel_confirmed', to_email: `u${id}@example.invalid`, subject: 'אישור ביטול מנוי — חיים דרך מספרים', body_text: 'שלום' });
function setup(envs: Record<string, string>, queue: Mail[], statuses: number[] | 'throw') {
  const calls: { fn: string; a: Record<string, unknown> }[] = []; const sent: { url: string; init: RequestInit }[] = [];
  const rpc: Rpc = async (fn, a) => { calls.push({ fn, a }); return { data: fn === 'hdm_email_outbox_pending' ? queue : null, error: null }; };
  let i = 0;
  const f = (async (url: string, init: RequestInit) => { sent.push({ url, init }); if (statuses === 'throw') throw new Error('down'); return new Response('{}', { status: statuses[i++] }); }) as unknown as typeof fetch;
  return { env: (k: string) => envs[k] ?? '', rpc, f, calls, sent };
}
const OK = { BREVO_API_KEY: 'xkeysib-test', MAIL_FROM: 'sender@example.invalid' };

Deno.test('בלי מפתח Brevo — לא נוגעים בתור', async () => {
  const s = setup({ MAIL_FROM: 'a@b.c' }, [mail(1)], [201]);
  assertEquals(await sendQueuedEmails(s.env, s.rpc, s.f), { skipped: 'not_configured' });
  assertEquals(s.calls.length, 0); assertEquals(s.sent.length, 0);
});
Deno.test('בלי שולח — לא נוגעים בתור', async () => {
  const s = setup({ BREVO_API_KEY: 'k' }, [mail(1)], [201]);
  assertEquals(await sendQueuedEmails(s.env, s.rpc, s.f), { skipped: 'not_configured' }); assertEquals(s.calls.length, 0);
});
Deno.test('DRY_RUN — לא שולחים ולא מסמנים', async () => {
  const s = setup({ ...OK, DRY_RUN: '1' }, [mail(1)], [201]);
  assertEquals(await sendQueuedEmails(s.env, s.rpc, s.f), { skipped: 'dry_run' }); assertEquals(s.sent.length, 0);
});
Deno.test('שליחה מוצלחת — נשלח ל-Brevo ומסומן נשלח', async () => {
  const s = setup(OK, [mail(7)], [201]);
  assertEquals(await sendQueuedEmails(s.env, s.rpc, s.f), { sent: 1, failed: 0 });
  assertEquals(s.sent[0].url, BREVO_URL);
  const h = s.sent[0].init.headers as Record<string, string>; assertEquals(h['api-key'], 'xkeysib-test');
  const b = JSON.parse(String(s.sent[0].init.body));
  assertEquals(b.to, [{ email: 'u7@example.invalid' }]); assertEquals(b.sender.email, 'sender@example.invalid'); assertEquals(b.subject, 'אישור ביטול מנוי — חיים דרך מספרים');
  assertEquals(s.calls[1], { fn: 'hdm_email_outbox_done', a: { p_id: 7, p_ok: true, p_error: null } });
});
Deno.test('Brevo מחזיר שגיאה — מסומן כנכשל (נשאר בתור), ממשיכים למייל הבא', async () => {
  const s = setup(OK, [mail(1), mail(2)], [401, 201]);
  assertEquals(await sendQueuedEmails(s.env, s.rpc, s.f), { sent: 1, failed: 1 });
  assertEquals(s.calls[1].a, { p_id: 1, p_ok: false, p_error: 'brevo 401' });
  assertEquals(s.calls[2].a, { p_id: 2, p_ok: true, p_error: null });
});
Deno.test('תקלת רשת — מסומן כנכשל עם הסיבה', async () => {
  const s = setup(OK, [mail(3)], 'throw');
  assertEquals(await sendQueuedEmails(s.env, s.rpc, s.f), { sent: 0, failed: 1 });
  assertEquals(String(s.calls[1].a.p_error).startsWith('network:'), true);
});
Deno.test('כתובת למענה — רק אם הוגדרה', () => {
  assertEquals('replyTo' in brevoBody(mail(1), 'f@x.y', ''), false);
  assertEquals(brevoBody(mail(1), 'f@x.y', 'r@x.y').replyTo, { email: 'r@x.y' });
});
