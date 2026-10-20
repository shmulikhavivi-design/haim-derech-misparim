// =====================================================================
// חיים דרך מספרים — בדיקה מקצה לקצה מקומית של חיבור Grow. לא מתחבר לשום פרויקט ולא ל-Grow.
// הקוד של הפונקציות (grow_flows.ts) + מסד Postgres זמני עם כל שכבת המנויים (17–26) + תחליף Grow (grow_mock.ts),
// מחוברים בתוך התהליך: Grow → הודעת שרת → grow-webhook, בלי רשת. מורץ ע"י scripts/grow_local/run.sh.
// =====================================================================
import { strict as A } from 'node:assert';
import { checkoutFlow, renewalsFlow, webhookFlow, type Db } from '../../supabase/functions/_shared/grow_flows.ts';
import { mockHandler } from '../../supabase/functions/_shared/grow_mock.ts';
import { GROW_PROD } from '../../supabase/functions/_shared/grow.ts';

const PG = ['-h', Deno.env.get('PGHOST')!, '-p', Deno.env.get('PGPORT')!, '-U', 'postgres', '-d', 'stg', '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-q'];
async function psql(sql: string): Promise<string> {
  const p = new Deno.Command('psql', { args: [...PG, '-c', sql], stdout: 'piped', stderr: 'piped' });
  const o = await p.output();
  if (!o.success) throw new Error(new TextDecoder().decode(o.stderr).trim().slice(0, 400));
  return new TextDecoder().decode(o.stdout).trim();
}
const dq = (s: string) => { const t = `q${crypto.randomUUID().slice(0, 8).replace(/-/g, '')}`; return `$${t}$${s}$${t}$`; };
function lit(v: unknown): string {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  if (typeof v === 'object') return `${dq(JSON.stringify(v))}::jsonb`;
  return dq(String(v));
}
const VOID = new Set(['hdm_billing_save_grow_card', 'hdm_billing_attach_process']);
async function call(role: 'service_role' | 'authenticated', fn: string, args: Record<string, unknown> = {}, sub?: string) {
  const a = Object.entries(args).map(([k, v]) => `${k} => ${lit(v)}`).join(', ');
  const claims = JSON.stringify(sub ? { sub, role } : { role });
  const expr = VOID.has(fn) ? `public.${fn}(${a})::text` : `coalesce(to_jsonb(public.${fn}(${a}))::text, 'null')`;
  const out = await psql(`begin; select set_config('request.jwt.claims', ${dq(claims)}, true)${sub ? `, set_config('request.jwt.claim.sub', '${sub}', true)` : ''};
    set local role ${role}; select ${expr}; commit;`);
  const last = out.split('\n').pop() ?? '';
  return VOID.has(fn) || !last ? null : JSON.parse(last);
}
const db: Db = {
  async rpc(fn, args) { try { return { data: await call('service_role', fn, args), error: null }; } catch (e) { return { data: null, error: { message: String(e) } }; } },
  async subscriptionPlan(p) { return (await psql(`select plan from public.hdm_subscriptions where profile_id = '${p}'`)) || null; },
};
const asUser = (uid: string, fn: string, args: Record<string, unknown> = {}) => call('authenticated', fn, args, uid);

// ---- סביבה: Staging מדומה + תחליף Grow ----
const SB = 'https://localtest.supabase.co';
const MOCK = `${SB}/functions/v1/grow-mock`;
const rnd = () => Array.from(crypto.getRandomValues(new Uint8Array(24)), (b) => b.toString(16).padStart(2, '0')).join('');
const ENVV: Record<string, string> = {
  SUPABASE_URL: SB, HDM_ENV: 'staging', GROW_MOCK: '1', GROW_LIVE: '1', GROW_API_BASE: MOCK,
  GROW_USER_ID: 'mock-user', GROW_PAGE_CODE: 'mock-page', GROW_WEBHOOK_TOKEN: rnd(), HDM_CRON_SECRET: rnd(), GROW_MOCK_SECRET: rnd(),
  HDM_APP_URL: 'https://app.example',
};
let env = (k: string) => ENVV[k] ?? '';
const webhookHits: number[] = [];
const growCalls: string[] = [];
const net: typeof fetch = async (input, init) => {
  const url = String(input instanceof Request ? input.url : input);
  if (url.startsWith(MOCK)) { growCalls.push(url.slice(MOCK.length + 1).split('?')[0]); return mockHandler(new Request(url, init), env, net); }
  if (url.startsWith(`${SB}/functions/v1/grow-webhook`)) {
    const u = new URL(url);
    const body: Record<string, unknown> = {};
    for (const [k, v] of new URLSearchParams(String(init?.body ?? ''))) body[k] = v;
    const r = await webhookFlow(env, db, net, u.searchParams.get('t') ?? '', u.searchParams.get('ck') ?? '', body);
    webhookHits.push(r.status);
    return new Response(JSON.stringify(r.body), { status: r.status });
  }
  throw new Error(`רשת חסומה בבדיקה: ${url}`);
};
const checkout = (uid: string | null, ck: unknown) => checkoutFlow(env, db, net, uid, ck);
const renew = (h = ENVV.HDM_CRON_SECRET) => renewalsFlow(env, db, net, h);
async function pay(url: string, scenario = 'ok') {
  const r = await net(`${url}&scenario=${scenario}`, { method: 'GET' });
  return await r.json() as { webhookStatus: number; webhook: Record<string, unknown> | null; note: Record<string, string> };
}

// ---- משתמשי בדיקה (מסד זמני) ----
const terms = () => psql('select public.hdm_billing_current_terms()');
const planOf = (p: string) => psql(`select public.hdm_plan_of('${p}')`);
async function person(k: string): Promise<{ uid: string; pid: string }> {
  const uid = crypto.randomUUID();
  await psql(`insert into auth.users (id, email, aud, role, created_at, raw_user_meta_data) values ('${uid}', 'loc_${k}@example.invalid', 'authenticated', 'authenticated', now(), '{}')`);
  const pid = await asUser(uid, 'hdm_claim_profile') as string;
  await psql(`insert into public.hdm_consents (user_id, profile_id, version, source) values ('${uid}', '${pid}', public.hdm_required_terms_version(), 'gate');
              insert into public.docs (collection, id, data) values ('profiles', '${pid}', '{"currentName":"בדיקה","gender":"אישה","birthdate":"1990-01-01"}')`);
  return { uid, pid };
}
async function buy(u: { uid: string }, plan: string, scenario = 'ok') {
  const s = await asUser(u.uid, 'hdm_billing_start_checkout', { p_plan: plan, p_terms_version: await terms(), p_accept: true }) as Record<string, string>;
  const r = await checkout(u.uid, s.checkoutId);
  A.equal(r.status, 200, JSON.stringify(r.body)); A.equal(r.body.mode, 'redirect');
  return { ck: s.checkoutId, paid: await pay(String(r.body.url), scenario) };
}
const PRICE: Record<string, number> = { basic: 2990, plus: 4890, vip: 7990 };
const U: Record<string, { uid: string; pid: string }> = {};
Deno.test({ name: 'הכנה: משתמשי בדיקה', sanitizeOps: false, sanitizeResources: false, fn: async () => {
  for (const k of ['basic', 'plus', 'vip', 'bad', 'off']) U[k] = await person(k);
} });

const T = (name: string, fn: () => Promise<void>) => Deno.test({ name, fn, sanitizeOps: false, sanitizeResources: false });

T('אבטחה: הודעה בלי טוקן / טוקן שגוי → 401; checkout בלי משתמש → 401; משימה בלי סוד → 401', async () => {
  A.equal((await webhookFlow(env, db, net, '', '', { 'data[transactionId]': '1' })).status, 401);
  A.equal((await webhookFlow(env, db, net, 'x'.repeat(48), '', { 'data[transactionId]': '1' })).status, 401);
  A.equal((await checkout(null, crypto.randomUUID())).status, 401);
  A.equal((await renew('wrong'.repeat(10))).status, 401);
});

T('סליקה כבויה (GROW_LIVE לא פעיל): 503, שום פנייה ל-Grow, הניסיון לא ננעל', async () => {
  const s = await asUser(U.off.uid, 'hdm_billing_start_checkout', { p_plan: 'basic', p_terms_version: await terms(), p_accept: true }) as Record<string, string>;
  const n = growCalls.length;
  env = (k) => (k === 'GROW_LIVE' ? '' : ENVV[k] ?? '');
  try { const r = await checkout(U.off.uid, s.checkoutId); A.equal(r.status, 503); A.equal(r.body.error, 'GROW_OFF'); }
  finally { env = (k) => ENVV[k] ?? ''; }
  A.equal(growCalls.length, n);
  A.equal(await psql(`select coalesce(grow_process_id, '') from public.hdm_checkouts where id = '${s.checkoutId}'`), '');
});

T('חשבון ה-Production של Grow חסום מחוץ ל-Production — בלי פנייה', async () => {
  const s = await asUser(U.off.uid, 'hdm_billing_start_checkout', { p_plan: 'basic', p_terms_version: await terms(), p_accept: true }) as Record<string, string>;
  env = (k) => (k === 'GROW_API_BASE' ? GROW_PROD : ENVV[k] ?? '');
  try { const r = await checkout(U.off.uid, s.checkoutId); A.equal(r.body.error, 'PRODUCTION_BLOCKED'); }
  finally { env = (k) => ENVV[k] ?? ''; }
});

for (const plan of ['basic', 'plus', 'vip']) {
  T(`הצטרפות ל-${plan}: דף תשלום → הודעת Grow → אימות → מסלול פעיל, נגבה ₪${PRICE[plan] / 100}, כרטיס נשמר`, async () => {
    const u = U[plan];
    const { ck, paid } = await buy(u, plan);
    A.equal(paid.webhookStatus, 200); A.equal(paid.webhook?.result, 'started');
    A.equal(await planOf(u.pid), plan);
    A.equal(await psql(`select amount_agorot from public.hdm_payments where checkout_id = '${ck}'`), String(PRICE[plan]));
    A.equal(await psql(`select concat_ws('|', left(grow_token, 3), card_last4, payer_name, payer_phone, card_exp) from public.hdm_billing_tokens where profile_id = '${u.pid}'`),
      'CT-|4580|נועה בדיקה|0500000000|1230');
    if (plan === 'basic') {
      const again = await webhookFlow(env, db, net, ENVV.GROW_WEBHOOK_TOKEN, '', paid.note);
      A.equal(again.body.result, 'already_processed');
      A.equal((await checkout(U.plus.uid, ck)).status, 404);           // ניסיון של משתמש אחר
    }
  });
}

T('הודעה מזויפת: Grow לא מכירה את העסקה → 400, לא מופעל', async () => {
  const { ck, paid } = await buy(U.bad, 'basic', 'forged');
  A.equal(paid.webhookStatus, 400);
  A.equal(await planOf(U.bad.pid), 'free');
  await psql(`update public.hdm_checkouts set status = 'expired', closed_at = now() where id = '${ck}'`);
});

T('Grow מדווחת ₪1.00 במקום ₪29.90 → amount_mismatch, לא מופעל, מסומן לבדיקה', async () => {
  const { ck, paid } = await buy(U.bad, 'basic', 'wrongsum');
  A.equal(paid.webhook?.result, 'amount_mismatch');
  A.equal(await planOf(U.bad.pid), 'free');
  A.equal(await psql(`select needs_review from public.hdm_payments where checkout_id = '${ck}' and outcome = 'approved'`), 't');
});

T('חידוש אוטומטי: חיוב בכרטיס השמור, חודש נוסף באותו תאריך, recurringDebitId, בלי חיוב כפול', async () => {
  const p = U.basic.pid;
  await psql(`update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = '${p}'`);
  const anchor = await psql(`select period_anchor from public.hdm_subscriptions where profile_id = '${p}'`);
  const r = await renew();
  A.equal(r.status, 200); A.equal(r.body.renewed, 1, JSON.stringify(r.body));
  A.equal(await psql(`select current_period_end > now() + interval '20 days' from public.hdm_subscriptions where profile_id = '${p}'`), 't');
  A.equal(await psql(`select period_anchor from public.hdm_subscriptions where profile_id = '${p}'`), anchor);
  A.match(await psql(`select grow_direct_debit_id from public.hdm_subscriptions where profile_id = '${p}'`), /^RD-/);
  A.equal(await psql(`select amount_agorot from public.hdm_payments where profile_id = '${p}' and kind = 'renewal'`), '2990');
  await renew();
  A.equal(await psql(`select count(*) from public.hdm_renewal_charges where profile_id = '${p}'`), '1');
  // חודש שלישי: נשלח ה-recurringDebitId שנשמר
  await psql(`update public.hdm_subscriptions set current_period_end = now() - interval '2 minutes' where profile_id = '${p}'`);
  A.equal((await renew()).body.renewed, 1);
});

T('חיוב שנכשל: כרטיס נדחה → past_due, לא מוארך, אין ניסיון חוזר לפני 48 שעות', async () => {
  const p = U.plus.pid;
  await psql(`update public.hdm_billing_tokens set grow_token = 'DECLINE-x' where profile_id = '${p}';
              update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = '${p}'`);
  const pe = await psql(`select current_period_end from public.hdm_subscriptions where profile_id = '${p}'`);
  const r = await renew();
  A.equal(r.body.failed, 1, JSON.stringify(r.body));
  A.equal(await psql(`select status from public.hdm_subscriptions where profile_id = '${p}'`), 'past_due');
  A.equal(await psql(`select current_period_end from public.hdm_subscriptions where profile_id = '${p}'`), pe);
  await renew();
  A.equal(await psql(`select count(*) from public.hdm_renewal_charges where profile_id = '${p}'`), '1');
});

T('שדרוג יחסי (בסיסי → פלוס): חיוב בכרטיס השמור, מופעל מיד, תאריך החיוב לא משתנה, לחיצה כפולה לא מחייבת', async () => {
  const u = U.basic;
  await psql(`update public.hdm_subscriptions set period_anchor = now() - interval '15 days',
              current_period_end = public.hdm_billing_add_months(now() - interval '15 days', 1) where profile_id = '${u.pid}'`);
  const pe = await psql(`select current_period_end from public.hdm_subscriptions where profile_id = '${u.pid}'`);
  const q = await asUser(u.uid, 'hdm_billing_upgrade_quote', { p_plan: 'plus' }) as Record<string, number>;
  A.ok(q.chargeNowAgorot >= 800 && q.chargeNowAgorot <= 1100, String(q.chargeNowAgorot));
  const s = await asUser(u.uid, 'hdm_billing_start_upgrade', { p_plan: 'plus', p_terms_version: await terms(), p_accept: true, p_quoted_agorot: q.chargeNowAgorot }) as Record<string, string>;
  const [r1, r2] = await Promise.all([checkout(u.uid, s.checkoutId), checkout(u.uid, s.checkoutId)]);
  const results = [r1, r2].map((r) => `${r.status}:${r.body.result ?? r.body.error}`).sort();
  A.deepEqual(results, ['200:upgraded', '409:in_progress'], JSON.stringify([r1, r2]));
  A.equal(await planOf(u.pid), 'plus');
  A.equal(await psql(`select current_period_end from public.hdm_subscriptions where profile_id = '${u.pid}'`), pe);
  A.equal(await psql(`select amount_agorot from public.hdm_payments where profile_id = '${u.pid}' and kind = 'upgrade'`), String(q.chargeNowAgorot));
});

T('ביטול חידוש: "בטיפול" → אושר בשרת; גישה עד סוף התקופה; בסוף — אין חיוב, חוזר לחינם', async () => {
  const u = U.basic;
  const c = await asUser(u.uid, 'hdm_billing_cancel', { p_refund: false }) as Record<string, unknown>;
  A.equal(c.cancelState, 'pending');
  A.equal(await planOf(u.pid), 'plus');
  const r = await renew();
  A.ok(Number(r.body.cancelsConfirmed) >= 1, JSON.stringify(r.body));
  A.equal(await psql(`select state from public.hdm_cancel_requests where profile_id = '${u.pid}' order by requested_at desc limit 1`), 'confirmed');
  A.equal(await psql(`select count(*) from public.hdm_email_outbox where profile_id = '${u.pid}' and kind = 'cancel_confirmed'`), '1');
  await psql(`update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = '${u.pid}'`);
  const before = await psql(`select count(*) from public.hdm_renewal_charges where profile_id = '${u.pid}'`);
  await renew();
  A.equal(await psql(`select count(*) from public.hdm_renewal_charges where profile_id = '${u.pid}'`), before);
  A.equal(await planOf(u.pid), 'free');
});

T('ביטול עסקה לפי החוק (VIP, בתוך 14 יום): השירות מופסק, החזר לטיפול, אין חידוש', async () => {
  const u = U.vip;
  const c = await asUser(u.uid, 'hdm_billing_cancel', { p_refund: true }) as Record<string, unknown>;
  A.equal(c.refundRequested, true);
  A.equal(await planOf(u.pid), 'free');
  A.equal(await psql(`select refund_state from public.hdm_cancel_requests where profile_id = '${u.pid}'`), 'open');
  const before = await psql(`select count(*) from public.hdm_renewal_charges where profile_id = '${u.pid}'`);
  await renew();
  A.equal(await psql(`select count(*) from public.hdm_renewal_charges where profile_id = '${u.pid}'`), before);
});

T('סיכום: כל הודעות Grow התקבלו, ופניות ל-Grow רק לנקודות המותרות', async () => {
  A.ok(webhookHits.length >= 5);
  const allowed = new Set(['createPaymentProcess', 'pay', 'getTransactionInfo', 'approveTransaction', 'createTransactionWithToken']);
  A.deepEqual([...new Set(growCalls)].filter((c) => !allowed.has(c)), []);
});
