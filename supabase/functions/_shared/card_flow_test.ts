// בדיקות אפשרות 2 (כרטיס פעם אחת → חיוב ראשון מהשרת) מול "Morning" מדומה בזיכרון. בלי רשת ובלי חיוב.
// הרצה: deno test --no-check supabase/functions/_shared/card_flow_test.ts
import { strict as A } from 'node:assert';
import { CheckoutInfo, MorningClient, MorningError, PROD_API, SANDBOX_API, tokenChargeBody } from './morning.ts';
import { FlowDb, runCardCheckout } from './card_flow.ts';

const envOf = (o: Record<string, string>) => (k: string) => o[k] ?? '';
const LIVE = { MORNING_CLIENT_ID: 'id-1', MORNING_CLIENT_SECRET: 'sec-1', MORNING_API_BASE: SANDBOX_API, MORNING_LIVE: '1',
               MORNING_PLUGIN_ID: 'plug-1', HDM_APP_URL: 'https://app.example' };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'content-type': 'application/json' } });
const CK = (o: Partial<CheckoutInfo> = {}): CheckoutInfo => ({
  id: '11111111-2222-3333-4444-555555555555', userId: 'u1', profileId: 'p1', kind: 'initial', plan: 'basic', amountAgorot: 2990,
  status: 'pending', createdAt: new Date().toISOString(), expiresAt: new Date(Date.now() + 1800e3).toISOString(), expired: false,
  email: 'noa@example.com', token: null, ...o });

// ---- Morning מדומה ----
function fakeMorning(opts: { decline?: boolean; netFail?: boolean; docStatus?: number; docAmount?: number; existingClient?: boolean } = {}) {
  const st = { clients: [] as Record<string, unknown>[], tokens: [] as Record<string, unknown>[], charges: 0, chargeAttempts: 0,
               links: [] as Record<string, unknown>[], bodies: [] as string[], docs: new Map<string, Record<string, unknown>>() };
  if (opts.existingClient) st.clients.push({ id: 'cl-existing', emails: ['noa@example.com'], active: true });
  const f = async (url: string, init?: RequestInit) => {
    const body = init?.body ? String(init.body) : ''; st.bodies.push(body);
    const p = url.replace(/^https:\/\/[^/]+(\/api\/v1)?/, '');
    if (url.includes('/oauth/token')) return json({ accessToken: 'AT', expiresAt: 9e9 });
    if (p === '/clients/search') { const em = JSON.parse(body).email; return json({ items: st.clients.filter((c) => (c.emails as string[]).includes(em)) }); }
    if (p === '/clients') { const c = { id: `cl-${st.clients.length + 1}`, ...JSON.parse(body) }; st.clients.push(c); return json(c, 201); }
    if (p === '/payments/tokens/url') { st.links.push(JSON.parse(body)); return json({ success: true, errorCode: 0, url: 'https://secure.meshulam.co.il/credit-checkout-form?l=x' }); }
    if (p === '/payments/tokens/search') { const k = JSON.parse(body).externalKey; return json({ total: 0, items: st.tokens.filter((t) => t.externalKey === k) }); }
    const ch = /^\/payments\/tokens\/([^/]+)\/charge$/.exec(p);
    if (ch) {
      st.chargeAttempts++;
      if (opts.netFail) throw new TypeError('network down');
      if (opts.decline) return json({ errorCode: 2302, errorMessage: 'כרטיס נדחה' }, 400);
      st.charges++;
      const b = JSON.parse(body);
      const doc = { id: `doc-${st.charges}`, number: 1000 + st.charges, type: b.type, currency: 'ILS', status: opts.docStatus ?? 1,
                    amount: opts.docAmount ?? b.amount, client: { id: st.tokens.find((t) => t.id === ch[1])?.externalKey } };
      st.docs.set(doc.id, doc); return json(doc, 201);
    }
    return json({ errorCode: 404, errorMessage: 'not found ' + p }, 404);
  };
  // הלקוח "שומר כרטיס" בדף של Grow: נוצר טוקן אצל Morning (רק 4 ספרות גלויות)
  const saveCard = (clientId: string) => st.tokens.push({ id: `tok-${st.tokens.length + 1}`, externalKey: clientId, status: 1,
                                                          creationDate: Math.floor(Date.now() / 1000), number: '4580', cardType: 2 });
  return { st, f, saveCard };
}

// ---- מסד מדומה (אותם כללים כמו במסד: תפיסה פעם אחת, אירוע נקלט פעם אחת) ----
function fakeDb() {
  const st = { customers: new Map<string, string>(), tokens: new Map<string, { id: string; last4: string | null }>(), claims: new Set<string>(),
               events: [] as Record<string, unknown>[], tx: new Set<string>() };
  const db: FlowDb = {
    async customerId(p) { return st.customers.get(p) ?? null; },
    async saveCustomer(p, id) { st.customers.set(p, id); },
    async profileName() { return 'נועה'; },
    async saveToken(p, id, last4) { st.tokens.set(p, { id, last4 }); },
    async claim(ck) { if (st.claims.has(ck)) return false; st.claims.add(ck); return true; },
    async applyEvent(ev) { const t = String(ev.transactionId); if (st.tx.has(t)) return 'duplicate'; st.tx.add(t); st.events.push(ev);
                           return ev.outcome === 'approved' ? (ev.checkoutId ? 'started' : 'review') : 'failed'; },
  };
  return { st, db };
}

Deno.test('שלב 1: בלי כרטיס שמור → קישור מאובטח לשמירת כרטיס של Grow, בלי חיוב', async () => {
  const M = fakeMorning(), D = fakeDb();
  const r = await runCardCheckout('start', CK(), new MorningClient(envOf(LIVE), M.f), envOf(LIVE), D.db);
  A.equal(r.body.mode, 'redirect'); A.match(String(r.body.url), /^https:\/\/secure\.meshulam\.co\.il\//);
  A.equal(M.st.chargeAttempts, 0); A.equal(D.st.events.length, 0);
  A.equal(M.st.clients.length, 1); A.deepEqual(M.st.clients[0].emails, ['noa@example.com']);
  const link = M.st.links[0];
  A.equal(link.externalKey, 'cl-1'); A.deepEqual(link.client, { id: 'cl-1' }); A.equal(link.channel, 1); A.equal(link.pluginId, 'plug-1');
  A.equal(link.successUrl, `https://app.example/?billing=card&ck=${CK().id}`);
  A.equal(D.st.customers.get('p1'), 'cl-1');
});

Deno.test('לקוח קיים ב-Morning (לפי אימייל) — לא נוצר לקוח כפול', async () => {
  const M = fakeMorning({ existingClient: true }), D = fakeDb();
  await runCardCheckout('start', CK(), new MorningClient(envOf(LIVE), M.f), envOf(LIVE), D.db);
  A.equal(M.st.clients.length, 1); A.equal(M.st.links[0].externalKey, 'cl-existing');
});

Deno.test('חזרה לפני שהכרטיס נשמר → ממתין, בלי חיוב ובלי הפעלה', async () => {
  const M = fakeMorning(), D = fakeDb(), m = new MorningClient(envOf(LIVE), M.f);
  await runCardCheckout('start', CK(), m, envOf(LIVE), D.db);
  const r = await runCardCheckout('complete', CK(), m, envOf(LIVE), D.db);
  A.equal(r.body.mode, 'waiting'); A.equal(M.st.chargeAttempts, 0); A.equal(D.st.events.length, 0); A.equal(D.st.claims.size, 0);
});

Deno.test('כרטיס נשמר → חיוב ראשון אחד של ₪29.90, מסמך מאומת, הפעלה רק אחרי האישור', async () => {
  const M = fakeMorning(), D = fakeDb(), m = new MorningClient(envOf(LIVE), M.f);
  await runCardCheckout('start', CK(), m, envOf(LIVE), D.db);
  M.saveCard('cl-1');
  const r = await runCardCheckout('complete', CK(), m, envOf(LIVE), D.db);
  A.equal(r.body.mode, 'charged'); A.equal(r.body.result, 'started');
  A.equal(M.st.charges, 1);
  const charge = JSON.parse(M.st.bodies.find((b) => b.includes('"description"') && b.includes('29.9'))!);
  A.equal(charge.amount, 29.9); A.equal(charge.type, 320); A.equal(charge.vatType, 0); A.equal(charge.maxPayments, 1);
  A.equal(D.st.events.length, 1);
  const ev = D.st.events[0];
  A.equal(ev.outcome, 'approved'); A.equal(ev.checkoutId, CK().id); A.equal(ev.amountAgorot, 2990); A.equal(ev.transactionId, 'morning:doc-1');
  A.deepEqual(D.st.tokens.get('p1'), { id: 'tok-1', last4: '4580' });   // נשמר רק מזהה טוקן + 4 ספרות
});

Deno.test('אין חיוב כפול: רענון / לחיצה כפולה / שתי בקשות במקביל → חיוב אחד בלבד', async () => {
  const M = fakeMorning(), D = fakeDb(), m = new MorningClient(envOf(LIVE), M.f);
  await runCardCheckout('start', CK(), m, envOf(LIVE), D.db);
  M.saveCard('cl-1');
  const rs = await Promise.all([1, 2, 3].map(() => runCardCheckout('complete', CK(), m, envOf(LIVE), D.db)));
  const again = await runCardCheckout('complete', CK({ token: 'tok-1' }), m, envOf(LIVE), D.db);
  A.equal(M.st.chargeAttempts, 1); A.equal(M.st.charges, 1);
  A.equal(rs.filter((r) => r.body.mode === 'charged').length, 1);
  A.ok([...rs, again].filter((r) => r.body.mode !== 'charged').every((r) => r.body.mode === 'processing'));
  A.equal(D.st.events.length, 1);
});

Deno.test('כרטיס נדחה → אירוע כישלון, המנוי לא מופעל', async () => {
  const M = fakeMorning({ decline: true }), D = fakeDb(), m = new MorningClient(envOf(LIVE), M.f);
  M.saveCard('cl-1'); D.st.customers.set('p1', 'cl-1');
  const r = await runCardCheckout('complete', CK(), m, envOf(LIVE), D.db);
  A.equal(r.body.mode, 'failed'); A.equal(M.st.charges, 0);
  A.equal(D.st.events.length, 1); A.equal(D.st.events[0].outcome, 'failed');
  A.ok(!D.st.events.some((e) => e.outcome === 'approved'));
});

Deno.test('תקלת רשת בזמן החיוב → "בתהליך", בלי ניסיון חוזר אוטומטי ובלי הפעלה', async () => {
  const M = fakeMorning({ netFail: true }), D = fakeDb(), m = new MorningClient(envOf(LIVE), M.f);
  M.saveCard('cl-1'); D.st.customers.set('p1', 'cl-1');
  const r1 = await runCardCheckout('complete', CK(), m, envOf(LIVE), D.db);
  const r2 = await runCardCheckout('complete', CK(), m, envOf(LIVE), D.db);
  A.equal(r1.body.mode, 'processing'); A.equal(r2.body.mode, 'processing');
  A.equal(M.st.chargeAttempts, 1); A.equal(D.st.events.length, 0);
});

Deno.test('מסמך מבוטל שחזר מהחיוב → לא מופעל (נשלח לבדיקה בלי מזהה ניסיון)', async () => {
  const M = fakeMorning({ docStatus: 4 }), D = fakeDb(), m = new MorningClient(envOf(LIVE), M.f);
  M.saveCard('cl-1'); D.st.customers.set('p1', 'cl-1');
  const r = await runCardCheckout('complete', CK(), m, envOf(LIVE), D.db);
  A.equal(D.st.events[0].checkoutId, undefined); A.equal(r.body.result, 'review');
});

Deno.test('סכום שונה במסמך → נשלח עם הסכום האמיתי (המסד מסמן אי-התאמה ולא מפעיל)', async () => {
  const M = fakeMorning({ docAmount: 1 }), D = fakeDb(), m = new MorningClient(envOf(LIVE), M.f);
  M.saveCard('cl-1'); D.st.customers.set('p1', 'cl-1');
  await runCardCheckout('complete', CK(), m, envOf(LIVE), D.db);
  A.equal(D.st.events[0].amountAgorot, 100);
});

Deno.test('סליקה כבויה / Production מחוץ ל-Production → נחסם לפני כל פנייה ל-Morning', async () => {
  for (const env of [{ ...LIVE, MORNING_LIVE: '0' }, { ...LIVE, MORNING_API_BASE: PROD_API }]) {
    const M = fakeMorning(), D = fakeDb();
    await A.rejects(runCardCheckout('start', CK(), new MorningClient(envOf(env), M.f), envOf(env), D.db), MorningError);
    A.equal(M.st.bodies.length, 0);
  }
});

Deno.test('פרטי כרטיס מלאים לא עוברים ולא נשמרים אצלנו', async () => {
  const M = fakeMorning(), D = fakeDb(), m = new MorningClient(envOf(LIVE), M.f);
  await runCardCheckout('start', CK(), m, envOf(LIVE), D.db);
  M.saveCard('cl-1');
  await runCardCheckout('complete', CK(), m, envOf(LIVE), D.db);
  const ours = JSON.stringify({ db: [...D.st.tokens.values(), ...D.st.events], sent: M.st.bodies })
    .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, '<uuid>');   // מזהים, לא כרטיסים
  A.ok(!/\b\d{12,19}\b/.test(ours), 'נמצא רצף שנראה כמו מספר כרטיס');
  A.ok(!/cvv|cvc|expir/i.test(JSON.stringify([...D.st.tokens.values(), ...D.st.events])));
});

Deno.test('חידוש חודשי משתמש באותו כרטיס שמור (גוף החיוב)', () => {
  const b = tokenChargeBody('חידוש מנוי בסיסי חודשי — חיים דרך מספרים', 2990) as Record<string, unknown>;
  A.equal(b.amount, 29.9); A.equal(b.type, 320); A.equal(b.maxPayments, 1);
});
