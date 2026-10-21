// =====================================================================
// חיים דרך מספרים — בדיקות Morning בלי חיוב ובלי הפקת מסמך:
//   1. תצוגה מקדימה של חשבונית (documents/preview) — לא מפיקה מסמך, רק PDF לבדיקת סכום ומע"מ.
//   2. יצירת דף תשלום (payments/form) — רק קישור; לא נפתח ולא משולם, ולכן אין חיוב.
//   3. חיפוש כרטיסים שמורים (payments/tokens/search) — קריאה בלבד.
// לא מודפסים מפתחות, טוקנים, מספרי מסוף או פרטי לקוח.
// =====================================================================
import { execFileSync } from 'node:child_process';
import { writeFileSync, appendFileSync } from 'node:fs';

const out = [];
const say = (s) => { out.push(s); if (!process.env.GITHUB_ACTIONS) console.log(s); };
const flush = () => { if (process.env.GITHUB_ACTIONS && out.length) console.log(`::notice title=morning-nocharge::${out.join('\n').replace(/%/g, '%25').replace(/\r?\n/g, '%0A')}`); };
const crash = (e) => { say(`קריסת הסקריפט: ${e && e.name} ${e && e.message ? String(e.message).slice(0, 120) : ''}`); flush(); process.exit(0); };
process.on('uncaughtException', crash); process.on('unhandledRejection', crash);

const rawId = (process.env.MORNING_CLIENT_ID ?? '').trim();
const id = rawId.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i)?.[0] ?? rawId;
const secret = (process.env.MORNING_CLIENT_SECRET ?? '').trim();
const API = 'https://api.greeninvoice.co.il/api/v1';
const scrub = (s) => String(s).replace(/https?:\/\/\S+/g, '<קישור>').replace(/\b\d{6,}\b/g, '<מספר>').slice(0, 400);

const tr = await fetch('https://api.morning.co/idp/v1/oauth/token', {
  method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' },
  body: new URLSearchParams({ grant_type: 'client_credentials', client_id: id, client_secret: secret }).toString(),
});
const tj = await tr.json().catch(() => ({}));
const tok = tj.access_token ?? tj.accessToken ?? tj.token;
if (!tok) { say(`❌ אימות נכשל: HTTP ${tr.status}`); flush(); process.exit(0); }
say('✅ אימות: הצליח');
const call = async (method, path, body) => {
  const r = await fetch(API + path, { method, headers: { authorization: `Bearer ${tok}`, 'content-type': 'application/json', accept: 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  const text = await r.text(); let j = null; try { j = JSON.parse(text); } catch { /* */ }
  return { status: r.status, j, text };
};

// ---- 1. תצוגה מקדימה של חשבונית מס/קבלה לכל מסלול, בשני סוגי מע"מ ----
const today = new Date().toISOString().slice(0, 10);
const plans = [['בסיסי', 29.90], ['פלוס', 48.90], ['VIP', 79.90]];
for (const [plan, price] of (process.env.SKIP_PREVIEW ? [] : plans)) {
  for (const [vatType, rowVat] of [[0, 1], [0, 2]]) {
    const body = {
      type: 320, lang: 'he', currency: 'ILS', vatType, date: today,
      description: `מנוי ${plan} חודשי — חיים דרך מספרים (תצוגה מקדימה בלבד)`,
      client: { name: 'לקוח בדיקה', emails: [], add: false },
      income: [{ description: `מנוי ${plan} חודשי`, quantity: 1, price, currency: 'ILS', vatType: rowVat }],
      payment: [{ type: 3, price, currency: 'ILS', date: today }],
    };
    const r = await call('POST', '/documents/preview', body);
    const file = r.j?.file;
    if (r.status !== 200 || !file) { say(`❌ תצוגת חשבונית ${plan} (מסמך ${vatType}, שורה ${rowVat}): HTTP ${r.status} — ${scrub(r.j?.errorMessage ?? r.text)}`); continue; }
    let lines = '';
    try {
      writeFileSync('/tmp/preview.pdf', Buffer.from(file, 'base64'));
      const txt = execFileSync('pdftotext', ['-layout', '/tmp/preview.pdf', '-'], { encoding: 'utf8' });
      lines = txt.split('\n').map((l) => l.trim()).filter((l) => /מע"?מ|סה"?כ|לתשלום|פטור|17|18%|₪/.test(l) && !/@|טל|ח\.?פ|עוסק|רחוב|קיסריה/.test(l)).slice(0, 6).join(' | ');
    } catch (e) { lines = `(לא ניתן לקרוא PDF: ${e.name})`; }
    say(`✅ תצוגת חשבונית ${plan} ${price} (מסמך ${vatType}, שורה ${rowVat}): ${scrub(lines) || '(אין שורות סכום)'}`);
  }
}

{ const r = await call('GET', '/businesses/me'); const b = r.j ?? {}; say(`עסק ב-Morning (שדות מע"מ בלבד): ${JSON.stringify(Object.fromEntries(Object.entries(b).filter(([k]) => /type|vat|exempt|tax/i.test(k) && !/id$/i.test(k))))}`); }
if (process.env.SKIP_FORM) { flush(); process.exit(0); }
// ---- 2. יצירת דף תשלום (קישור בלבד — לא נפתח, לא משולם) ----
{
  const body = {
    description: 'בדיקת חיבור — חיים דרך מספרים (לא לתשלום)', type: 320, lang: 'he', currency: 'ILS', vatType: 0,
    amount: 29.90, maxPayments: 1,
    income: [{ description: 'מנוי בסיסי חודשי', quantity: 1, price: 29.90, currency: 'ILS', vatType: 1 }], pluginId: process.env.MORNING_PLUGIN_ID || undefined, group: 100,
    client: { name: 'לקוח בדיקה', emails: [], add: false },
    successUrl: 'https://haim-derech-misparim.pages.dev/?billing=return&ck=probe',
    failureUrl: 'https://haim-derech-misparim.pages.dev/?billing=failed&ck=probe',
    notifyUrl: 'https://ousepgdvzammgkxkweze.supabase.co/functions/v1/morning-webhook?ck=probe',
    custom: 'probe-nocharge',
  };
  const r = await call('POST', '/payments/form', body);
  const url = typeof r.j?.url === 'string' ? r.j.url : r.j?.url?.he;
  say((r.status === 200 || r.status === 201) && url ? `✅ דף תשלום נוצר (קישור לא נפתח ולא שולם): מארח ${new URL(url).host}` : `❌ דף תשלום: HTTP ${r.status} — ${scrub(r.j?.errorMessage ?? r.text)}`);
  if (r.j && typeof r.j === 'object') say(`  שדות בתשובה (שמות בלבד): ${Object.keys(r.j).join(', ')}`);
}

// ---- 3. כרטיסים שמורים (קריאה בלבד) ----
{
  const r = await call('POST', '/payments/tokens/search', { page: 1, pageSize: 1 });
  say(r.status === 200 ? `✅ חיפוש כרטיסים שמורים: עובד · סה"כ שמורים ${r.j?.total ?? (r.j?.items?.length ?? '?')}` : `❌ חיפוש כרטיסים שמורים: HTTP ${r.status} — ${scrub(r.j?.errorMessage ?? r.text)}`);
}

const summary = process.env.GITHUB_STEP_SUMMARY;
if (summary) appendFileSync(summary, `### בדיקות Morning בלי חיוב\n\n${out.map((l) => `- ${l}`).join('\n')}\n`);
flush();
