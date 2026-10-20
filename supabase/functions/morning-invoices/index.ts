// חיים דרך מספרים — morning-invoices: הפקת חשבוניות ב-Morning אחרי תשלום מוצלח (Staging בלבד עד אישור).
// משימה מתוזמנת עם x-hdm-cron. כבוי עד MORNING_LIVE=1. הלוגיקה: ../_shared/morning_invoices.ts
import { supabaseDb } from '../_shared/supabase_db.ts';
import { invoicesFlow } from '../_shared/morning_invoices.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const db = supabaseDb();
Deno.serve(async (req) => {
  const r = await invoicesFlow(env, db, fetch, req.headers.get('x-hdm-cron') ?? '');
  return new Response(JSON.stringify(r.body), { status: r.status, headers: { 'content-type': 'application/json' } });
});
