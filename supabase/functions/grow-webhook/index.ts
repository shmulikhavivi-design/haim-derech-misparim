// =====================================================================
// חיים דרך מספרים — grow-webhook: הודעת השרת של Grow אחרי תשלום בדף התשלום (Staging בלבד עד אישור)
//
// Grow לא חותמת על ההודעות, ולכן:
//   1. הכתובת כוללת טוקן סודי (GROW_WEBHOOK_TOKEN) — בלעדיו: 401 בלי לגעת בכלום.
//   2. לא סומכים על גוף ההודעה: getTransactionInfo מול Grow (קריאה בלבד) עם transactionId + transactionToken.
//   3. hdm_billing_apply_grow_event — המנוי מופעל פעם אחת לכל עסקה; אי-התאמה (סכום, ניסיון לא קיים, כפילות) → לבדיקה, בלי להפעיל.
//   4. שמירת הכרטיס ופרטי המשלם (שם, טלפון) לחידושים.
//   5. approveTransaction — אישור קבלה ש-Grow דורשת (לא משנה את העסקה; בלעדיו Grow שולחת שוב).
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2';
import { CheckoutInfo, GrowClient, GrowError, flattenGrowForm, safeEqual, verifyGrowPayment } from '../_shared/grow.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const admin = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
const out = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'content-type': 'application/json' } });

async function readBody(req: Request): Promise<Record<string, unknown>> {
  const ct = req.headers.get('content-type') ?? '';
  if (ct.includes('multipart/form-data')) {
    const fd = await req.formData(); const o: Record<string, unknown> = {};
    for (const [k, v] of fd.entries()) if (typeof v === 'string') o[k] = v;
    return o;
  }
  const text = await req.text();
  if (!text) return {};
  try { return JSON.parse(text); } catch { /* form-urlencoded */ }
  const o: Record<string, unknown> = {};
  for (const [k, v] of new URLSearchParams(text)) o[k] = v;
  return o;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return out({ error: 'method' }, 405);
  const u = new URL(req.url);
  const expected = env('GROW_WEBHOOK_TOKEN');
  if (!expected || expected.length < 32 || !safeEqual(u.searchParams.get('t') ?? '', expected)) return out({ error: 'auth' }, 401);

  try {
    const note = flattenGrowForm(await readBody(req));
    if (!note.transactionId || !note.transactionToken) return out({ error: 'fields' }, 400);
    const ckId = u.searchParams.get('ck') || note.cField1 || '';

    let ck: CheckoutInfo | null = null;
    if (/^[0-9a-f-]{36}$/i.test(ckId)) {
      const { data, error } = await admin.rpc('hdm_billing_checkout_lookup', { p_checkout: ckId });
      if (error) throw error;
      ck = (data as CheckoutInfo | null) ?? null;
    }

    const g = new GrowClient(env, fetch);
    const info = await g.getTransactionInfo(note.transactionId, note.transactionToken);    // מקור האמת
    const v = verifyGrowPayment(note, info.data, ck);
    const { data: res, error } = await admin.rpc('hdm_billing_apply_grow_event', { p: v.event });
    if (error) throw error;
    const result = String((res as Record<string, unknown>)?.result ?? '');
    console.log('grow-webhook', result, v.bound ? 'bound' : 'unbound', v.problems.join('; '));

    if ((result === 'started' || result === 'upgraded') && ck && v.card) {
      const { error: e3 } = await admin.rpc('hdm_billing_save_grow_card', {
        p_profile: ck.profileId, p_token: v.card.token, p_last4: v.card.last4 ?? '', p_name: v.card.name ?? '',
        p_phone: v.card.phone ?? '', p_exp: v.card.exp ?? '',
      });
      if (e3) console.warn('grow-webhook: card not saved', e3.message);
      if (!v.card.phone || !v.card.name) console.warn('grow-webhook: payer name/phone missing — renewals need them');
    } else if (result === 'started' && !v.card) {
      console.warn('grow-webhook: no cardToken in update — renewals will not charge (Token permission?)');
    }

    // אישור קבלה ל-Grow (אחרי שהאירוע נשמר). כישלון כאן לא מבטל את הקליטה; Grow תשלח שוב והקליטה בטוחה לחזרה.
    try { await g.approveTransaction(note); } catch (e) { console.warn('grow-webhook: approve failed', e instanceof Error ? e.message.slice(0, 200) : ''); }
    return out({ ok: true, result });
  } catch (e) {
    const code = e instanceof GrowError ? e.code : 'ERROR';
    console.error('grow-webhook', code, e instanceof Error ? e.message.slice(0, 300) : '');
    return out({ error: code }, code === 'REJECTED' ? 400 : 500);    // 5xx → Grow שולחת שוב
  }
});
