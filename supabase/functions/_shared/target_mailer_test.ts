import { assertEquals } from 'jsr:@std/assert@1';
import { BREVO_URL, type Rpc } from './email_worker.ts';
import { classify, sendTargetEmails, targetBrevoBody, targetEmailHtml, type TargetMail } from './target_mailer.ts';

const SUBJECT = '❤️ מישהו מתעניין בך!';
const BODY = 'יש לנו חדשות משמחות בשבילך!\n\nמישהו ראה את הפרופיל שלך ושלח לך חץ 🎯.\n\nאולי זאת תחילתה של אהבה חדשה?\n\n'
  + 'היכנסו לאפליקציה וגלו מי מתעניין בכם, בהתאם למסלול המנוי שלכם.\n\nhttps://haimderechmisparim.com\n\n'
  + 'חיים דרך מספרים – אהבה היא לא מקרית!\n\nלא רוצים לקבל מיילים על חצים? אפשר לבטל בכל עת באפליקציה: הגדרות ← התראות מייל.\nhttps://haimderechmisparim.com/#notify';
const mail = (id: number): TargetMail => ({ id, kind: 'target_received', to_email: `u${id}@example.invalid`, subject: SUBJECT, body_text: BODY });

// ids: מה ש-claim מחזיר; begun: אילו ids יקבלו כתובת ב-begin (השאר — ביטלו התראות / נתפסו ע"י אחר)
function setup(envs: Record<string, string>, ids: number[], statuses: number[] | 'throw', opts: { begun?: number[]; doneErrors?: number } = {}) {
  const calls: { fn: string; a: Record<string, unknown> }[] = []; const sent: { url: string; init: RequestInit }[] = [];
  let de = opts.doneErrors ?? 0; const begun = new Set(opts.begun ?? ids);
  const rpc: Rpc = async (fn, a) => {
    calls.push({ fn, a });
    if (fn === 'hdm_target_email_claim') return { data: ids.map((id) => ({ id, kind: 'target_received' })), error: null };
    if (fn === 'hdm_target_email_begin') return { data: begun.has(a.p_id as number) ? [mail(a.p_id as number)] : [], error: null };
    if (fn === 'hdm_target_email_done' && de > 0) { de--; return { data: null, error: { message: 'db down' } }; }
    return { data: null, error: null };
  };
  let i = 0;
  const f = (async (url: string, init: RequestInit) => { sent.push({ url, init }); if (statuses === 'throw') throw new Error('down'); return new Response('{}', { status: statuses[i++] }); }) as unknown as typeof fetch;
  return { env: (k: string) => envs[k] ?? '', rpc, f, calls, sent, done: () => calls.filter((c) => c.fn === 'hdm_target_email_done') };
}
const OK = { TARGET_EMAILS_LIVE: '1', BREVO_API_KEY: 'xkeysib-test', MAIL_FROM: 'noreply@example.invalid', MAIL_REPLY_TO: 'reply@example.invalid' };

Deno.test('כבוי כברירת מחדל (בלי TARGET_EMAILS_LIVE) — לא נוגעים בתור ולא שולחים', async () => {
  const s = setup({ ...OK, TARGET_EMAILS_LIVE: '' }, [1], [201]);
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { skipped: 'off' });
  assertEquals(s.calls.length, 0); assertEquals(s.sent.length, 0);
});
Deno.test('בלי מפתח Brevo או שולח — לא נוגעים בתור', async () => {
  const a = setup({ ...OK, BREVO_API_KEY: '' }, [1], [201]);
  assertEquals(await sendTargetEmails(a.env, a.rpc, a.f), { skipped: 'not_configured' }); assertEquals(a.calls.length, 0);
  const b = setup({ ...OK, MAIL_FROM: '' }, [1], [201]);
  assertEquals(await sendTargetEmails(b.env, b.rpc, b.f), { skipped: 'not_configured' }); assertEquals(b.calls.length, 0);
});
Deno.test('DRY_RUN — לא שולחים ולא מסמנים', async () => {
  const s = setup({ ...OK, DRY_RUN: '1' }, [1], [201]);
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { skipped: 'dry_run' }); assertEquals(s.sent.length, 0); assertEquals(s.calls.length, 0);
});
Deno.test('שליחה מוצלחת — claim → begin → Brevo → done(sent); נוסח הבעלים', async () => {
  const s = setup(OK, [7], [201]);
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { sent: 1, rejected: 0, uncertain: 0, skipped: 0 });
  assertEquals(s.calls.map((c) => c.fn), ['hdm_target_email_claim', 'hdm_target_email_begin', 'hdm_target_email_done']);
  assertEquals(s.sent[0].url, BREVO_URL);
  const b = JSON.parse(String(s.sent[0].init.body));
  assertEquals(b.to, [{ email: 'u7@example.invalid' }]); assertEquals(b.sender, { name: 'חיים דרך מספרים', email: 'noreply@example.invalid' });
  assertEquals(b.subject, SUBJECT); assertEquals(b.textContent, BODY); assertEquals(b.tags, ['hdm-target_received']);
  assertEquals(s.done()[0].a, { p_id: 7, p_result: 'sent', p_error: null });
});
Deno.test('ביטול התראות ברגע האחרון (begin לא מחזיר כתובת) — לא נשלח בכלל', async () => {
  const s = setup(OK, [1, 2], [201], { begun: [2] });
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { sent: 1, rejected: 0, uncertain: 0, skipped: 1 });
  assertEquals(s.sent.length, 1); assertEquals(JSON.parse(String(s.sent[0].init.body)).to, [{ email: 'u2@example.invalid' }]);
  assertEquals(s.done().map((c) => c.a.p_id), [2]);
});
Deno.test('Brevo דחה במפורש (4xx) — rejected (מותר ניסיון חוזר), ממשיכים למייל הבא', async () => {
  const s = setup(OK, [1, 2], [401, 201]);
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { sent: 1, rejected: 1, uncertain: 0, skipped: 0 });
  assertEquals(s.done()[0].a, { p_id: 1, p_result: 'rejected', p_error: 'brevo 401' });
});
Deno.test('תשובה לא ברורה (5xx) — uncertain: לא נשלח שוב', async () => {
  const s = setup(OK, [1], [502]);
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { sent: 0, rejected: 0, uncertain: 1, skipped: 0 });
  assertEquals(s.done()[0].a.p_result, 'uncertain');
});
Deno.test('ניתוק / זמן קצוב — uncertain: לא נשלח שוב', async () => {
  const s = setup(OK, [1, 2], 'throw');
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { sent: 0, rejected: 0, uncertain: 2, skipped: 0 });
  assertEquals(String(s.done()[0].a.p_error).startsWith('network:'), true);
});
Deno.test('סימון נכשל אחרי שליחה מוצלחת — לא שולחים שוב (רק מנסים לסמן, עד 3)', async () => {
  const s = setup(OK, [3], [201], { doneErrors: 3 });
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { sent: 1, rejected: 0, uncertain: 0, skipped: 0 });
  assertEquals(s.sent.length, 1); assertEquals(s.done().length, 3);
});
Deno.test('סיווג תשובות', () => {
  assertEquals([classify(200), classify(201), classify(400), classify(401), classify(429), classify(500), classify(503), classify(null)],
    ['sent', 'sent', 'rejected', 'rejected', 'rejected', 'uncertain', 'uncertain', 'uncertain']);
});
Deno.test('תור ריק — שום שליחה', async () => {
  const s = setup(OK, [], [201]);
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { sent: 0, rejected: 0, uncertain: 0, skipped: 0 }); assertEquals(s.sent.length, 0);
});
Deno.test('HTML: מימין לשמאל, כפתור כניסה, קישור ביטול, בלי סקריפטים', () => {
  const h = targetEmailHtml(SUBJECT, BODY);
  assertEquals(h.includes('dir="rtl"'), true);
  assertEquals(h.includes('href="https://haimderechmisparim.com"'), true);
  assertEquals(h.includes('href="https://haimderechmisparim.com/#notify"'), true);
  assertEquals(h.includes('<script'), false);
  const b = targetBrevoBody(mail(1), 'a@b.c', '');
  assertEquals(b.replyTo, undefined);
  assertEquals((b.headers as Record<string, string>)['List-Unsubscribe'], '<https://haimderechmisparim.com/#notify>');
});
