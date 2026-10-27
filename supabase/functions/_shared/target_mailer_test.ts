import { assertEquals } from 'jsr:@std/assert@1';
import { BREVO_URL } from './email_worker.ts';
import { brevoUrl, classify, sendTargetEmails, targetBrevoBody, targetEmailHtml, type QueueDb, type TargetMail } from './target_mailer.ts';

const SUBJECT = '❤️ מישהו מתעניין בך!';
const BODY = 'יש לנו חדשות משמחות בשבילך!\n\nמישהו ראה את הפרופיל שלך ושלח לך חץ 🎯.\n\nאולי זאת תחילתה של אהבה חדשה?\n\n'
  + 'היכנסו לאפליקציה וגלו מי מתעניין בכם, בהתאם למסלול המנוי שלכם.\n\nhttps://haimderechmisparim.com\n\n'
  + 'חיים דרך מספרים – אהבה היא לא מקרית!\n\nלא רוצים לקבל מיילים על חצים? אפשר לבטל בכל עת באפליקציה: הגדרות ← התראות מייל.\nhttps://haimderechmisparim.com/#notify';
const mail = (id: number): TargetMail => ({ id, kind: 'target_received', to_email: `u${id}@example.invalid`, subject: SUBJECT, body_text: BODY });

// ids: מה ש-claim מחזיר; begun: אילו ids יקבלו כתובת ב-begin (השאר — ביטלו התראות / חסימה / נתפסו ע"י אחר)
// הדמיית המסד רושמת כל קריאה, ואם הנעילה הייתה מוחזקת בזמנה.
function setup(envs: Record<string, string>, ids: number[], statuses: number[] | 'throw', opts: { begun?: number[]; doneErrors?: number } = {}) {
  const calls: { fn: string; a: Record<string, unknown>; locked: boolean }[] = []; const sent: { url: string; init: RequestInit; locked: boolean }[] = [];
  let de = opts.doneErrors ?? 0; const begun = new Set(opts.begun ?? ids); let locked = false;
  const db: QueueDb = {
    async claim(limit) { calls.push({ fn: 'claim', a: { limit }, locked }); return ids; },
    async withUserLock(id, fn) {
      calls.push({ fn: 'lock', a: { id }, locked }); locked = true;
      try { return await fn(); } finally { locked = false; calls.push({ fn: 'unlock', a: { id }, locked }); }
    },
    async begin(id) { calls.push({ fn: 'begin', a: { id }, locked }); return begun.has(id) ? mail(id) : null; },
    async done(id, outcome, error) {
      calls.push({ fn: 'done', a: { id, outcome, error }, locked });
      if (de > 0) { de--; throw new Error('db down'); }
    },
  };
  let i = 0;
  const f = (async (url: string, init: RequestInit) => { sent.push({ url, init, locked }); if (statuses === 'throw') throw new Error('down'); return new Response('{}', { status: statuses[i++] }); }) as unknown as typeof fetch;
  return { env: (k: string) => envs[k] ?? '', rpc: db, f, calls, sent, done: () => calls.filter((c) => c.fn === 'done') };
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
  assertEquals(s.calls.map((c) => c.fn), ['claim', 'lock', 'begin', 'done', 'unlock']);
  assertEquals(s.sent[0].url, BREVO_URL);
  const b = JSON.parse(String(s.sent[0].init.body));
  assertEquals(b.to, [{ email: 'u7@example.invalid' }]); assertEquals(b.sender, { name: 'חיים דרך מספרים', email: 'noreply@example.invalid' });
  assertEquals(b.subject, SUBJECT); assertEquals(b.textContent, BODY); assertEquals(b.tags, ['hdm-target_received']);
  assertEquals(s.done()[0].a, { id: 7, outcome: 'sent', error: null });
});
Deno.test('ביטול התראות ברגע האחרון (begin לא מחזיר כתובת) — לא נשלח בכלל', async () => {
  const s = setup(OK, [1, 2], [201], { begun: [2] });
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { sent: 1, rejected: 0, uncertain: 0, skipped: 1 });
  assertEquals(s.sent.length, 1); assertEquals(JSON.parse(String(s.sent[0].init.body)).to, [{ email: 'u2@example.invalid' }]);
  assertEquals(s.done().map((c) => c.a.id), [2]);
});
Deno.test('Brevo דחה במפורש (4xx) — rejected (מותר ניסיון חוזר), ממשיכים למייל הבא', async () => {
  const s = setup(OK, [1, 2], [401, 201]);
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { sent: 1, rejected: 1, uncertain: 0, skipped: 0 });
  assertEquals(s.done()[0].a, { id: 1, outcome: 'rejected', error: 'brevo 401' });
});
Deno.test('תשובה לא ברורה (5xx) — uncertain: לא נשלח שוב', async () => {
  const s = setup(OK, [1], [502]);
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { sent: 0, rejected: 0, uncertain: 1, skipped: 0 });
  assertEquals(s.done()[0].a.outcome, 'uncertain');
});
Deno.test('ניתוק / זמן קצוב — uncertain: לא נשלח שוב', async () => {
  const s = setup(OK, [1, 2], 'throw');
  assertEquals(await sendTargetEmails(s.env, s.rpc, s.f), { sent: 0, rejected: 0, uncertain: 2, skipped: 0 });
  assertEquals(String(s.done()[0].a.error).startsWith('network:'), true);
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

Deno.test('ביטול התראות מול מסירה: begin, הקריאה ל-Brevo והסימון — כולם בתוך נעילת המשתמש', async () => {
  const s = setup(OK, [1, 2], [201, 401]);
  await sendTargetEmails(s.env, s.rpc, s.f);
  assertEquals(s.calls.filter((c) => ['begin', 'done'].includes(c.fn)).every((c) => c.locked), true);
  assertEquals(s.sent.every((x) => x.locked), true);
  assertEquals(s.calls.filter((c) => c.fn === 'lock').length, 2); assertEquals(s.calls.filter((c) => c.fn === 'unlock').length, 2);
});
Deno.test('הנעילה משתחררת גם כשהסימון נכשל וגם כשאין רשת', async () => {
  const a = setup(OK, [1], 'throw', { doneErrors: 3 });
  await sendTargetEmails(a.env, a.rpc, a.f);
  assertEquals(a.calls[a.calls.length - 1].fn, 'unlock');
});
Deno.test('כתובת בדיקה של Brevo — רק ב-Staging; ב-Production תמיד Brevo האמיתי', () => {
  assertEquals(brevoUrl((k) => ({ HDM_ENV: 'staging', BREVO_URL_TEST: 'https://example.invalid/delay' } as Record<string, string>)[k] ?? ''), 'https://example.invalid/delay');
  assertEquals(brevoUrl((k) => ({ BREVO_URL_TEST: 'https://example.invalid/delay' } as Record<string, string>)[k] ?? ''), BREVO_URL);
  assertEquals(brevoUrl((k) => ({ HDM_ENV: 'production', BREVO_URL_TEST: 'https://example.invalid/delay' } as Record<string, string>)[k] ?? ''), BREVO_URL);
});
