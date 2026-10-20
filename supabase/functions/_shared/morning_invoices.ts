// =====================================================================
// חיים דרך מספרים — הפקת חשבונית מס/קבלה ב-Morning לכל תשלום מוצלח ב-Grow (מתוך תור hdm_invoice_queue, SQL 30).
// עטיפה: supabase/functions/morning-invoices. נבדק מקומית מול תחליף Morning (scripts/grow_local/e2e_test.ts).
//   * כבוי עד MORNING_LIVE=1 (כשהוא כבוי — לא נוגעים בתור בכלל). חשבון ה-Production של Morning חסום מחוץ ל-Production.
//   * המחירים כוללים מע"מ: שורת הכנסה עם vatType=1 (כולל מע"מ) — לאמת ב-Sandbox של Morning שהמסמך יוצא בדיוק על הסכום.
//   * תשובה שלילית מ-Morning = כישלון (ניסיון חוזר עד 5). אין תשובה = לא שולחים שוב (ייתכן שהופק) — לבדיקה אחרי שעה.
// =====================================================================
import { EnvFn, FetchFn, MorningClient, MorningError, assertMoneyAllowed, toShekels } from './morning.ts';
import type { Db, Out } from './grow_flows.ts';
import { safeEqual } from './grow.ts';

const PLAN_HE: Record<string, string> = { basic: 'בסיסי', plus: 'פלוס', vip: 'VIP' };
const KIND_HE: Record<string, string> = { initial: 'מנוי חודשי', renewal: 'חידוש מנוי חודשי', upgrade: 'שדרוג מסלול (יתרת התקופה)' };

export interface InvoiceJob {
  id: number; kind: string; plan: string | null; amountAgorot: number; paidAt: string;
  email: string | null; name: string | null; last4: string | null; providerRef: string | null;
}

/** תאריך התשלום לפי שעון ישראל (YYYY-MM-DD) */
export function ilDate(iso: string): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Jerusalem', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(iso));
}

export function invoiceBody(j: InvoiceJob): Record<string, unknown> {
  const sum = toShekels(j.amountAgorot);
  const desc = `${KIND_HE[j.kind] ?? 'מנוי'} — מסלול ${PLAN_HE[String(j.plan)] ?? j.plan ?? ''} — חיים דרך מספרים`.replace(/\s+/g, ' ');
  const name = (j.name || '').trim() || j.email || 'לקוח/ה';
  return {
    type: 320,                                  // חשבונית מס/קבלה (עוסק מורשה)
    lang: 'he', currency: 'ILS', vatType: 0,    // ברמת המסמך: ברירת המחדל של העסק
    description: desc,
    client: { name, emails: j.email ? [j.email] : [], add: true },
    income: [{ description: desc, quantity: 1, price: sum, currency: 'ILS', vatType: 1 }],     // 1 = המחיר כולל מע"מ
    payment: [{ type: 3, price: sum, currency: 'ILS', date: ilDate(j.paidAt), dealType: 1, numPayments: 1,
                ...(j.last4 ? { cardNum: j.last4 } : {}) }],
    remarks: j.providerRef ? `אסמכתה ב-Grow: ${j.providerRef}` : undefined,
  };
}

export async function invoicesFlow(env: EnvFn, db: Db, fetchFn: FetchFn, cronHeader: string): Promise<Out> {
  const secret = env('HDM_CRON_SECRET');
  if (!secret || secret.length < 32 || !safeEqual(cronHeader, secret)) return { status: 401, body: { error: 'auth' } };
  try { assertMoneyAllowed(env); } catch (e) {
    return { status: 200, body: { skipped: e instanceof MorningError ? e.code : 'off' } };    // כבוי: לא תופסים כלום
  }
  const { data, error } = await db.rpc('hdm_invoice_claim', { p_limit: 10 });
  if (error) return { status: 500, body: { error: 'claim' } };
  const m = new MorningClient(env, fetchFn);
  const out = { issued: 0, failed: 0, noAnswer: 0 };
  for (const j of (data ?? []) as InvoiceJob[]) {
    try {
      const doc = await m.request('POST', '/documents', invoiceBody(j), true) as Record<string, unknown>;
      const docId = String(doc.id ?? ''), num = String(doc.number ?? '');
      await db.rpc('hdm_invoice_done', { p_id: j.id, p_ok: true, p_doc_id: docId, p_doc_number: num });
      out.issued++;
    } catch (e) {
      if (e instanceof MorningError && (e.code === 'REJECTED' || e.code === 'AUTH_FAILED' || e.code === 'NO_CREDENTIALS')) {
        await db.rpc('hdm_invoice_done', { p_id: j.id, p_ok: false, p_error: e.message.slice(0, 400) });
        out.failed++;
      } else { out.noAnswer++; console.error('morning-invoices: no answer', j.id, e instanceof Error ? e.message.slice(0, 200) : ''); }
    }
  }
  return { status: 200, body: out };
}
