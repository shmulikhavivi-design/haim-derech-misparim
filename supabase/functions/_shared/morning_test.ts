// בדיקות יחידה ללקוח Morning — בלי רשת (fetch מדומה). הרצה: deno test supabase/functions/_shared/morning_test.ts
import { strict as A } from 'node:assert';

// עטיפות קטנות מעל node:assert (מובנה ב-Deno, בלי הורדה)
const assert = (c: unknown, msg?: string) => A.ok(c, msg);
const assertEquals = (a: unknown, b: unknown) => A.deepStrictEqual(a, b);
// deno-lint-ignore no-explicit-any
function assertThrows(fn: () => unknown, cls?: any, includes?: string) {
  A.throws(fn, (e: Error) => (!cls || e instanceof cls) && (!includes || e.message.includes(includes)));
}
// deno-lint-ignore no-explicit-any
async function assertRejects(fn: () => Promise<unknown>, cls?: any, includes?: string): Promise<any> {
  let caught: unknown;
  try { await fn(); } catch (e) { caught = e; }
  A.ok(caught, 'expected rejection');
  if (cls) A.ok(caught instanceof cls, `wrong error type: ${caught}`);
  if (includes) A.ok((caught as Error).message.includes(includes), (caught as Error).message);
  return caught;
}
import {
  CheckoutInfo, MorningClient, MorningError, PROD_API, SANDBOX_API, apiBase, assertMoneyAllowed, authBase, findCardToken,
  paymentFormBody, pickCheckoutId, pickDocumentId, tokenChargeBody, verifyMorningSignature, safeEqual, toAgorot, toShekels, verifyDocumentAgainstCheckout,
} from './morning.ts';

const envOf = (o: Record<string, string>) => (k: string) => o[k] ?? '';
type Call = { url: string; init?: RequestInit };
function fakeFetch(routes: (c: Call) => Response) {
  const calls: Call[] = [];
  const f = (url: string, init?: RequestInit) => { const c = { url, init }; calls.push(c); return Promise.resolve(routes(c)); };
  return { f, calls };
}
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'content-type': 'application/json' } });

const CK: CheckoutInfo = {
  id: '11111111-2222-3333-4444-555555555555', userId: 'u', profileId: 'p1', kind: 'initial', plan: 'basic',
  amountAgorot: 2990, status: 'pending', createdAt: '2026-10-20T10:00:00Z', expiresAt: '2026-10-20T10:30:00Z',
  expired: false, email: 'noa@example.com',
};
const BASE = { MORNING_CLIENT_ID: 'id-1', MORNING_CLIENT_SECRET: 'sec-1', MORNING_API_BASE: SANDBOX_API };

Deno.test('סביבות: כתובת האימות נגזרת מכתובת ה-API', () => {
  assertEquals(apiBase(envOf({})), SANDBOX_API);                       // ברירת מחדל = Sandbox
  assertEquals(authBase(SANDBOX_API), 'https://api.sandbox.morning.dev');
  assertEquals(authBase(PROD_API), 'https://api.morning.co');
  assertThrows(() => apiBase(envOf({ MORNING_API_BASE: 'https://evil.example/api/v1' })), MorningError);
});

Deno.test('חסימות כסף: כבוי כברירת מחדל, Production חסום מחוץ ל-Production', () => {
  assertThrows(() => assertMoneyAllowed(envOf(BASE)), MorningError, 'כבויה');
  assertMoneyAllowed(envOf({ ...BASE, MORNING_LIVE: '1' }));            // Sandbox + LIVE = מותר
  assertThrows(() => assertMoneyAllowed(envOf({ ...BASE, MORNING_LIVE: '1', MORNING_API_BASE: PROD_API, HDM_ENV: 'staging' })),
    MorningError, 'Production');
  assertMoneyAllowed(envOf({ ...BASE, MORNING_LIVE: '1', MORNING_API_BASE: PROD_API, HDM_ENV: 'production' }));
});

Deno.test('חיוב חסום לא שולח שום בקשה (גם לא אימות)', async () => {
  const { f, calls } = fakeFetch(() => json({}));
  const m = new MorningClient(envOf({ ...BASE, MORNING_API_BASE: PROD_API, MORNING_LIVE: '1' }), f);
  await assertRejects(() => m.chargeToken('tok', { amount: 1 }), MorningError, 'Production');
  await assertRejects(() => m.createPaymentForm({ amount: 1 }), MorningError, 'Production');
  assertEquals(calls.length, 0);
});

Deno.test('אימות OAuth: client_credentials, טוקן נשמר ומשמש שוב', async () => {
  const { f, calls } = fakeFetch((c) => c.url.endsWith('/idp/v1/oauth/token')
    ? json({ accessToken: 'AT', expiresAt: Math.floor(Date.now() / 1000) + 3600 })
    : json({ id: 'b1' }));
  const m = new MorningClient(envOf({ ...BASE, MORNING_API_BASE: PROD_API }), f);
  await m.businessMe(); await m.documentInfo();                       // קריאה בלבד — מותר גם מול Production
  assertEquals(calls.filter((c) => c.url.includes('oauth')).length, 1);
  const auth = calls[0];
  assertEquals(auth.url, 'https://api.morning.co/idp/v1/oauth/token');
  const sent = new URLSearchParams(String(auth.init?.body));
  assertEquals([sent.get('grant_type'), sent.get('client_id'), sent.get('client_secret')], ['client_credentials', 'id-1', 'sec-1']);
  assertEquals((calls[1].init?.headers as Record<string, string>).authorization, 'Bearer AT');
  assertEquals(calls[2].url, `${PROD_API}/documents/info?type=320`);
});

Deno.test('אימות: נופל ל-JSON אם הטופס נדחה; כישלון לא חושף את הסוד', async () => {
  let n = 0;
  const { f } = fakeFetch((c) => {
    if (c.url.includes('oauth')) return ++n === 1 ? json({ error: 'bad' }, 415) : json({ access_token: 'AT2', expires_in: 3600 });
    return json({ ok: 1 });
  });
  const m = new MorningClient(envOf(BASE), f);
  await m.businessMe();
  assertEquals(n, 2);
  const { f: f2 } = fakeFetch(() => json({ error: 'invalid_client' }, 401));
  const e = await assertRejects(() => new MorningClient(envOf(BASE), f2).businessMe(), MorningError);
  assert(!e.message.includes('sec-1'));
});

Deno.test('שגיאה עסקית בתוך 201 נחשבת שגיאה', async () => {
  const { f } = fakeFetch((c) => c.url.includes('oauth') ? json({ accessToken: 'AT', expiresAt: 9e9 }) : json({ success: false, errorCode: 2600 }, 201));
  const m = new MorningClient(envOf({ ...BASE, MORNING_LIVE: '1' }), f);
  const e = await assertRejects(() => m.createPaymentForm({}), MorningError);
  assertEquals(e.code, 'REJECTED');
});

Deno.test('דף תשלום: סכום כולל מע"מ, שורת הכנסה כוללת מע"מ, עם תוסף, notify והפניות', () => {
  const b = paymentFormBody(envOf({ MORNING_PLUGIN_ID: 'plug', HDM_APP_URL: 'https://app.example/' }), CK, 'https://n');
  assertEquals(b.amount, 29.9);
  assertEquals(b.type, 320);
  assertEquals(b.pluginId, 'plug');
  assertEquals(b.vatType, 0);    // 1 ברמת המסמך = פטור ממע"מ — אסור
  assertEquals(b.income, [{ description: 'מנוי בסיסי חודשי', quantity: 1, price: 29.9, currency: 'ILS', vatType: 1 }]);
  assertEquals(b.notifyUrl, 'https://n');
  assertEquals(b.custom, CK.id);
  assertEquals(b.successUrl, `https://app.example/?billing=return&ck=${CK.id}`);
  assertEquals((b.client as Record<string, unknown>).emails, ['noa@example.com']);
});

Deno.test('חיוב חידוש: מסמך vatType 0, שורה כוללת מע"מ בסכום המסלול', () => {
  const b = tokenChargeBody('מנוי פלוס חודשי', 4890);
  assertEquals(b.vatType, 0);
  assertEquals(b.income, [{ description: 'מנוי פלוס חודשי', quantity: 1, price: 48.9, currency: 'ILS', vatType: 1 }]);
});

Deno.test('המרות סכום ואגורות', () => {
  assertEquals(toAgorot('29.90'), 2990); assertEquals(toAgorot(48.9), 4890); assertEquals(toAgorot(79.9), 7990);
  assertEquals(toShekels(950), 9.5);
});

Deno.test('webhook: טוקן בהשוואה קבועה, מזהה מסמך מכל צורה', () => {
  assert(safeEqual('abc', 'abc')); assert(!safeEqual('abc', 'abd')); assert(!safeEqual('abc', 'abcd')); assert(!safeEqual('', 'x'));
  assertEquals(pickDocumentId({ documentId: 'd1' }), 'd1');
  assertEquals(pickDocumentId({ document: { id: 'd2' } }), 'd2');
  assertEquals(pickDocumentId({ foo: 1 }), '');
});

const DOC = { id: 'doc-1', type: 320, currency: 'ILS', amount: 29.9, number: 1001, creationDate: Date.parse('2026-10-20T10:05:00Z') / 1000,
  client: { id: 'cl-1', emails: ['Noa@Example.com'] } };

Deno.test('אימות מסמך: תואם → אירוע עם checkoutId וסכום מהמסמך', () => {
  const v = verifyDocumentAgainstCheckout(DOC, CK);
  assert(v.bound);
  assertEquals(v.event.checkoutId, CK.id);
  assertEquals(v.event.amountAgorot, 2990);
  assertEquals(v.event.transactionId, 'morning:doc-1');
  assertEquals(v.event.kind, 'initial');
  assertEquals(v.clientId, 'cl-1');
});

Deno.test('אימות מסמך: סכום שונה → נשאר מקושר, והמסד יסמן amount_mismatch', () => {
  const v = verifyDocumentAgainstCheckout({ ...DOC, amount: 1 }, CK);
  assert(v.bound);
  assertEquals(v.event.amountAgorot, 100);
});

Deno.test('אימות מסמך: מייל אחר / מסמך ישן / אין ניסיון → בלי checkoutId (לא מפעיל, לבדיקה)', () => {
  for (const [doc, ck] of [
    [{ ...DOC, client: { emails: ['other@example.com'] } }, CK],
    [{ ...DOC, creationDate: Date.parse('2026-10-19T10:00:00Z') / 1000 }, CK],
    [{ ...DOC, type: 305 }, CK],
    [DOC, null],
  ] as [Record<string, unknown>, CheckoutInfo | null][]) {
    const v = verifyDocumentAgainstCheckout(doc, ck);
    assert(!v.bound, JSON.stringify(v.problems));
    assertEquals(v.event.checkoutId, undefined);
  }
  assertThrows(() => verifyDocumentAgainstCheckout({}, CK), MorningError);
});

Deno.test('טוקן כרטיס (לפי התיעוד הרשמי): externalKey, סטטוס תקף בלבד, 4 ספרות מ-number', async () => {
  const { f, calls } = fakeFetch((c) => c.url.includes('oauth') ? json({ accessToken: 'AT', expiresAt: 9e9 }) : json({ total: 4, items: [
    { id: 'old', externalKey: 'cl-1', status: 1, creationDate: 1, number: '1111' },
    { id: 'revoked', externalKey: 'cl-1', status: 3, creationDate: 2e9, number: '2222' },
    { id: 'other', externalKey: 'cl-2', status: 1, creationDate: 2e9, number: '3333' },
    { id: 'new', externalKey: 'cl-1', status: 2, creationDate: Date.parse('2026-10-20T10:06:00Z') / 1000, number: '4242' },
  ] }));
  const m = new MorningClient(envOf(BASE), f);       // חיפוש טוקנים לא מזיז כסף — עובד גם כשהסליקה כבויה
  const t = await findCardToken(m, 'cl-1', Date.parse(CK.createdAt));
  assertEquals(t, { id: 'new', last4: '4242' });
  assertEquals(JSON.parse(String(calls[1].init?.body)).externalKey, 'cl-1');
  assertEquals(await findCardToken(m, undefined, 0), null);
});

Deno.test('Morning Webhooks: מזהה מסמך מאירוע document/created, custom → ניסיון התשלום', () => {
  assertEquals(pickDocumentId({ id: 'doc-9', type: 320, number: 17 }), 'doc-9');
  assertEquals(pickDocumentId({ id: 'pay-req-1', total: 10 }), '');   // payment/received — לא מסמך
  assertEquals(pickCheckoutId({ custom: CK.id }), CK.id);
  assertEquals(pickCheckoutId({ custom: { custom: CK.id } }), CK.id);
  assertEquals(pickCheckoutId({}), '');
});

Deno.test('Morning Webhooks: חתימת HMAC-SHA256 על הגוף הגולמי', async () => {
  const body = '{"id":"doc-9","type":320}', secret = 'whsec-0123456789abcdef';
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const hex = Array.from(new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body))), (b) => b.toString(16).padStart(2, '0')).join('');
  assert(await verifyMorningSignature(body, hex, secret));
  assert(!await verifyMorningSignature(body + ' ', hex, secret));        // גוף ששונה
  assert(!await verifyMorningSignature(body, hex, 'other-secret-xxxxxx'));
  assert(!await verifyMorningSignature(body, hex, ''));                  // בלי סוד מוגדר — נדחה
});

Deno.test('אימות מסמך: מסמך מבוטל לא מפעיל מנוי', () => {
  const v = verifyDocumentAgainstCheckout({ id: 'd1', type: 320, currency: 'ILS', amount: 48.9, status: 4, client: { emails: [CK.email] } }, CK);
  assert(!v.bound); assert(v.problems.some((p) => p.includes('מבוטל')));
});
