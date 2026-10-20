// =====================================================================
// חיים דרך מספרים — grow-mock: תחליף ל-Grow לבדיקות אוטומטיות ב-Staging בלבד. לא מזיז כסף ולא פונה ל-Grow.
//
// פועל רק כש-HDM_ENV=staging ו-GROW_MOCK=1; אחרת 404. מחקה את ה-API של Grow לפי התיעוד:
//   createPaymentProcess · getTransactionInfo · approveTransaction · createTransactionWithToken  (טופס → { status, err, data })
// ומוסיף נקודת בדיקה אחת שאין ב-Grow:
//   GET /pay?p=...&scenario=ok|wrongsum|forged — "הלקוח שילם": שולח הודעת שרת ל-notifyUrl כמו ש-Grow שולחת.
// בלי מצב שמור: מזהי העסקאות חתומים ב-HMAC (GROW_MOCK_SECRET), כך ש-getTransactionInfo מזהה הודעה מזויפת.
// כרטיס שה-Token שלו מתחיל ב-DECLINE — נדחה (לבדיקת חיוב שנכשל).
// הקוד המשותף: ../_shared/grow_mock.ts (גם לבדיקה המקומית); כאן רק Deno.serve.
// =====================================================================
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'content-type': 'application/json' } });
const ok = (data: Record<string, unknown>) => json({ status: 1, err: '', data });
const fail = (id: number, message: string) => json({ status: 0, err: { id, message }, data: '' });

let ENV: (k: string) => string = () => '';
const env = (k: string) => ENV(k);
const enc = new TextEncoder();
async function hmac(s: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', enc.encode(env('GROW_MOCK_SECRET')), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(s)));
  return btoa(String.fromCharCode(...sig)).replace(/[+/=]/g, (c) => ({ '+': '-', '/': '_', '=': '' }[c]!));
}
const b64 = (o: unknown) => btoa(unescape(encodeURIComponent(JSON.stringify(o)))).replace(/[+/=]/g, (c) => ({ '+': '-', '/': '_', '=': '' }[c]!));
const unb64 = (s: string) => JSON.parse(decodeURIComponent(escape(atob(s.replace(/-/g, '+').replace(/_/g, '/')))));
async function sign(o: unknown) { const p = b64(o); return `${p}.${await hmac(p)}`; }
async function verify(t: string): Promise<Record<string, unknown> | null> {
  const [p, s] = String(t).split('.');
  if (!p || !s || (await hmac(p)) !== s) return null;
  try { return unb64(p); } catch { return null; }
}
const rnd = (n = 9) => String(Math.floor(10 ** (n - 1) + Math.random() * 9 * 10 ** (n - 1)));

async function form(req: Request): Promise<Record<string, string>> {
  const o: Record<string, string> = {};
  const ct = req.headers.get('content-type') ?? '';
  if (ct.includes('multipart/form-data')) { for (const [k, v] of (await req.formData()).entries()) if (typeof v === 'string') o[k] = v; }
  else for (const [k, v] of new URLSearchParams(await req.text())) o[k] = v;
  return o;
}
function creds(f: Record<string, string>) { return f.userId === env('GROW_USER_ID') && f.pageCode === env('GROW_PAGE_CODE'); }
function missing(f: Record<string, string>, keys: string[]) { return keys.filter((k) => !f[k]); }

export async function mockHandler(req: Request, env: (k: string) => string, fetchFn: typeof fetch): Promise<Response> {
  ENV = env;
  if (env('HDM_ENV') !== 'staging' || env('GROW_MOCK') !== '1' || env('GROW_MOCK_SECRET').length < 32) return new Response('not found', { status: 404 });
  const u = new URL(req.url);
  const op = u.pathname.split('/').filter(Boolean).pop() ?? '';
  const self = `${env('SUPABASE_URL').replace(/\/+$/, '')}/functions/v1/grow-mock`;

  if (op === 'pay' && req.method === 'GET') {
    const p = await verify(u.searchParams.get('p') ?? '');
    if (!p) return json({ error: 'bad process' }, 400);
    const scenario = u.searchParams.get('scenario') ?? 'ok';
    const tx = rnd();
    const realSum = scenario === 'wrongsum' ? '1.00' : String(p.sum);
    const token = scenario === 'forged' ? `${b64({ tx, sum: realSum, ck: p.ck })}.forged` : await sign({ tx, sum: realSum, ck: p.ck });
    // הודעת שרת כמו של Grow: טופס, השדות תחת data[...]
    const note: Record<string, string> = {
      status: '1', 'data[transactionId]': tx, 'data[transactionToken]': token, 'data[transactionTypeId]': '1', 'data[paymentType]': '2',
      'data[sum]': String(p.sum), 'data[paymentsNum]': '1', 'data[allPaymentsNum]': '1', 'data[asmachta]': rnd(7),
      'data[description]': String(p.description), 'data[fullName]': 'נועה בדיקה', 'data[payerPhone]': '050-000-0000',
      'data[payerEmail]': String(p.email ?? ''), 'data[cardSuffix]': '4580', 'data[cardType]': 'Local', 'data[cardBrand]': 'Visa',
      'data[cardExp]': '1230', 'data[cardToken]': `CT-${rnd(12)}`, 'data[processId]': String(p.processId),
      'data[processToken]': String(p.processToken), 'data[customFields][cField1]': String(p.ck), 'data[customFields][cField2]': String(p.kind ?? ''),
    };
    const r = await fetchFn(String(p.notifyUrl), { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(note).toString() });
    return json({ webhookStatus: r.status, webhook: await r.json().catch(() => null), note });
  }
  if (req.method !== 'POST') return new Response('method', { status: 405 });
  const f = await form(req);
  if (!creds(f)) return fail(401, 'userId/pageCode שגויים');

  switch (op) {
    case 'createPaymentProcess': {
      const miss = missing(f, ['sum', 'description', 'successUrl', 'cancelUrl', 'notifyUrl']);
      if (miss.length) return fail(400, `חסר: ${miss.join(',')}`);
      if (!/^\d+\.\d{2}$/.test(f.sum)) return fail(400, 'sum לא תקין');
      if (f.saveCardToken !== '1') return fail(400, 'הבדיקה מצפה ל-saveCardToken=1');
      const processId = rnd(), processToken = rnd(16);
      const p = await sign({ sum: f.sum, description: f.description, notifyUrl: f.notifyUrl, ck: f.cField1, kind: f.cField2, email: f['pageField[email]'], processId, processToken });
      return ok({ url: `${self}/pay?p=${p}`, processId, processToken });
    }
    case 'getTransactionInfo': {
      const t = await verify(f.transactionToken ?? '');
      if (!t || String(t.tx) !== f.transactionId) return fail(404, 'עסקה לא נמצאה');
      return ok({ transactionId: f.transactionId, sum: t.sum, statusCode: '2', asmachta: '0000000' });
    }
    case 'approveTransaction':
      return f.transactionId ? ok({ approved: true }) : fail(400, 'חסר transactionId');
    case 'createTransactionWithToken': {
      const miss = missing(f, ['cardToken', 'sum', 'description', 'paymentType', 'pageField[fullName]', 'pageField[phone]', 'transactionUniqueIdentifier']);
      if (miss.length) return fail(400, `חסר: ${miss.join(',')}`);
      if (!/^\d{9}$/.test(f.transactionUniqueIdentifier)) return fail(400, 'transactionUniqueIdentifier לא תקין');
      if (!/^0\d{8,9}$/.test(f['pageField[phone]'])) return fail(400, 'טלפון לא תקין');
      if (f.cardToken.startsWith('DECLINE')) return fail(5, 'העסקה נדחתה על ידי חברת האשראי (בדיקה)');
      const data: Record<string, unknown> = { transactionId: rnd(), asmachta: rnd(7), sum: f.sum };
      if (f.isRecurringDebitPayment === '1') data.recurringDebitId = `RD-${rnd(8)}`;
      if (f.recurringDebitId) data.recurringDebitId = f.recurringDebitId;
      return ok(data);
    }
  }
  return fail(404, `לא מוכר: ${op}`);
}
