// בדיקות יחידה ללקוח Grow — בלי רשת (fetch מדומה). הרצה: deno test --no-check supabase/functions/_shared/grow_test.ts
import { strict as A } from 'node:assert';
import {
  CheckoutInfo, GROW_PROD, GROW_SANDBOX, GrowClient, GrowError, assertGrowMoneyAllowed, flattenGrowForm, growBase,
  normalizeIlPhone, paymentProcessFields, safeEqual, tokenChargeFields, toShekelsStr, uniqueIdFor, verifyGrowPayment,
} from './grow.ts';

const envOf = (o: Record<string, string>) => (k: string) => o[k] ?? '';
type Call = { url: string; form: Record<string, string> };
function fakeFetch(route: (c: Call) => unknown, status = 200) {
  const calls: Call[] = [];
  const f = async (url: string, init?: RequestInit) => {
    const form: Record<string, string> = {};
    if (init?.body instanceof FormData) for (const [k, v] of init.body.entries()) form[k] = String(v);
    const c = { url, form }; calls.push(c);
    return new Response(JSON.stringify(route(c)), { status });
  };
  return { f, calls };
}
async function rejects(fn: () => Promise<unknown>, code?: string) {
  let e: unknown; try { await fn(); } catch (x) { e = x; }
  A.ok(e instanceof GrowError, `expected GrowError, got ${e}`);
  if (code) A.equal((e as GrowError).code, code);
  return e as GrowError;
}
const BASE = { GROW_USER_ID: 'u-1', GROW_PAGE_CODE: 'pc-1', GROW_API_KEY: 'k-1' };
const CK: CheckoutInfo = {
  id: '11111111-2222-3333-4444-555555555555', userId: 'u', profileId: 'p1', kind: 'initial', plan: 'basic', amountAgorot: 2990,
  status: 'pending', createdAt: '2026-10-20T10:00:00Z', expiresAt: '2026-10-20T10:30:00Z', expired: false, email: 'noa@example.com',
};

Deno.test('סביבות: Sandbox כברירת מחדל, כתובת זרה נדחית', () => {
  A.equal(growBase(envOf({})), GROW_SANDBOX);
  A.equal(growBase(envOf({ GROW_API_BASE: GROW_PROD + '/' })), GROW_PROD);
  A.throws(() => growBase(envOf({ GROW_API_BASE: 'https://evil.example/api' })), GrowError);
});

Deno.test('חסימות כסף: כבוי כברירת מחדל; Production חסום מחוץ ל-Production', () => {
  A.throws(() => assertGrowMoneyAllowed(envOf(BASE)), /כבויה/);
  assertGrowMoneyAllowed(envOf({ ...BASE, GROW_LIVE: '1' }));
  A.throws(() => assertGrowMoneyAllowed(envOf({ ...BASE, GROW_LIVE: '1', GROW_API_BASE: GROW_PROD, HDM_ENV: 'staging' })), /Production/);
  assertGrowMoneyAllowed(envOf({ ...BASE, GROW_LIVE: '1', GROW_API_BASE: GROW_PROD, HDM_ENV: 'production' }));
});

Deno.test('חיוב חסום לא שולח שום בקשה ל-Grow', async () => {
  const { f, calls } = fakeFetch(() => ({ status: 1, data: {} }));
  const g = new GrowClient(envOf({ ...BASE, GROW_LIVE: '1', GROW_API_BASE: GROW_PROD }), f);
  await rejects(() => g.createTransactionWithToken({ sum: '1.00' }), 'PRODUCTION_BLOCKED');
  await rejects(() => g.createPaymentProcess({ sum: '1.00' }), 'PRODUCTION_BLOCKED');
  const g2 = new GrowClient(envOf(BASE), f);
  await rejects(() => g2.createPaymentProcess({ sum: '1.00' }), 'GROW_OFF');
  A.equal(calls.length, 0);
});

Deno.test('בקשה: טופס עם userId, pageCode, apiKey; תשובה status=1', async () => {
  const { f, calls } = fakeFetch(() => ({ status: 1, err: '', data: { url: 'https://sandbox.meshulam.co.il/pay/x', processId: 7 } }));
  const g = new GrowClient(envOf({ ...BASE, GROW_LIVE: '1' }), f);
  const r = await g.createPaymentProcess({ sum: '29.90' });
  A.equal(calls[0].url, `${GROW_SANDBOX}/createPaymentProcess`);
  A.deepEqual([calls[0].form.userId, calls[0].form.pageCode, calls[0].form.apiKey, calls[0].form.sum], ['u-1', 'pc-1', 'k-1', '29.90']);
  A.equal(r.data.processId, 7);
});

Deno.test('בלי apiKey — לא נשלח שדה ריק; בלי userId — שגיאה', async () => {
  const { f, calls } = fakeFetch(() => ({ status: 1, data: {} }));
  await new GrowClient(envOf({ GROW_USER_ID: 'u', GROW_PAGE_CODE: 'p' }), f).getTransactionInfo('1', 't');
  A.equal('apiKey' in calls[0].form, false);
  await rejects(() => new GrowClient(envOf({ GROW_PAGE_CODE: 'p' }), f).getTransactionInfo('1', 't'), 'NO_CREDENTIALS');
});

Deno.test('תשובת status=0 → REJECTED עם הודעת Grow; 5xx → UPSTREAM', async () => {
  const { f } = fakeFetch(() => ({ status: 0, err: { id: 401, message: 'card declined' }, data: '' }));
  const e = await rejects(() => new GrowClient(envOf({ ...BASE, GROW_LIVE: '1' }), f).createTransactionWithToken({}), 'REJECTED');
  A.match(e.message, /card declined/);
  A.ok(!e.message.includes('k-1'));
  const { f: f5 } = fakeFetch(() => ({}), 502);
  await rejects(() => new GrowClient(envOf(BASE), f5).getTransactionInfo('1', 't'), 'UPSTREAM');
});

Deno.test('דף תשלום: שלושת המחירים, שמירת כרטיס, notify, מזהה ניסיון', () => {
  for (const [plan, ag, s] of [['basic', 2990, '29.90'], ['plus', 4890, '48.90'], ['vip', 7990, '79.90']] as const) {
    const f = paymentProcessFields(envOf({ HDM_APP_URL: 'https://app.example/' }), { ...CK, plan, amountAgorot: ag }, 'https://n');
    A.equal(f.sum, s);
  }
  const f = paymentProcessFields(envOf({ HDM_APP_URL: 'https://app.example' }), CK, 'https://n');
  A.equal(f.saveCardToken, 1); A.equal(f.chargeType, 1); A.equal(f.paymentNum, 1);
  A.equal(f.cField1, CK.id); A.equal(f.notifyUrl, 'https://n');
  A.equal(f.successUrl, `https://app.example/?billing=return&ck=${CK.id}`);
  A.equal(f['pageField[email]'], 'noa@example.com');
});

Deno.test('חיוב בכרטיס: ראשון עם isRecurringDebitPayment, אחר כך recurringDebitId; מזהה ייחודי יציב', async () => {
  const base = { token: 'ct', agorot: 950, description: 'd', name: 'נועה כהן', phone: '0500000000', key: 'renewal:abc', recurring: true };
  const first = await tokenChargeFields(base);
  A.equal(first.isRecurringDebitPayment, 1); A.equal(first.recurringDebitId, undefined); A.equal(first.sum, '9.50');
  const next = await tokenChargeFields({ ...base, recurringDebitId: 'RD9' });
  A.equal(next.recurringDebitId, 'RD9'); A.equal(next.isRecurringDebitPayment, undefined);
  const up = await tokenChargeFields({ ...base, recurring: false, key: 'upgrade:x' });
  A.equal(up.isRecurringDebitPayment, undefined); A.equal(up.recurringDebitId, undefined);
  A.equal(first.transactionUniqueIdentifier, await uniqueIdFor('renewal:abc'));       // אותו חיוב → אותו מספר
  A.notEqual(await uniqueIdFor('renewal:abc'), await uniqueIdFor('renewal:abd'));
  const n = await uniqueIdFor('x'); A.ok(n >= 100_000_000 && n < 1_000_000_000);
});

Deno.test('עזרים: טלפון, סכום, השוואה קבועה', () => {
  A.equal(normalizeIlPhone('050-000-0000'), '0500000000');
  A.equal(normalizeIlPhone('+972 52 123 4567'), '0521234567');
  A.equal(normalizeIlPhone('123'), null);
  A.equal(toShekelsStr(2990), '29.90');
  A.ok(safeEqual('abc', 'abc')); A.ok(!safeEqual('abc', 'abd')); A.ok(!safeEqual('', 'x'));
});

Deno.test('הודעת שרת: שדות שטוחים או data[...]', () => {
  A.deepEqual(flattenGrowForm({ 'data[transactionId]': '9', 'data[customFields][cField1]': 'ck', status: '1' }),
    { transactionId: '9', cField1: 'ck', status: '1' });
  A.deepEqual(flattenGrowForm({ data: { transactionId: 9, customFields: { cField1: 'ck' } } }), { transactionId: '9', cField1: 'ck' });
});

const NOTE = { transactionId: '555', transactionToken: 'tt', sum: '29.90', cField1: CK.id, cardToken: 'CT1', cardSuffix: '4580',
  fullName: 'נועה כהן', payerPhone: '050-000-0000', cardExp: '1230', asmachta: '0123' };

Deno.test('אימות תשלום: תואם → אירוע מקושר, סכום מ-Grow, כרטיס ופרטי משלם', () => {
  const v = verifyGrowPayment(NOTE, { transactionId: 555, sum: 29.9 }, CK);
  A.ok(v.bound);
  A.deepEqual([v.event.transactionId, v.event.kind, v.event.outcome, v.event.amountAgorot, v.event.checkoutId],
    ['grow:555', 'initial', 'approved', 2990, CK.id]);
  A.deepEqual(v.card, { token: 'CT1', last4: '4580', name: 'נועה כהן', phone: '0500000000', exp: '1230' });
});

Deno.test('אימות תשלום: הסכום נלקח מ-Grow ולא מההודעה', () => {
  const v = verifyGrowPayment({ ...NOTE, sum: '29.90' }, { transactionId: '555', sum: '1.00' }, CK);
  A.equal(v.event.amountAgorot, 100);      // המסד יסמן amount_mismatch ולא יפעיל
});

Deno.test('אימות תשלום: עסקה אחרת / ניסיון אחר / בלי ניסיון → בלי checkoutId (לא מפעיל, לבדיקה)', () => {
  for (const [note, info, ck] of [
    [NOTE, { transactionId: '999', sum: 29.9 }, CK],
    [{ ...NOTE, cField1: '00000000-0000-0000-0000-000000000000' }, { transactionId: '555', sum: 29.9 }, CK],
    [NOTE, { transactionId: '555', sum: 29.9 }, null],
  ] as [Record<string, string>, Record<string, unknown>, CheckoutInfo | null][]) {
    const v = verifyGrowPayment(note, info, ck);
    A.ok(!v.bound, JSON.stringify(v.problems));
    A.equal(v.event.checkoutId, undefined);
  }
  A.throws(() => verifyGrowPayment({}, {}, CK), GrowError);
});

Deno.test('אימות תשלום: שדרוג → kind=upgrade; בלי cardToken → אין כרטיס', () => {
  const v = verifyGrowPayment({ ...NOTE, cardToken: '' }, { transactionId: '555', sum: 9.5 }, { ...CK, kind: 'upgrade', amountAgorot: 950 });
  A.equal(v.event.kind, 'upgrade'); A.equal(v.card, null);
});
