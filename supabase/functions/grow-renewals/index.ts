// =====================================================================
// חיים דרך מספרים — grow-renewals (Staging בלבד עד אישור). הלוגיקה: ../_shared/grow_flows.ts (renewalsFlow)
// משימה מתוזמנת: אישור ביטולים + חידוש חודשי בכרטיס השמור (חיוב אחד לכל תקופה). רק עם x-hdm-cron. חיובים כבויים עד GROW_LIVE=1.
// =====================================================================
import { supabaseDb } from '../_shared/supabase_db.ts';
import { renewalsFlow } from '../_shared/grow_flows.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const db = supabaseDb();

Deno.serve(async (req) => {
  const r = await renewalsFlow(env, db, fetch, req.headers.get('x-hdm-cron') ?? '');
  return new Response(JSON.stringify(r.body), { status: r.status, headers: { 'content-type': 'application/json' } });
});
