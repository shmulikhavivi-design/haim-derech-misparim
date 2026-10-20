// =====================================================================
// חיים דרך מספרים — grow-checkout (Staging בלבד עד אישור). הלוגיקה: ../_shared/grow_flows.ts (checkoutFlow)
// הצטרפות → דף תשלום של Grow עם שמירת כרטיס; שדרוג → חיוב יחסי בכרטיס השמור. כבוי עד GROW_LIVE=1.
// עמוד התשלום הקיים באפליקציה לא מחובר לפונקציה הזו — יחובר רק באישור.
// =====================================================================
import { adminClient, supabaseDb } from '../_shared/supabase_db.ts';
import { checkoutFlow } from '../_shared/grow_flows.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const admin = adminClient();
const db = supabaseDb(admin);
const CORS = {
  'access-control-allow-origin': env('HDM_APP_ORIGIN') || '*',
  'access-control-allow-headers': 'authorization, content-type, apikey, x-client-info',
  'access-control-allow-methods': 'POST, OPTIONS',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });
  if (req.method !== 'POST') return new Response(JSON.stringify({ error: 'method' }), { status: 405, headers: CORS });
  const jwt = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  const { data: who } = jwt ? await admin.auth.getUser(jwt) : { data: null };
  const { checkoutId } = await req.json().catch(() => ({}));
  const r = await checkoutFlow(env, db, fetch, who?.user?.id ?? null, checkoutId);
  return new Response(JSON.stringify(r.body), { status: r.status, headers: { ...CORS, 'content-type': 'application/json' } });
});
