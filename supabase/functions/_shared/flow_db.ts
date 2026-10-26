// מימוש FlowDb מול המסד (service role) — משותף ל-morning-checkout ול-hdm-billing-worker.
// deno-lint-ignore-file no-explicit-any
import { FlowDb } from './card_flow.ts';
import { CheckoutInfo } from './morning.ts';

export function makeFlowDb(admin: any, tag: string): FlowDb {
  return {
    async customerId(pid) { const { data } = await admin.from('hdm_billing_customers').select('morning_client_id').eq('profile_id', pid).maybeSingle(); return (data?.morning_client_id as string) ?? null; },
    async saveCustomer(pid, id) { const { error } = await admin.from('hdm_billing_customers').upsert({ profile_id: pid, morning_client_id: id }); if (error) throw error; },
    async profileName(pid) { const { data } = await admin.from('docs').select('data').eq('collection', 'profiles').eq('id', pid).maybeSingle(); return String(((data?.data ?? {}) as Record<string, unknown>).currentName ?? '').trim(); },
    async saveToken(pid, tok, last4) { const { error } = await admin.rpc('hdm_billing_save_token', { p_profile: pid, p_token: tok, p_last4: last4 }); if (error) throw error; },
    async claim(id, ref) { const { data, error } = await admin.rpc('hdm_billing_claim_checkout', { p_checkout: id, p_process_id: ref }); if (error) throw error; return data === true; },
    async applyEvent(ev) { const { data, error } = await admin.rpc('hdm_billing_apply_grow_event', { p: ev }); if (error) throw error; return ((data as Record<string, unknown>)?.result as string) ?? null; },
    log(msg) { console.error(`${tag}:`, msg); },
  };
}

/** ניסיונות הצטרפות שממתינים לשמירת כרטיס (בתוקף, לא נתפסו, יש לקוח Morning, אין כרטיס שמור, בני דקה ומעלה).
 *  דרך hdm_billing_pending_card_checkouts — ל-service_role אין גישה ישירה לטבלה hdm_checkouts (נמצא ב-Staging 26.10). */
export async function pendingCheckouts(admin: any, limit = 20): Promise<CheckoutInfo[]> {
  const { data, error } = await admin.rpc('hdm_billing_pending_card_checkouts', { p_limit: limit });
  if (error) throw error;
  return (Array.isArray(data) ? data : []) as CheckoutInfo[];
}
