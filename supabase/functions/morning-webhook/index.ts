// =====================================================================
// חיים דרך מספרים — morning-webhook (Staging בלבד עד אישור)
//
// Morning שולחת לכאן הודעה (notifyUrl) אחרי תשלום בדף התשלום. Morning **לא חותמת** על ההודעות, ולכן:
//   1. הכתובת כוללת טוקן סודי (MORNING_WEBHOOK_TOKEN) — בלעדיו: 401, בלי לגעת בכלום.
//   2. לא סומכים על גוף ההודעה: שולפים את המסמך מחדש מ-Morning (GET /documents/{id}, קריאה בלבד)
//      ומשווים לניסיון התשלום שבמסד: סוג, מטבע, מייל הלקוח, זמן יצירה וסכום.
//   3. רק אז hdm_billing_apply_grow_event. המסד מפעיל מנוי פעם אחת בלבד לכל מסמך, ומסמן לבדיקה כל אי-התאמה
//      (סכום שונה, תשלום כפול, תשלום שלא שייך לאף ניסיון) — בלי להפעיל.
//   4. אחרי הצטרפות מוצלחת: שמירת הטוקן של הכרטיס לחידושים (אם Morning שמרה טוקן).
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2';
import { CheckoutInfo, MorningClient, MorningError, findCardToken, pickCheckoutId, pickDocumentId, safeEqual, verifyDocumentAgainstCheckout, verifyMorningSignature } from '../_shared/morning.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const admin = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
const ok = (body: unknown = { ok: true }, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

function parseBody(text: string): Record<string, unknown> {
  if (!text) return {};
  try { return JSON.parse(text); } catch { /* form-urlencoded */ }
  const out: Record<string, unknown> = {};
  for (const [k, v] of new URLSearchParams(text)) out[k] = v;
  return out;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return ok({ error: 'method' }, 405);
  const u = new URL(req.url);
  const raw = await req.text();
  // שתי דרכים מותרות להיכנס: (1) notifyUrl של דף התשלום עם טוקן סודי בכתובת;
  // (2) Webhook שהוגדר בממשק Morning עם סוד — חתימת HMAC-SHA256 על הגוף (x-webhook-signature).
  const expected = env('MORNING_WEBHOOK_TOKEN');
  const byToken = !!expected && expected.length >= 32 && safeEqual(u.searchParams.get('t') ?? '', expected);
  const sig = req.headers.get('x-webhook-signature') ?? '';
  const bySig = !byToken && !!sig && await verifyMorningSignature(raw, sig, env('MORNING_WEBHOOK_SECRET'));
  if (!byToken && !bySig) return ok({ error: 'auth' }, 401);
  const topic = req.headers.get('x-webhook-topic') ?? '';
  if (bySig && topic && topic !== 'document/created') return ok({ ignored: topic });   // 2xx כדי ש-Morning לא תספור כישלון

  try {
    const body = parseBody(raw);
    const docId = pickDocumentId(body);
    if (!docId) return ok({ error: 'no_document' }, 400);
    const ckId = u.searchParams.get('ck') || pickCheckoutId(body);

    let ck: CheckoutInfo | null = null;
    if (/^[0-9a-f-]{36}$/i.test(ckId)) {
      const { data, error } = await admin.rpc('hdm_billing_checkout_lookup', { p_checkout: ckId });
      if (error) throw error;
      ck = (data as CheckoutInfo | null) ?? null;
    }

    const m = new MorningClient(env, fetch);
    const doc = await m.getDocument(docId) as Record<string, unknown>;     // מקור האמת — לא גוף ההודעה
    const v = verifyDocumentAgainstCheckout(doc, ck);
    const { data: res, error } = await admin.rpc('hdm_billing_apply_grow_event', { p: v.event });
    if (error) throw error;
    const result = (res as Record<string, unknown>)?.result;
    console.log('morning-webhook', result, v.bound ? 'bound' : 'unbound', v.problems.join('; '));

    if (result === 'started' && ck) {
      try {
        const tok = await findCardToken(m, v.clientId, Date.parse(ck.createdAt));
        if (tok) await admin.rpc('hdm_billing_save_token', { p_profile: ck.profileId, p_token: tok.id, p_last4: tok.last4 });
        else console.warn('morning-webhook: no card token found — renewals will not charge until a token exists');
      } catch (e) { console.warn('morning-webhook: token lookup failed', e instanceof Error ? e.message.slice(0, 200) : ''); }
    }
    return ok({ ok: true, result });
  } catch (e) {
    const code = e instanceof MorningError ? e.code : 'ERROR';
    console.error('morning-webhook', code, e instanceof Error ? e.message.slice(0, 300) : '');
    // 5xx → Morning תנסה שוב; הקליטה במסד בטוחה להפעלה חוזרת
    return ok({ error: code }, code === 'REJECTED' ? 400 : 500);
  }
});
