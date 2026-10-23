// =====================================================================
// חיים דרך מספרים — בדיקת חיבור ל-Morning, **קריאה בלבד**.
//
// מה היא עושה: מתחברת עם MORNING_CLIENT_ID / MORNING_CLIENT_SECRET (מסודות GitHub, לא מודפסים),
// מזהה אם המפתחות שייכים ל-Production או ל-Sandbox של Morning, וקוראת:
//   GET /businesses/me           — סוג העסק (עוסק מורשה וכו')
//   GET /documents/info?type=320 — תוספי הסליקה (Grow): פעיל, מאושר לאתר (ecommerce), קבוצות, תשלומים, וכל הדגלים
// מה היא לא עושה: אין יצירת מסמך, אין דף תשלום, אין חיוב — MorningClient חוסם כתיבה (MORNING_LIVE לא מוגדר כאן).
// מספרי מסוף / מזהי סוחר לא מודפסים.
// הרצה: deno run --allow-net --allow-env scripts/morning/probe.ts
// =====================================================================
import { MorningClient, MorningError, PROD_API, SANDBOX_API } from '../../supabase/functions/_shared/morning.ts';

const EXPECTED_PLUGIN = Deno.env.get('MORNING_PLUGIN_ID') ?? '';
const out: string[] = [];
const say = (s: string) => { out.push(s); console.log(s); };
const notice = () => { if (Deno.env.get('GITHUB_ACTIONS')) console.log(`::notice title=morning-probe::${out.join('%0A').replace(/\r/g, '')}`); };

// אין MORNING_LIVE ואין HDM_ENV — כל פעולת כסף נחסמת בקוד
const base = { ...Deno.env.toObject() };
delete base.MORNING_LIVE; delete base.HDM_ENV;

let client: MorningClient | null = null, envName = '';
for (const [name, api] of [['Production', PROD_API], ['Sandbox', SANDBOX_API]] as const) {
  const env = (k: string) => (k === 'MORNING_API_BASE' ? api : base[k] ?? '');
  const m = new MorningClient(env, fetch);
  try { await m.businessMe(); client = m; envName = name; break; }
  catch (e) { say(`· ${name}: ${e instanceof MorningError ? e.code : 'error'}`); }
}
if (!client) { say('❌ המפתחות לא התקבלו לא ב-Production ולא ב-Sandbox של Morning.'); notice(); Deno.exit(1); }
say(`✅ המפתחות תקינים — שייכים ל-${envName} של Morning`);

const biz = await client.businessMe() as Record<string, unknown>;
say(`עסק: סוג ${biz.type ?? '?'} · פעיל ${biz.active ?? '?'} · מטבע ${biz.currency ?? '?'}`);

const info = await client.documentInfo(320) as Record<string, unknown>;
const plugins = (Array.isArray(info.paymentPlugins) ? info.paymentPlugins : []) as Record<string, unknown>[];
say(`תוספי סליקה: ${plugins.length}`);
const SAFE = ['active', 'payments', 'ecommerce', 'type', 'groups', 'currencies', 'maxPayments', 'tokens', 'token',
  'recurring', 'recurringPayments', 'standingOrder', 'saveCard', 'premium', 'friendlyName'];
for (const p of plugins) {
  const mine = EXPECTED_PLUGIN && p.id === EXPECTED_PLUGIN;
  const shown: Record<string, unknown> = {};
  for (const k of SAFE) if (k in p) shown[k] = p[k];
  const settings = (p.settings ?? {}) as Record<string, unknown>;
  for (const k of ['ecommerceRequested', 'website', 'tokens', 'recurring']) if (k in settings) shown[`settings.${k}`] = settings[k];
  say(`${mine ? '★ הפלאגין שקיבלתם' : '· פלאגין אחר'}: ${JSON.stringify(shown)}`);
  say(`  שדות נוספים (שמות בלבד): ${Object.keys(p).filter((k) => !SAFE.includes(k) && k !== 'settings').join(', ')}`);
  say(`  הגדרות (שמות בלבד): ${Object.keys(settings).join(', ')}`);
}
if (EXPECTED_PLUGIN && !plugins.some((p) => p.id === EXPECTED_PLUGIN)) say('⚠️ מזהה הפלאגין שקיבלתם לא נמצא בחשבון הזה.');

const summary = Deno.env.get('GITHUB_STEP_SUMMARY');
if (summary) await Deno.writeTextFile(summary, `### בדיקת Morning (קריאה בלבד)\n\n${out.map((l) => `- ${l}`).join('\n')}\n`, { append: true });
notice();
