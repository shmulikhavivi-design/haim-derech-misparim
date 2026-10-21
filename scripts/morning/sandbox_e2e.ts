// =====================================================================
// חיים דרך מספרים — בדיקת Morning מול Staging + Sandbox (בלי כסף אמיתי)
//
// חלק א (תמיד): הפונקציות שנפרסו ל-Staging — שמירה על הכניסות:
//   webhook בלי טוקן / טוקן שגוי → 401 · בלי מסמך → 400 · checkout בלי משתמש → 401 · renewals בלי סוד → 401
//   renewals עם סוד כשהסליקה כבויה → skipped (לא נתפס ולא חויב אף מנוי)
// חלק ב (רק אם יש MORNING_SANDBOX_CLIENT_ID / SECRET): חשבון ה-Sandbox של Morning בלבד —
//   אימות, תוסף סליקה, תצוגת חשבונית לכל מסלול (סכום + מע"מ), דף תשלום לכל מסלול (קישור בלבד),
//   הפקת חשבונית מס/קבלה ב-Sandbox לכל מסלול ואימות שלה מול ניסיון תשלום (כולל דחיית סכום שגוי ומייל שגוי).
// חשבון ה-Production של Morning לא בשימוש כאן בכלל: הכתובת קבועה ל-Sandbox, והקוד בודק זאת.
// לא מודפסים מפתחות, טוקנים או קישורי תשלום.
// =====================================================================
import { MorningClient, MorningError, SANDBOX_API, CheckoutInfo, incomeRow, paymentFormBody, toAgorot, verifyDocumentAgainstCheckout } from '../../supabase/functions/_shared/morning.ts';

const E = (k: string) => Deno.env.get(k) ?? '';
const REF = 'ousepgdvzammgkxkweze';
const FN = `https://${REF}.supabase.co/functions/v1`;
const out: string[] = [];
let pass = 0, fail = 0, skip = 0;
const ok = (name: string, cond: boolean, extra = '') => { cond ? pass++ : fail++; out.push(`${cond ? '✅' : '❌'} ${name}${extra ? ` — ${extra}` : ''}`); };
const skipped = (name: string, why: string) => { skip++; out.push(`⏭️ ${name} — ${why}`); };
const scrub = (s: unknown) => String(s).replace(/https?:\/\/\S+/g, '<קישור>').replace(/eyJ[\w.-]+/g, '<jwt>').slice(0, 220);

async function hit(path: string, init: RequestInit = {}) {
  const r = await fetch(`${FN}${path}`, init).catch((e) => ({ status: 0, text: async () => String(e) } as unknown as Response));
  const t = await r.text(); let j: Record<string, unknown> = {}; try { j = JSON.parse(t); } catch { j = { raw: t.slice(0, 120) }; }
  return { status: r.status, j };
}

// ---------------- חלק א: הפונקציות ב-Staging ----------------
const WT = E('MORNING_WEBHOOK_TOKEN'), CS = E('HDM_CRON_SECRET');
{
  let r = await hit('/morning-webhook', { method: 'POST', body: '{}' });
  ok('webhook בלי טוקן נחסם', r.status === 401, `HTTP ${r.status}`);
  r = await hit(`/morning-webhook?t=${'x'.repeat(64)}`, { method: 'POST', body: '{"documentId":"x"}' });
  ok('webhook עם טוקן שגוי נחסם', r.status === 401, `HTTP ${r.status}`);
  r = await hit(`/morning-webhook?t=${WT}`, { method: 'POST', body: '{}' });
  ok('webhook בלי מסמך נדחה', r.status === 400, `HTTP ${r.status}`);
  r = await hit(`/morning-webhook?t=${WT}&ck=00000000-0000-0000-0000-000000000000`, { method: 'POST', body: '{"documentId":"not-a-real-doc"}' });
  ok('webhook עם מסמך מזויף — לא מפעיל מנוי (Morning לא מאשרת את המסמך)', r.status >= 400 && r.j.result === undefined, `HTTP ${r.status} ${scrub(r.j.error ?? '')}`);
  r = await hit('/morning-checkout', { method: 'POST', body: '{}' });
  ok('checkout בלי משתמש מחובר נחסם', r.status === 401, `HTTP ${r.status}`);
  r = await hit('/morning-checkout', { method: 'GET' });
  ok('checkout מקבל רק POST', r.status === 405, `HTTP ${r.status}`);
  r = await hit('/morning-renewals', { method: 'POST' });
  ok('חידושים בלי סוד התזמון נחסמים', r.status === 401, `HTTP ${r.status}`);
  if (E('MORNING_LIVE_EXPECTED') !== '1') {
    r = await hit('/morning-renewals', { method: 'POST', headers: { 'x-hdm-cron': CS } });
    ok('חידושים כשהסליקה כבויה — אף מנוי לא נתפס ולא חויב', r.status === 200 && r.j.skipped === 'MORNING_OFF', JSON.stringify(r.j));
  }
}

// ---------------- חלק ב: Sandbox של Morning ----------------
const sid = E('MORNING_SANDBOX_CLIENT_ID'), ssec = E('MORNING_SANDBOX_CLIENT_SECRET');
const PLANS: [string, string, number][] = [['basic', 'בסיסי', 2990], ['plus', 'פלוס', 4890], ['vip', 'VIP', 7990]];
if (!sid || !ssec) {
  skipped('בדיקות Sandbox של Morning (אימות, חשבוניות, דפי תשלום)', 'MORNING_SANDBOX_CLIENT_ID / MORNING_SANDBOX_CLIENT_SECRET לא נמצאו בסביבה staging');
} else {
  const senv = (k: string) => ({ MORNING_API_BASE: SANDBOX_API, MORNING_CLIENT_ID: sid, MORNING_CLIENT_SECRET: ssec, MORNING_LIVE: '1', HDM_ENV: 'staging',
    HDM_APP_URL: 'https://haim-derech-misparim.pages.dev', SUPABASE_URL: `https://${REF}.supabase.co`, MORNING_WEBHOOK_TOKEN: 'sandbox-probe' } as Record<string, string>)[k] ?? '';
  const m = new MorningClient(senv, fetch);
  ok('הכתובת היא Sandbox בלבד', m.api === SANDBOX_API);
  let authed = false;
  try { await m.businessMe(); authed = true; ok('אימות מול Morning Sandbox', true); }
  catch (e) { ok('אימות מול Morning Sandbox', false, e instanceof MorningError ? `${e.code} HTTP ${e.status}` : scrub(e)); }

  if (authed) {
    let pluginId = '';
    try {
      const info = await m.documentInfo(320) as Record<string, unknown>;
      const plugins = (Array.isArray(info.paymentPlugins) ? info.paymentPlugins : []) as Record<string, unknown>[];
      const p = plugins.find((x) => x.active !== false && x.payments !== false) ?? plugins[0];
      pluginId = typeof p?.id === 'string' ? p.id : '';
      ok('תוסף סליקה קיים בחשבון ה-Sandbox', !!pluginId, `${plugins.length} תוספים${p ? `; tokens=${String(p.tokens)} ecommerce=${String(p.ecommerce)}` : ''}`);
    } catch (e) { ok('תוסף סליקה קיים בחשבון ה-Sandbox', false, scrub((e as Error).message)); }

    const today = new Date().toISOString().slice(0, 10);
    const email = `hdm-sandbox-${crypto.randomUUID().slice(0, 8)}@example.com`;
    for (const [plan, he, ag] of PLANS) {
      const price = ag / 100;
      // תצוגת חשבונית (לא מפיקה מסמך)
      try {
        const pv = await m.request('POST', '/documents/preview', {
          type: 320, lang: 'he', currency: 'ILS', vatType: 0, date: today, description: `מנוי ${he} חודשי — בדיקת Sandbox`,
          client: { name: 'לקוח בדיקה', emails: [], add: false }, income: [incomeRow(`מנוי ${he} חודשי`, ag)],
          payment: [{ type: 3, price, currency: 'ILS', date: today }],
        }, false) as Record<string, unknown>;
        ok(`תצוגת חשבונית ${he} ₪${price.toFixed(2)}`, typeof pv.file === 'string' && pv.file.length > 100);
      } catch (e) { ok(`תצוגת חשבונית ${he}`, false, scrub((e as Error).message)); }

      // דף תשלום (קישור בלבד, לא נפתח)
      const ck: CheckoutInfo = { id: crypto.randomUUID(), userId: 'sandbox', profileId: 'sandbox', kind: 'initial', plan, amountAgorot: ag,
        status: 'pending', createdAt: new Date(Date.now() - 60_000).toISOString(), expiresAt: '', expired: false, email };
      try {
        const body = paymentFormBody((k) => k === 'MORNING_PLUGIN_ID' ? pluginId : senv(k), ck, `${FN}/morning-webhook?ck=${ck.id}`);
        ok(`סכום דף התשלום ${he} = ₪${price.toFixed(2)}`, body.amount === price);
        const f = await m.createPaymentForm(body) as Record<string, unknown>;
        const url = typeof f.url === 'string' ? f.url : String((f.url as Record<string, string>)?.he ?? '');
        ok(`דף תשלום ${he} נוצר ב-Sandbox`, /^https:\/\//.test(url), url ? `מארח ${new URL(url).host}` : '');
      } catch (e) { ok(`דף תשלום ${he} נוצר ב-Sandbox`, false, scrub((e as Error).message)); }

      // הפקת חשבונית מס/קבלה ב-Sandbox (אין כסף — מסמך בדיקה) + אימות מול ניסיון התשלום
      try {
        const doc = await m.request('POST', '/documents', {
          type: 320, lang: 'he', currency: 'ILS', vatType: 0, date: today, description: `מנוי ${he} חודשי — חיים דרך מספרים (Sandbox)`,
          client: { name: 'לקוח בדיקה', emails: [email], add: false }, income: [incomeRow(`מנוי ${he} חודשי`, ag)],
          payment: [{ type: 3, price, currency: 'ILS', date: today }], remarks: 'בדיקת Sandbox — לא חיוב אמיתי',
        }, true) as Record<string, unknown>;
        const docId = String(doc.id ?? '');
        ok(`חשבונית ${he} הופקה ב-Sandbox`, !!docId, doc.number ? `מס' ${doc.number}` : '');
        if (docId) {
          const full = await m.getDocument(docId) as Record<string, unknown>;
          ok(`החשבונית ${he}: סכום ₪${price.toFixed(2)} כולל מע"מ`, toAgorot(full.amount) === ag, `amount=${full.amount} vat=${full.vat ?? '?'}`);
          const v = verifyDocumentAgainstCheckout(full, ck);
          ok(`אימות webhook ${he}: המסמך משויך לניסיון התשלום`, v.bound && v.event.checkoutId === ck.id, v.problems.join('; '));
          const wrongAmt = verifyDocumentAgainstCheckout(full, { ...ck, amountAgorot: ag + 100 });
          ok(`אימות webhook ${he}: סכום שגוי מסומן ולא עובר`, wrongAmt.problems.some((p) => p.startsWith('סכום')));
          const wrongMail = verifyDocumentAgainstCheckout(full, { ...ck, email: 'other@example.com' });
          ok(`אימות webhook ${he}: מסמך של לקוח אחר לא מפעיל`, !wrongMail.bound);
          const again = verifyDocumentAgainstCheckout(full, ck);
          ok(`אותו מסמך פעמיים → אותו מזהה עסקה (המסד קולט פעם אחת)`, again.event.transactionId === v.event.transactionId);
        }
      } catch (e) { ok(`חשבונית ${he} הופקה ב-Sandbox`, false, scrub((e as Error).message)); }
    }
    try {
      const t = await m.searchTokens({ page: 1, pageSize: 1 }) as Record<string, unknown>;
      ok('חיפוש כרטיסים שמורים ב-Sandbox', true, `סה"כ ${t.total ?? '?'}`);
    } catch (e) { ok('חיפוש כרטיסים שמורים ב-Sandbox', false, scrub((e as Error).message)); }
  }
}

const head = `עברו ${pass} · נכשלו ${fail} · דולגו ${skip}`;
console.log(head); out.forEach((l) => console.log(l));
if (E('GITHUB_ACTIONS')) {
  const enc = (s: string) => s.replace(/%/g, '%25').replace(/\r?\n/g, '%0A');
  console.log(`::notice title=staging-result::${enc(`e2emorning: ${head}`)}`);
  console.log(`::notice title=staging-output::${enc(out.join('\n'))}`);
}
const sum = E('GITHUB_STEP_SUMMARY');
if (sum) await Deno.writeTextFile(sum, `### Morning — Staging + Sandbox\n\n${head}\n\n${out.map((l) => `- ${l}`).join('\n')}\n`, { append: true });
Deno.exit(fail ? 1 : 0);
