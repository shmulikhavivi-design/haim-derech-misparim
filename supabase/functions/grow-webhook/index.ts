// =====================================================================
// חיים דרך מספרים — grow-webhook (Staging בלבד עד אישור). הלוגיקה: ../_shared/grow_flows.ts (webhookFlow)
// Grow לא חותמת על ההודעות: טוקן סודי בכתובת + getTransactionInfo מול Grow לפני כל הפעלה; אחר כך approveTransaction.
// =====================================================================
import { supabaseDb } from '../_shared/supabase_db.ts';
import { readGrowBody, webhookFlow } from '../_shared/grow_flows.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const db = supabaseDb();

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response(JSON.stringify({ error: 'method' }), { status: 405 });
  const u = new URL(req.url);
  const r = await webhookFlow(env, db, fetch, u.searchParams.get('t') ?? '', u.searchParams.get('ck') ?? '', await readGrowBody(req));
  return new Response(JSON.stringify(r.body), { status: r.status, headers: { 'content-type': 'application/json' } });
});
