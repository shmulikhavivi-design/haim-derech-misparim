// =====================================================================
// חיים דרך מספרים — לקוח ה-API של Grow (Meshulam), חיבור ישיר.
//
// מקור: התיעוד הרשמי developers.grow.business (נבדק 20.10.2026):
//   Sandbox:    https://sandbox.meshulam.co.il/api/light/server/1.0/
//   Production: https://secure.meshulam.co.il/api/light/server/1.0/
//   כל בקשה נשלחת מהשרת בלבד (בקשות מדפדפן נחסמות), כטופס (multipart/form-data).
//   זיהוי: userId (העסק) + pageCode (סוג התשלום, למשל אשראי). apiKey — רק אם Grow נתנה (פלטפורמה/הרשאות מיוחדות).
//   תשובה: { status: 1|0, err: { id, message } | '', data: {...} }
//
// עקרונות:
//   * המפתחות נקראים רק מסודות הפונקציה (GROW_USER_ID, GROW_PAGE_CODE, GROW_API_KEY). לא בקוד, לא בדפדפן, לא ביומן.
//   * כל פעולה שמזיזה כסף חסומה עד GROW_LIVE=1, וחשבון ה-Production של Grow חסום מחוץ ל-HDM_ENV=production.
//   * הקובץ לא תלוי ב-Deno (סביבה ו-fetch מוזרקים) — נבדק בלי רשת.
// =====================================================================

export type EnvFn = (k: string) => string;
export type FetchFn = (input: string, init?: RequestInit) => Promise<Response>;

export const GROW_SANDBOX = 'https://sandbox.meshulam.co.il/api/light/server/1.0';
export const GROW_PROD = 'https://secure.meshulam.co.il/api/light/server/1.0';

export class GrowError extends Error {
  constructor(public code: string, message: string, public status = 0, public growErr: unknown = undefined) { super(message); }
}

export function growBase(env: EnvFn): string {
  const b = (env('GROW_API_BASE') || GROW_SANDBOX).trim().replace(/\/+$/, '');
  if (b !== GROW_SANDBOX && b !== GROW_PROD) throw new GrowError('BAD_BASE', 'GROW_API_BASE לא מוכר (רק Sandbox או Production של Grow)');
  return b;
}

export function assertGrowMoneyAllowed(env: EnvFn): void {
  if (env('GROW_LIVE') !== '1') throw new GrowError('GROW_OFF', 'הסליקה כבויה (GROW_LIVE לא פעיל) — לא נשלח דבר ל-Grow');
  if (growBase(env) === GROW_PROD && env('HDM_ENV') !== 'production') {
    throw new GrowError('PRODUCTION_BLOCKED', 'חשבון ה-Production של Grow חסום מחוץ ל-Production');
  }
}

export const toAgorot = (shekels: unknown): number => Math.round(Number(shekels) * 100);
export const toShekelsStr = (agorot: number): string => (Math.round(agorot) / 100).toFixed(2);

export function safeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  let diff = ea.length ^ eb.length;
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) diff |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return diff === 0;
}

/** טלפון ישראלי בפורמט 05XXXXXXXX (Grow דורשת טלפון תקין בכל חיוב בכרטיס שמור). */
export function normalizeIlPhone(raw: unknown): string | null {
  let d = String(raw ?? '').replace(/\D/g, '');
  if (d.startsWith('972')) d = '0' + d.slice(3);
  return /^0[0-9]{8,9}$/.test(d) ? d : null;
}

/** מספר שלם יציב לכל חיוב (transactionUniqueIdentifier): אותו חיוב → אותו מספר, ולכן Grow דוחה כפילות. */
export async function uniqueIdFor(key: string): Promise<number> {
  const h = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(key)));
  const n = ((h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3]) >>> 0;
  return 100_000_000 + (n % 900_000_000);     // 9 ספרות, מתחת לגבול של int32
}

export type GrowResp = { status: number; err: { id?: number; message?: string } | string; data: Record<string, unknown> };

export class GrowClient {
  readonly base: string;
  constructor(private env: EnvFn, private fetchFn: FetchFn) { this.base = growBase(env); }

  private creds(): Record<string, string> {
    const userId = this.env('GROW_USER_ID'), pageCode = this.env('GROW_PAGE_CODE'), apiKey = this.env('GROW_API_KEY');
    if (!userId || !pageCode) throw new GrowError('NO_CREDENTIALS', 'חסרים GROW_USER_ID / GROW_PAGE_CODE בסודות הפונקציה');
    return { userId, pageCode, ...(apiKey ? { apiKey } : {}) };
  }

  /** write=true → עובר דרך assertGrowMoneyAllowed לפני כל דבר אחר. */
  async call(method: string, fields: Record<string, unknown>, write: boolean): Promise<GrowResp> {
    if (write) assertGrowMoneyAllowed(this.env);
    const fd = new FormData();
    for (const [k, v] of Object.entries({ ...this.creds(), ...fields })) if (v !== undefined && v !== null && v !== '') fd.append(k, String(v));
    const r = await this.fetchFn(`${this.base}/${method}`, { method: 'POST', body: fd });
    const text = await r.text();
    let j: GrowResp;
    try { j = JSON.parse(text); } catch { throw new GrowError('UPSTREAM', `Grow ${method}: תשובה לא קריאה (HTTP ${r.status})`, r.status); }
    if (r.status >= 500) throw new GrowError('UPSTREAM', `Grow ${method}: HTTP ${r.status}`, r.status);
    if (Number(j.status) !== 1) {
      const e = typeof j.err === 'object' ? j.err : { message: String(j.err ?? '') };
      throw new GrowError('REJECTED', `Grow ${method}: ${e.id ?? ''} ${String(e.message ?? '').slice(0, 200)}`.trim(), r.status, e);
    }
    j.data = (j.data && typeof j.data === 'object') ? j.data : {};
    return j;
  }

  // ---- פעולות כסף ----
  createPaymentProcess(f: Record<string, unknown>) { return this.call('createPaymentProcess', f, true); }
  createTransactionWithToken(f: Record<string, unknown>) { return this.call('createTransactionWithToken', f, true); }
  // ---- אישור קבלת הודעה / קריאה בלבד (לא מזיזים כסף) ----
  approveTransaction(f: Record<string, unknown>) { return this.call('approveTransaction', f, false); }
  getTransactionInfo(transactionId: string, transactionToken: string) {
    return this.call('getTransactionInfo', { transactionId, transactionToken }, false);
  }
}

// ---------------------------------------------------------------------
// בניית בקשות
// ---------------------------------------------------------------------
export const PLAN_HE: Record<string, string> = { basic: 'בסיסי', plus: 'פלוס', vip: 'VIP' };

export interface CheckoutInfo {
  id: string; userId: string; profileId: string; kind: 'initial' | 'upgrade'; plan: string; fromPlan?: string | null;
  amountAgorot: number; status: string; createdAt: string; expiresAt: string; expired: boolean; email: string | null;
  token?: string | null; processId?: string | null;
}

export function notifyUrlFor(env: EnvFn, checkoutId: string): string {
  const base = (env('SUPABASE_URL') || '').replace(/\/+$/, '');
  return `${base}/functions/v1/grow-webhook?t=${encodeURIComponent(env('GROW_WEBHOOK_TOKEN'))}&ck=${encodeURIComponent(checkoutId)}`;
}

/** דף התשלום של Grow להצטרפות: חיוב רגיל אחד + שמירת הכרטיס לחידושים. */
export function paymentProcessFields(env: EnvFn, ck: CheckoutInfo, notifyUrl: string): Record<string, unknown> {
  const app = (env('HDM_APP_URL') || '').replace(/\/+$/, '');
  const plan = PLAN_HE[ck.plan] ?? ck.plan;
  return {
    sum: toShekelsStr(ck.amountAgorot),
    description: ck.kind === 'upgrade' ? `שדרוג למסלול ${plan} - חיים דרך מספרים` : `מנוי ${plan} חודשי - חיים דרך מספרים`,
    chargeType: 1,              // חיוב רגיל
    paymentNum: 1,
    saveCardToken: 1,           // שמירת הכרטיס לחידוש החודשי (דורש הרשאת Token מ-Grow)
    successUrl: `${app}/?billing=return&ck=${ck.id}`,
    cancelUrl: `${app}/?billing=cancel&ck=${ck.id}`,
    notifyUrl,
    'pageField[email]': ck.email ?? undefined,
    cField1: ck.id,             // מזהה ניסיון התשלום — חוזר בהודעת השרת
    cField2: ck.kind,
  };
}

export async function tokenChargeFields(o: {
  token: string; agorot: number; description: string; name: string; phone: string; key: string;
  checkoutId?: string; recurringDebitId?: string | null; recurring: boolean;
}): Promise<Record<string, unknown>> {
  return {
    cardToken: o.token,
    sum: toShekelsStr(o.agorot),
    description: o.description,
    paymentType: 2,                                     // חיוב רגיל, יחיד — הסדרה מנוהלת אצלנו
    paymentNum: 1,
    'pageField[fullName]': o.name,
    'pageField[phone]': o.phone,
    transactionUniqueIdentifier: await uniqueIdFor(o.key),
    ...(o.recurring ? (o.recurringDebitId ? { recurringDebitId: o.recurringDebitId } : { isRecurringDebitPayment: 1 }) : {}),
    ...(o.checkoutId ? { cField1: o.checkoutId } : {}),
  };
}

// ---------------------------------------------------------------------
// הודעת השרת של Grow (notifyUrl): טופס. השדות יכולים להגיע שטוחים או תחת data[...].
// ---------------------------------------------------------------------
export function flattenGrowForm(body: Record<string, unknown>): Record<string, string> {
  const out: Record<string, string> = {};
  const put = (k: string, v: unknown) => { if (v !== undefined && v !== null && typeof v !== 'object') out[k] = String(v); };
  for (const [k, v] of Object.entries(body)) {
    const m = k.match(/^data\[([^\]]+)\](?:\[([^\]]+)\])?$/);
    if (m) put(m[2] ?? m[1], v);
    else if (k === 'data' && v && typeof v === 'object') for (const [k2, v2] of Object.entries(v as Record<string, unknown>)) {
      if (v2 && typeof v2 === 'object') for (const [k3, v3] of Object.entries(v2 as Record<string, unknown>)) put(k3, v3); else put(k2, v2);
    }
    else put(k, v);
  }
  return out;
}

export interface VerifiedGrowPayment {
  event: Record<string, unknown>;      // ל-hdm_billing_apply_grow_event
  bound: boolean;
  problems: string[];
  card: { token: string; last4: string | null; name: string | null; phone: string | null; exp: string | null } | null;
}

/**
 * לא סומכים על ההודעה לבד: info = תשובת getTransactionInfo מ-Grow (קריאה בלבד), עם אותו transactionId.
 * המסמך מקושר לניסיון התשלום רק אם הכול תואם; אחרת האירוע נשלח בלי checkoutId → נרשם לבדיקה ולא מפעיל מנוי.
 */
export function verifyGrowPayment(note: Record<string, string>, info: Record<string, unknown>, ck: CheckoutInfo | null): VerifiedGrowPayment {
  const problems: string[] = [];
  const txId = note.transactionId;
  if (!txId) throw new GrowError('NO_TRANSACTION', 'אין transactionId בהודעה');
  const infoTx = String(info.transactionId ?? info.transaction_id ?? txId);
  if (infoTx !== txId) problems.push('מזהה העסקה ב-Grow שונה');
  const sumAg = toAgorot(info.sum ?? note.sum);
  if (!Number.isFinite(sumAg)) problems.push('אין סכום');
  // משמעות קודי statusCode לא מוגדרת בתיעוד הפומבי — לא מנחשים. האישור הוא ש-getTransactionInfo החזירה status=1
  // לאותה עסקה (אחרת GrowClient זורק שגיאה), והסכום נבדק במסד מול ניסיון התשלום (amount_mismatch → לבדיקה).
  const st = String(info.statusCode ?? note.statusCode ?? '');
  if (!ck) problems.push('אין ניסיון תשלום');
  else if (note.cField1 && note.cField1 !== ck.id) problems.push('cField1 לא תואם');
  const bound = !!ck && problems.length === 0;
  const token = note.cardToken || String(info.cardToken ?? '');
  return {
    bound, problems,
    card: token ? {
      token,
      last4: (note.cardSuffix || String(info.cardSuffix ?? '')).replace(/\D/g, '').slice(-4) || null,
      name: (note.fullName || String(info.fullName ?? '')).trim() || null,
      phone: normalizeIlPhone(note.payerPhone || info.payerPhone),
      exp: (note.cardExp || String(info.cardExp ?? '')).replace(/\D/g, '').slice(0, 4) || null,
    } : null,
    event: {
      transactionId: `grow:${txId}`,
      kind: ck?.kind === 'upgrade' ? 'upgrade' : 'initial',
      outcome: 'approved',
      amountAgorot: Number.isFinite(sumAg) ? sumAg : -1,
      ...(bound ? { checkoutId: ck!.id } : {}),
      raw: { provider: 'grow', transactionId: txId, asmachta: note.asmachta ?? info.asmachta ?? null, statusCode: st || null, processId: note.processId ?? null, problems },
    },
  };
}
