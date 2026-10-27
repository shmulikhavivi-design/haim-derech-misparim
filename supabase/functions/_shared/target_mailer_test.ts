import { assertEquals } from 'jsr:@std/assert@1';
import { BREVO_URL, type Rpc } from './email_worker.ts';
import { sendTargetEmails, targetBrevoBody, targetEmailHtml, type TargetMail } from './target_mailer.ts';

const SUBJECT = '❤️ מישהו מתעניין בך!';
const BODY = 'יש לנו חדשות משמחות בשבילך!\n\nמישהו ראה את הפרופיל שלך ושלח לך חץ 🎯.\n\nאולי זאת תחילתה של אהבה חדשה?\n\n'
  + 'היכנסו לאפליקציה וגלו מי מתעניין בכם, בהתאם למסלול המנוי שלכם.\n\nhttps://haimderechmisparim.com\n\n'
  + 'חיים דרך מספרים – אהבה היא לא מקרית!\n\nלא רוצים לקבל מיילים על חצים? אפשר לבטל בכל עת באפליקציה: הגדרות ← התראות מייל.\nhttps://haimderechmisparim.com/#notify';
const mail = (id: number): TargetMail => ({ id, kind: 'target_received', to_email: `u${id}@example.invalid`, subject: SUBJECT, body_text: BODY });
function setup(envs: Record<string, string>, queue: TargetMail[], statuses: number[] | 'throw', doneErrors = 0) {
  const calls: { fn: string; a: Record<string, unknown> }[] = []; const sent: { url: string; init: RequestInit }[] = [];
  let de = doneErrors;
  const rpc: Rpc = async (fn, a) => {
    calls.push({ fn, a });
    if (fn === 'hdm_target_email_done' && de > 0) { de--; return { data: null, error: { message: 'db down' } }; }
    return { data: fn === 'hdm_target_email_claim' ? queue : null, error: null };
  };
  let i = 0;
  const f = (async (url: string, init: RequestInit) => { sent.push({ url, init }); if (statuses === 'throw') throw new Error('down'); return new Response('{}', { status: statuses[i++] }); }) as unknown as typeof fetch;
  return { env: (k: string) => envs[k] ?? '', rpc, f, calls, sent };
}
const OK = { TARGET_EMAILS_LIVE: '1', BREVO_API_KEY: 'xkeysib-test', MAIL_FROM: 'noreply@example.invalid', MAIL_REPLY_TO: 'reply@example.invalid' };

Deno.test('כבוי כברירת מחדל (בלי TARGET_EMAILS_LIVE) — לא נוגעים בתור ולא שולחים', async () => {
  const s = setup({ ...OK, TARGET_EMAILS_LIVE: '' }, [mail(1)], [201]);
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { skipped: 'off' });
  assertEquals(s.calls.length, 0); assertEquals(s.sent.length, 0);
});
Deno.test('בלי מפתח Brevo או שולח — לא נוגעים בתור', async () => {
  const a = setup({ ...OK, BREVO_API_KEY: '' }, [mail(1)], [201]);
  assertEquals(await sendTargetEmails(a.env, a.rpc, a.f), { skipped: 'not_configured' }); assertEquals(a.calls.length, 0);
  const b = setup({ ...OK, MAIL_FROM: '' }, [mail(1)], [201]);
  assertEquals(await sendTargetEmails(b.env, b.rpc, b.f), { skipped: 'not_configured' }); assertEquals(b.calls.length, 0);
});
Deno.test('DRY_RUN — לא שולחים ולא מסמנים', async () => {
  const s = setup({ ...OK, DRY_RUN: '1' }, [mail(1)], [201]);
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { skipped: 'dry_run' }); assertEquals(s.sent.length, 0); assertEquals(s.calls.length, 0);
});
Deno.test('שליחה מוצלחת — אותה תשתית Brevo, נושא ונוסח הבעלים, מסומן נשלח', async () => {
  const s = setup(OK, [mail(7)], [201]);
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { sent: 1, failed: 0 });
  assertEquals(s.calls[0], { fn: 'hdm_target_email_claim', a: { p_limit: 20 } });
  assertEquals(s.sent[0].url, BREVO_URL);
  assertEquals((s.sent[0].init.headers as Record<string, string>)['api-key'], 'xkeysib-test');
  const b = JSON.parse(String(s.sent[0].init.body));
  assertEquals(b.to, [{ email: 'u7@example.invalid' }]); assertEquals(b.sender, { name: 'חיים דרך מספרים', email: 'noreply@example.invalid' });
  assertEquals(b.subject, SUBJECT); assertEquals(b.textContent, BODY); assertEquals(b.replyTo, { email: 'reply@example.invalid' });
  assertEquals(b.tags, ['hdm-target_received']);
  assertEquals(s.calls[1], { fn: 'hdm_target_email_done', a: { p_id: 7, p_ok: true, p_error: null } });
});
Deno.test('Brevo דוחה — מסומן נכשל (חוזר לתור), ממשיכים למייל הבא', async () => {
  const s = setup(OK, [mail(1), mail(2)], [500, 201]);
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { sent: 1, failed: 1 });
  assertEquals(s.calls[1].a, { p_id: 1, p_ok: false, p_error: 'brevo 500' });
  assertEquals(s.calls[2].a, { p_id: 2, p_ok: true, p_error: null });
});
Deno.test('אין רשת — לא קורס, כל המיילים מסומנים נכשלים', async () => {
  const s = setup(OK, [mail(1), mail(2)], 'throw');
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { sent: 0, failed: 2 });
  assertEquals(String(s.calls[1].a.p_error).startsWith('network:'), true);
});
Deno.test('סימון "נשלח" נכשל פעמיים — מנסים שוב עד 3 פעמים (לא שולחים שוב)', async () => {
  const s = setup(OK, [mail(3)], [201], 2);
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { sent: 1, failed: 0 });
  assertEquals(s.sent.length, 1);
  assertEquals(s.calls.filter((c) => c.fn === 'hdm_target_email_done').length, 3);
});
Deno.test('תור ריק — שום שליחה', async () => {
  const s = setup(OK, [], [201]);
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { sent: 0, failed: 0 }); assertEquals(s.sent.length, 0);
});
Deno.test('HTML: מימין לשמאל, כפתור כניסה, קישור ביטול, בלי פרטי שולח', () => {
  const h = targetEmailHtml(SUBJECT, BODY);
  assertEquals(h.includes('dir="rtl"'), true);
  assertEquals(h.includes('href="https://haimderechmisparim.com"'), true);
  assertEquals(h.includes('href="https://haimderechmisparim.com/#notify"'), true);
  assertEquals(h.includes('<script'), false);
  const b = targetBrevoBody(mail(1), 'a@b.c', '');
  assertEquals(b.replyTo, undefined);
  assertEquals((b.headers as Record<string, string>)['List-Unsubscribe'], '<https://haimderechmisparim.com/#notify>');
});
