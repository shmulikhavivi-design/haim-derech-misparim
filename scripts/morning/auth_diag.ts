// =====================================================================
// חיים דרך מספרים — אבחון אימות מול Morning. **אימות בלבד**: אין מסמכים, אין חיובים, אין דפי תשלום.
// לא מדפיס את המפתחות ולא טוקנים. מדפיס רק: אורך, פורמט, רווחים/שורות נסתרים, קוד HTTP והודעת השגיאה של Morning.
// =====================================================================
const rawId = Deno.env.get('MORNING_CLIENT_ID') ?? '';
const rawSecret = Deno.env.get('MORNING_CLIENT_SECRET') ?? '';
const out: string[] = [];
const say = (s: string) => { out.push(s); console.log(s); };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function describe(name: string, v: string) {
  const t = v.trim();
  const hidden = v !== t ? ' ⚠️ יש רווח/שורה ריקה בהתחלה או בסוף' : '';
  const quotes = /^["'].*["']$/.test(t) ? ' ⚠️ עטוף במרכאות' : '';
  const inner = /\s/.test(t) ? ' ⚠️ יש רווח באמצע' : '';
  const fmt = UUID.test(t) ? 'UUID' : /^[A-Za-z0-9_\-]+$/.test(t) ? 'אותיות/ספרות' : 'תווים מיוחדים';
  say(`${name}: קיים=${v.length > 0} · אורך ${t.length} · פורמט ${fmt}${hidden}${quotes}${inner}`);
}
describe('MORNING_CLIENT_ID', rawId);
describe('MORNING_CLIENT_SECRET', rawSecret);
if (rawId.trim() && rawId.trim() === rawSecret.trim()) say('⚠️ שני הסודות זהים');

const id = rawId.trim().replace(/^["']|["']$/g, ''), secret = rawSecret.trim().replace(/^["']|["']$/g, '');
const scrub = (s: string) => {
  let r = s;
  for (const v of [id, secret]) if (v.length >= 4) r = r.split(v).join('***');
  return r.replace(/("?(access_?token|token|refresh_?token)"?\s*:\s*")[^"]+/gi, '$1***').slice(0, 300);
};

type Attempt = { label: string; url: string; init: RequestInit };
const form = (a: string, b: string) => new URLSearchParams({ grant_type: 'client_credentials', client_id: a, client_secret: b }).toString();
const attempts = (a: string, b: string, tag: string): Attempt[] => [
  { label: `${tag} · Morning OAuth (form)`, url: 'https://api.morning.co/idp/v1/oauth/token',
    init: { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' }, body: form(a, b) } },
  { label: `${tag} · Morning OAuth (Basic)`, url: 'https://api.morning.co/idp/v1/oauth/token',
    init: { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json', authorization: 'Basic ' + btoa(`${a}:${b}`) }, body: 'grant_type=client_credentials' } },
  { label: `${tag} · Green Invoice /account/token`, url: 'https://api.greeninvoice.co.il/api/v1/account/token',
    init: { method: 'POST', headers: { 'content-type': 'application/json', accept: 'application/json' }, body: JSON.stringify({ id: a, secret: b }) } },
  { label: `${tag} · Sandbox OAuth (form)`, url: 'https://api.sandbox.morning.dev/idp/v1/oauth/token',
    init: { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' }, body: form(a, b) } },
  { label: `${tag} · Sandbox /account/token`, url: 'https://sandbox.d.greeninvoice.co.il/api/v1/account/token',
    init: { method: 'POST', headers: { 'content-type': 'application/json', accept: 'application/json' }, body: JSON.stringify({ id: a, secret: b }) } },
];

let okLabel = '';
for (const [a, b, tag] of [[id, secret, 'רגיל'], [secret, id, 'הפוך']] as const) {
  for (const at of attempts(a, b, tag)) {
    try {
      const r = await fetch(at.url, at.init);
      const text = await r.text();
      let tok = false;
      try { const j = JSON.parse(text); tok = !!(j.access_token ?? j.accessToken ?? j.token); } catch { /* not json */ }
      const ok = r.ok && tok;
      say(`${ok ? '✅' : '❌'} ${at.label}: HTTP ${r.status}${ok ? ' — טוקן התקבל' : ` — ${scrub(text) || '(גוף ריק)'}`}`);
      if (ok && !okLabel) okLabel = at.label;
    } catch (e) { say(`❌ ${at.label}: שגיאת רשת ${(e as Error).name}`); }
  }
  if (okLabel) break;
}
say(okLabel ? `סיכום: האימות הצליח דרך "${okLabel}".` : 'סיכום: האימות נכשל בכל הדרכים.');

const summary = Deno.env.get('GITHUB_STEP_SUMMARY');
if (summary) await Deno.writeTextFile(summary, `### אבחון אימות Morning\n\n${out.map((l) => `- ${l}`).join('\n')}\n`, { append: true });
if (Deno.env.get('GITHUB_ACTIONS')) console.log(`::notice title=morning-auth::${out.join('%0A')}`);
