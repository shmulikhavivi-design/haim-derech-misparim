// =====================================================================
// אפשרות 2 (22.10): כרטיס פעם אחת → חיוב ראשון מהשרת. לוגיקה טהורה עם תלויות מוזרקות, כדי לבדוק בלי חיוב אמיתי.
// כללים: (1) מחייבים רק אחרי "תפיסה" אטומית של ניסיון התשלום — פעם אחת בלבד; (2) מפעילים רק אחרי שהחיוב אושר
// ומסמך Morning אומת; (3) תשובה לא ברורה → לא מנסים שוב; (4) נשמרים רק מזהה טוקן ו-4 ספרות.
// =====================================================================
import {
  CheckoutInfo, EnvFn, MorningClient, MorningError, PLAN_HE, assertMoneyAllowed, ensureMorningClient, findCardToken, tokenChargeBody,
  tokenLinkBody, verifyChargeDocument,
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

export async function runCardCheckout(step: 'start' | 'complete', c: CheckoutInfo, m: MorningClient, env: EnvFn, db: FlowDb): Promise<FlowResult> {
  assertMoneyAllowed(env);
  const clientId = await customerFor(m, db, c);
  let token = c.token ?? null;
  if (!token) {
    const t = await findCardToken(m, clientId, 0);
    if (t) { await db.saveToken(c.profileId, t.id, t.last4); token = t.id; }
  }
  if (!token) {
    if (step === 'complete') return { status: 202, body: { mode: 'waiting' } };
    const link = await m.createTokenLink(tokenLinkBody(env, clientId, c)) as Record<string, unknown>;
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
