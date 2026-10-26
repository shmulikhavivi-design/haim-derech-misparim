// =====================================================================
// אפשרות 2 (22.10): כרטיס פעם אחת → חיוב ראשון מהשרת. לוגיקה טהורה עם תלויות מוזרקות, כדי לבדוק בלי חיוב אמיתי.
// כללים: (1) מחייבים רק אחרי "תפיסה" אטומית של ניסיון התשלום — פעם אחת בלבד; (2) מפעילים רק אחרי שהחיוב אושר
// ומסמך Morning אומת; (3) תשובה לא ברורה → לא מנסים שוב; (4) נשמרים רק מזהה טוקן ו-4 ספרות.
// =====================================================================
import {
  CheckoutInfo, EnvFn, MorningClient, MorningError, PLAN_HE, assertMoneyAllowed, ensureMorningClient, findCardToken, tokenChargeBody,
  appBase, returnBaseFor, tokenLinkBody, verifyChargeDocument,
} from './morning.ts';

export interface FlowDb {
  customerId(profileId: string): Promise<string | null>;
  saveCustomer(profileId: string, clientId: string): Promise<void>;
  profileName(profileId: string): Promise<string>;
  saveToken(profileId: string, tokenId: string, last4: string | null): Promise<void>;
  claim(checkoutId: string, ref: string): Promise<boolean>;
  applyEvent(event: Record<string, unknown>): Promise<string | null>;
  log?(msg: string): void;
}
export interface FlowResult { status: number; body: Record<string, unknown> }

export async function customerFor(m: MorningClient, db: FlowDb, c: CheckoutInfo): Promise<string> {
  const known = await db.customerId(c.profileId);
  if (known) return known;
  const id = await ensureMorningClient(m, c.email, await db.profileName(c.profileId));
  await db.saveCustomer(c.profileId, id);
  return id;
}

export async function runCardCheckout(step: 'start' | 'complete', c: CheckoutInfo, m: MorningClient, env: EnvFn, db: FlowDb, origin?: unknown): Promise<FlowResult> {
  assertMoneyAllowed(env);
  const clientId = await customerFor(m, db, c);
  let token = c.token ?? null;
  if (!token) {
    const t = await findCardToken(m, clientId, 0);
    if (t) { await db.saveToken(c.profileId, t.id, t.last4); token = t.id; }
  }
  if (!token) {
    if (step === 'complete') return { status: 202, body: { mode: 'waiting' } };
    // חוזרים לאותה כתובת שממנה הלקוח יצא (שם הוא מחובר). אם Morning דוחה את הכתובת — פעם אחת עם HDM_APP_URL. קישור לא מחייב.
    const base = returnBaseFor(env, origin);
    let link: Record<string, unknown>;
    try {
      link = await m.createTokenLink(tokenLinkBody(env, clientId, c, base)) as Record<string, unknown>;
    } catch (e) {
      if (!(e instanceof MorningError && e.code === 'REJECTED') || base === appBase(env)) throw e;
      db.log?.(`token link rejected for return base, retrying with HDM_APP_URL: ${e.message.slice(0, 200)}`);
      link = await m.createTokenLink(tokenLinkBody(env, clientId, c)) as Record<string, unknown>;
    }
    const url = typeof link.url === 'string' ? link.url : '';
    if (!/^https:\/\//.test(url)) throw new MorningError('NO_URL', 'Morning לא החזירה קישור לשמירת כרטיס');
    return { status: 200, body: { mode: 'redirect', url } };
  }
  if (!await db.claim(c.id, `morning-charge:${c.id}`)) return { status: 202, body: { mode: 'processing' } };
  const plan = PLAN_HE[c.plan] ?? c.plan;
  const desc = c.kind === 'upgrade' ? `שדרוג למסלול ${plan} — חיים דרך מספרים` : `מנוי ${plan} חודשי — חיים דרך מספרים`;
  let event: Record<string, unknown>;
  try {
    const doc = await m.chargeToken(token, tokenChargeBody(desc, c.amountAgorot)) as Record<string, unknown>;
    event = verifyChargeDocument(doc, c).event;
  } catch (e) {
    if (e instanceof MorningError && e.code === 'REJECTED') {
      event = { transactionId: `morning-fail:${c.id}`, kind: c.kind, outcome: 'failed', amountAgorot: c.amountAgorot, checkoutId: c.id,
                raw: { provider: 'morning', flow: 'card-then-charge', error: e.message.slice(0, 300) } };
    } else {
      db.log?.(`charge without clear answer ${c.id}: ${e instanceof Error ? e.message.slice(0, 200) : ''}`);
      return { status: 202, body: { mode: 'processing' } };
    }
  }
  const result = await db.applyEvent(event);
  return { status: 200, body: { mode: event.outcome === 'approved' ? 'charged' : 'failed', result } };
}

// ---------------------------------------------------------------------
// השלמה בצד השרת (26.10): הלקוח שמר כרטיס אצל Grow ואז סגר את הדף / לא חזר / חזר בלי חיבור.
// המשימה המתוזמנת (hdm-billing-worker, כל 5 דקות) עוברת על ניסיונות ממתינים ומשלימה אותם בדיוק כמו "השלמת התשלום":
// אותה תפיסה אטומית (חיוב אחד לכל ניסיון, גם במקביל לדפדפן), הפעלה רק אחרי אישור מ-Morning ואימות המסמך.
// לא נוגעים בניסיון שפג, שכבר נתפס, שאין לו לקוח Morning (לא יוצרים לקוחות מכאן), או שנפתח לפני פחות מדקה.
// ---------------------------------------------------------------------
export interface SweepSummary { charged: number; failed: number; waiting: number; processing: number; skipped: number }
export async function sweepCardCheckouts(list: CheckoutInfo[], m: MorningClient, env: EnvFn, db: FlowDb, now = Date.now()): Promise<SweepSummary> {
  const sum: SweepSummary = { charged: 0, failed: 0, waiting: 0, processing: 0, skipped: 0 };
  assertMoneyAllowed(env);
  for (const c of list) {
    const pid = String((c as unknown as Record<string, unknown>).processId ?? '');
    const young = now - Date.parse(c.createdAt) < 60_000;
    if (!c || c.status !== 'pending' || c.expired || Date.parse(c.expiresAt) <= now || pid || c.token || young) { sum.skipped++; continue; }
    if (!await db.customerId(c.profileId)) { sum.skipped++; continue; }
    try {
      const r = await runCardCheckout('complete', c, m, env, db);
      const mode = String(r.body.mode);
      if (mode === 'charged') sum.charged++; else if (mode === 'failed') sum.failed++;
      else if (mode === 'waiting') sum.waiting++; else sum.processing++;
    } catch (e) {
      sum.processing++; db.log?.(`sweep ${c.id}: ${e instanceof Error ? e.message.slice(0, 200) : ''}`);
    }
  }
  return sum;
}
