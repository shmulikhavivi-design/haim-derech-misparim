// =====================================================================
// חיים דרך מספרים — תחליף Morning לבדיקות (Staging / מקומי בלבד). לא פונה ל-Morning ולא מפיק מסמך אמיתי.
// פועל רק עם HDM_ENV=staging + MORNING_MOCK=1. מחקה: POST /idp/v1/oauth/token, POST /documents.
// בודק את המסמך כמו שרואה חשבון היה בודק: סוג 320, סכום ההכנסה = סכום התשלום, תשלום באשראי, מטבע ILS.
// לקוח ששמו מכיל FAILDOC — נדחה (לבדיקת כישלון).
// =====================================================================
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'content-type': 'application/json' } });
const rnd = (n: number) => String(Math.floor(10 ** (n - 1) + Math.random() * 9 * 10 ** (n - 1)));

export async function morningMockHandler(req: Request, env: (k: string) => string): Promise<Response> {
  if (env('HDM_ENV') !== 'staging' || env('MORNING_MOCK') !== '1') return new Response('not found', { status: 404 });
  const path = new URL(req.url).pathname;
  if (req.method !== 'POST') return json({ errorCode: 405, errorMessage: 'method' }, 405);
  if (path.endsWith('/idp/v1/oauth/token')) {
    const f = new URLSearchParams(await req.text());
    if (f.get('grant_type') !== 'client_credentials' || f.get('client_id') !== env('MORNING_CLIENT_ID') || f.get('client_secret') !== env('MORNING_CLIENT_SECRET')) {
      return json({ error: 'invalid_client' }, 401);
    }
    return json({ accessToken: `mock-${rnd(12)}`, expiresAt: Math.floor(Date.now() / 1000) + 3600 });
  }
  if (!(req.headers.get('authorization') ?? '').startsWith('Bearer mock-')) return json({ errorCode: 401, errorMessage: 'auth' }, 401);
  if (path.endsWith('/documents')) {
    const d = await req.json().catch(() => ({})) as Record<string, any>;
    const inc = (d.income ?? []).reduce((a: number, i: any) => a + Number(i.price) * Number(i.quantity ?? 1), 0);
    const pay = (d.payment ?? []).reduce((a: number, p: any) => a + Number(p.price), 0);
    const problems: string[] = [];
    if (d.type !== 320) problems.push('type');
    if (d.currency !== 'ILS') problems.push('currency');
    if (Math.round(inc * 100) !== Math.round(pay * 100) || pay <= 0) problems.push('2422 sum mismatch');
    if (!(d.payment ?? []).every((p: any) => p.type === 3 && /^\d{4}-\d{2}-\d{2}$/.test(String(p.date)))) problems.push('payment');
    if (!d.client?.name) problems.push('client');
    if (String(d.client?.name ?? '').includes('FAILDOC')) problems.push('rejected (test)');
    if (problems.length) return json({ errorCode: 2422, errorMessage: problems.join(',') }, 400);
    return json({ id: crypto.randomUUID(), number: rnd(5), type: 320, amount: pay, currency: 'ILS' }, 201);
  }
  return json({ errorCode: 404, errorMessage: 'unknown' }, 404);
}
