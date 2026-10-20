// =====================================================================
// חיים דרך מספרים — לקוח ה-API של Morning (חשבונית ירוקה), שמחובר לסליקה של Grow.
//
// עקרונות:
//   * המפתחות (MORNING_CLIENT_ID / MORNING_CLIENT_SECRET) נקראים רק ממשתני הסביבה של הפונקציה (Supabase Secrets).
//     לא נשמרים בקוד, לא נשלחים לדפדפן ולא מודפסים ביומן.
//   * כל פעולה שעלולה להעביר כסף (דף תשלום, חיוב כרטיס שמור) חסומה עד MORNING_LIVE=1,
//     ומול חשבון ה-Production של Morning — חסומה תמיד, חוץ מבסביבה שמוגדרת HDM_ENV=production.
//     קריאות GET (קריאה בלבד) מותרות.
//   * הקובץ לא תלוי ב-Deno: הסביבה, fetch והשעון מוזרקים, כדי שאפשר יהיה לבדוק אותו בלי רשת.
//
// מקור (נבדק 20.10.2026): אימות OAuth 2.0 client-credentials מול שרת זהות נפרד:
//   Production: API https://api.greeninvoice.co.il/api/v1        · אימות https://api.morning.co
//   Sandbox:    API https://sandbox.d.greeninvoice.co.il/api/v1  · אימות https://api.sandbox.morning.dev
//   POST {AUTH}/idp/v1/oauth/token  { grant_type: client_credentials, client_id, client_secret } → accessToken, expiresAt
// =====================================================================

export type EnvFn = (k: string) => string;
export type FetchFn = (input: string, init?: RequestInit) => Promise<Response>;

export const PROD_API = 'https://api.greeninvoice.co.il/api/v1';
export const SANDBOX_API = 'https://sandbox.d.greeninvoice.co.il/api/v1';
const AUTH_HOST: Record<string, string> = {
  [PROD_API]: 'https://api.morning.co',
  [SANDBOX_API]: 'https://api.sandbox.morning.dev',
};

export class MorningError extends Error {
  constructor(public code: string, message: string, public status = 0, public body: unknown = undefined) {
    super(message);
  }
}

/** תחליף Morning לבדיקות אוטומטיות — רק ב-Staging, רק עם MORNING_MOCK=1, ורק הפונקציה morning-mock של אותו פרויקט. */
export function morningMockBase(env: EnvFn): string | null {
  const sb = (env('SUPABASE_URL') || '').trim().replace(/\/+$/, '');
  if (env('HDM_ENV') !== 'staging' || env('MORNING_MOCK') !== '1' || !/^https:\/\/[a-z0-9]+\.supabase\.co$/.test(sb)) return null;
  return `${sb}/functions/v1/morning-mock`;
}
export function apiBase(env: EnvFn): string {
  const b = (env('MORNING_API_BASE') || SANDBOX_API).trim().replace(/\/+$/, '');
  if (b in AUTH_HOST) return b;
  if (b === morningMockBase(env)) return b;
  throw new MorningError('BAD_BASE', 'MORNING_API_BASE לא מוכר (רק Production או Sandbox של Morning)');
}
export const authBase = (api: string) => AUTH_HOST[api] ?? api;   // לתחליף: אותה כתובת
export const isProductionApi = (api: string) => api === PROD_API;

/** חסימה לכל פעולה שעלולה להעביר כסף. */
export function assertMoneyAllowed(env: EnvFn): void {
  if (env('MORNING_LIVE') !== '1') {
    throw new MorningError('MORNING_OFF', 'הסליקה כבויה (MORNING_LIVE לא פעיל) — לא נשלח דבר ל-Morning');
  }
  if (isProductionApi(apiBase(env)) && env('HDM_ENV') !== 'production') {
    throw new MorningError('PRODUCTION_BLOCKED', 'חשבון ה-Production של Morning חסום לחיובים מחוץ ל-Production');
  }
}

export const toAgorot = (shekels: unknown): number => Math.round(Number(shekels) * 100);
export const toShekels = (agorot: number): number => Math.round(agorot) / 100;

/** השוואה בזמן קבוע (לטוקן ה-webhook). */
export function safeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  let diff = ea.length ^ eb.length;
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) diff |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return diff === 0;
}

export class MorningClient {
  private token = '';
  private tokenExp = 0;
  readonly api: string;

  constructor(private env: EnvFn, private fetchFn: FetchFn, private now: () => number = Date.now) {
    this.api = apiBase(env);
  }

  private async accessToken(): Promise<string> {
    if (this.token && this.now() < this.tokenExp - 60_000) return this.token;
    const id = this.env('MORNING_CLIENT_ID'), secret = this.env('MORNING_CLIENT_SECRET');
    if (!id || !secret) throw new MorningError('NO_CREDENTIALS', 'חסרים MORNING_CLIENT_ID / MORNING_CLIENT_SECRET בסודות הפונקציה');
    const url = `${authBase(this.api)}/idp/v1/oauth/token`;
    const form = new URLSearchParams({ grant_type: 'client_credentials', client_id: id, client_secret: secret });
    let r = await this.fetchFn(url, {
      method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' }, body: form.toString(),
    });
    if (r.status === 415 || r.status === 400) {   // שרת שמקבל רק JSON
      r = await this.fetchFn(url, {
        method: 'POST', headers: { 'content-type': 'application/json', accept: 'application/json' },
        body: JSON.stringify({ grant_type: 'client_credentials', client_id: id, client_secret: secret }),
      });
    }
    const j = await r.json().catch(() => ({})) as Record<string, unknown>;
    const tok = String(j.accessToken ?? j.access_token ?? j.token ?? '');
    if (!r.ok || !tok) throw new MorningError('AUTH_FAILED', `האימות מול Morning נכשל (HTTP ${r.status})`, r.status);
    const expAt = Number(j.expiresAt ?? j.expires ?? 0);          // Unix (שניות)
    const expIn = Number(j.expires_in ?? j.expiresIn ?? 0);       // משך (שניות)
    this.tokenExp = expAt > 1e9 ? expAt * 1000 : this.now() + (expIn > 0 ? expIn * 1000 : 30 * 60_000);
    this.token = tok;
    return tok;
  }

  /** קריאה ל-API. write=true → עובר דרך assertMoneyAllowed לפני כל דבר אחר. */
  async request<T = Record<string, unknown>>(method: 'GET' | 'POST', path: string, body?: unknown, write = method !== 'GET'): Promise<T> {
    if (write) assertMoneyAllowed(this.env);
    const tok = await this.accessToken();
    const r = await this.fetchFn(`${this.api}${path}`, {
      method,
      headers: { authorization: `Bearer ${tok}`, accept: 'application/json', ...(body ? { 'content-type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    const text = await r.text();
    let j: Record<string, unknown> = {};
    try { j = text ? JSON.parse(text) : {}; } catch { j = { raw: text.slice(0, 300) }; }
    // Morning מחזירה לפעמים שגיאה עסקית בתוך 2xx (success:false / errorCode)
    const errCode = Number(j.errorCode ?? 0);
    if (!r.ok || j.success === false || errCode) {
      throw new MorningError(r.status >= 500 ? 'UPSTREAM' : 'REJECTED',
        `Morning ${method} ${path}: HTTP ${r.status}${errCode ? ` errorCode ${errCode}` : ''} ${String(j.errorMessage ?? j.message ?? '').slice(0, 200)}`,
        r.status, j);
    }
    return j as T;
  }

  // ---- קריאה בלבד ----
  getDocument(id: string) { return this.request('GET', `/documents/${encodeURIComponent(id)}`); }
  documentInfo(type = 320) { return this.request('GET', `/documents/info?type=${type}`); }
  businessMe() { return this.request('GET', '/businesses/me'); }
  // חיפוש טוקנים הוא POST אבל לא מזיז כסף
  searchTokens(filter: Record<string, unknown>) { return this.request('POST', '/payments/tokens/search', filter, false); }

  // ---- פעולות כסף (חסומות עד MORNING_LIVE=1, ו-Production חסום מחוץ ל-Production) ----
  createPaymentForm(body: Record<string, unknown>) { return this.request('POST', '/payments/form', body, true); }
  chargeToken(tokenId: string, body: Record<string, unknown>) {
    return this.request('POST', `/payments/tokens/${encodeURIComponent(tokenId)}/charge`, body, true);
  }
}

// ---------------------------------------------------------------------
// בניית בקשות
// ---------------------------------------------------------------------
export const PLAN_HE: Record<string, string> = { basic: 'בסיסי', plus: 'פלוס', vip: 'VIP' };

export interface CheckoutInfo {
  id: string; userId: string; profileId: string; kind: 'initial' | 'upgrade'; plan: string; fromPlan?: string | null;
  amountAgorot: number; status: string; createdAt: string; expiresAt: string; expired: boolean; email: string | null; token?: string | null;
}

/** גוף הבקשה לדף התשלום. המחירים כוללים מע"מ, ולכן נשלח רק amount (בלי income) — Morning בונה שורה אחת. */
export function paymentFormBody(env: EnvFn, ck: CheckoutInfo, notifyUrl: string): Record<string, unknown> {
  const app = (env('HDM_APP_URL') || '').replace(/\/+$/, '');
  const plan = PLAN_HE[ck.plan] ?? ck.plan;
  return {
    description: ck.kind === 'upgrade' ? `שדרוג למסלול ${plan} — חיים דרך מספרים` : `מנוי ${plan} חודשי — חיים דרך מספרים`,
    type: 320,                 // חשבונית מס/קבלה (עוסק מורשה)
    lang: 'he',
    currency: 'ILS',
    vatType: 1,                // הסכום כולל מע"מ — לאמת ב-Sandbox שהחשבונית יוצאת בדיוק על הסכום
    amount: toShekels(ck.amountAgorot),
    maxPayments: 1,
    pluginId: env('MORNING_PLUGIN_ID') || undefined,
    group: 100,                // כרטיס אשראי (נדרש בתוסף Grow)
    client: { name: ck.email ?? 'לקוח', emails: ck.email ? [ck.email] : [], add: true },
    successUrl: `${app}/?billing=return&ck=${ck.id}`,
    failureUrl: `${app}/?billing=failed&ck=${ck.id}`,
    notifyUrl,
    custom: ck.id,
  };
}

export function notifyUrlFor(env: EnvFn, checkoutId: string): string {
  const base = (env('SUPABASE_URL') || '').replace(/\/+$/, '');
  return `${base}/functions/v1/morning-webhook?t=${encodeURIComponent(env('MORNING_WEBHOOK_TOKEN'))}&ck=${encodeURIComponent(checkoutId)}`;
}

export function tokenChargeBody(description: string, amountAgorot: number): Record<string, unknown> {
  return { type: 320, lang: 'he', currency: 'ILS', vatType: 0, amount: toShekels(amountAgorot), description, maxPayments: 1 };
}

// ---------------------------------------------------------------------
// אימות הודעת תשלום: לא סומכים על גוף ה-webhook (Morning לא חותמת עליו).
// שולפים את המסמך מחדש מ-Morning ומשווים לניסיון התשלום שבמסד.
// ---------------------------------------------------------------------
export function pickDocumentId(body: Record<string, unknown>): string {
  for (const k of ['documentId', 'document_id', 'docId', 'documentID']) {
    const v = body[k]; if (typeof v === 'string' && v) return v;
  }
  const d = body.document as Record<string, unknown> | undefined;
  if (d && typeof d.id === 'string') return d.id;
  return '';
}

export function documentAmountAgorot(doc: Record<string, unknown>): number {
  const v = doc.amount ?? doc.total ?? doc.amountTotal;
  return v === undefined || v === null ? NaN : toAgorot(v);
}

export interface VerifiedPayment {
  event: Record<string, unknown>;     // ל-hdm_billing_apply_grow_event
  bound: boolean;                     // המסמך שייך לניסיון התשלום
  problems: string[];
  clientId?: string;
}

/** מחזיר אירוע מאומת. אם המסמך אמיתי אבל לא תואם — האירוע נשלח בלי checkoutId → נרשם לבדיקה ולא מפעיל מנוי. */
export function verifyDocumentAgainstCheckout(doc: Record<string, unknown>, ck: CheckoutInfo | null): VerifiedPayment {
  const problems: string[] = [];
  const docId = String(doc.id ?? '');
  if (!docId) throw new MorningError('NO_DOCUMENT', 'המסמך לא נמצא ב-Morning');
  const amt = documentAmountAgorot(doc);
  if (Number(doc.type) !== 320 && Number(doc.type) !== 400) problems.push(`סוג מסמך ${doc.type}`);
  if (doc.currency && doc.currency !== 'ILS') problems.push(`מטבע ${doc.currency}`);
  const client = (doc.client ?? {}) as Record<string, unknown>;
  const emails = ([] as unknown[]).concat(client.emails ?? []).map((e) => String(e).toLowerCase());
  if (!ck) problems.push('אין ניסיון תשלום');
  else {
    if (ck.email && emails.length && !emails.includes(ck.email.toLowerCase())) problems.push('מייל הלקוח במסמך שונה');
    const created = Number(doc.creationDate ?? doc.createdAt ?? 0);
    if (created > 1e9 && created * 1000 < Date.parse(ck.createdAt) - 5 * 60_000) problems.push('המסמך נוצר לפני ניסיון התשלום');
    if (Number.isFinite(amt) && amt !== ck.amountAgorot) problems.push(`סכום ${amt} במקום ${ck.amountAgorot}`); // ה-DB יסמן amount_mismatch
  }
  const blocking = problems.filter((p) => !p.startsWith('סכום'));
  const bound = !!ck && blocking.length === 0;
  return {
    bound, problems,
    clientId: typeof client.id === 'string' ? client.id : undefined,
    event: {
      transactionId: `morning:${docId}`,
      kind: ck?.kind === 'upgrade' ? 'upgrade' : 'initial',
      outcome: 'approved',
      amountAgorot: Number.isFinite(amt) ? amt : -1,
      ...(bound ? { checkoutId: ck!.id } : {}),
      raw: { provider: 'morning', documentId: docId, number: doc.number ?? null, problems },
    },
  };
}

/** הטוקן של הכרטיס ששולם עכשיו (לחידושים). מחזיר null אם Morning לא שמרה טוקן. */
export async function findCardToken(m: MorningClient, clientId: string | undefined, sinceMs: number) {
  if (!clientId) return null;
  const res = await m.searchTokens({ clientId, page: 1, pageSize: 10 }) as Record<string, unknown>;
  const items = (Array.isArray(res.items) ? res.items : Array.isArray(res) ? res : []) as Record<string, unknown>[];
  const fresh = items
    .filter((t) => t && typeof t.id === 'string' && t.active !== false)
    .sort((a, b) => Number(b.creationDate ?? 0) - Number(a.creationDate ?? 0))
    .filter((t) => !t.creationDate || Number(t.creationDate) * 1000 >= sinceMs - 10 * 60_000);
  if (!fresh.length) return null;
  const t = fresh[0];
  const digits = String(t.cardNum ?? t.last4 ?? t.lastDigits ?? '').replace(/\D/g, '').slice(-4);
  return { id: String(t.id), last4: digits.length === 4 ? digits : null };
}
