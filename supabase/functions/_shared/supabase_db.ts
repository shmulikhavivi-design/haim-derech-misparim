// עטיפת supabase-js (service_role) לממשק Db של grow_flows.ts
import { createClient } from 'npm:@supabase/supabase-js@2';
import type { Db } from './grow_flows.ts';

export function adminClient() {
  const env = (k: string) => Deno.env.get(k) ?? '';
  return createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
}
export function supabaseDb(admin = adminClient()): Db {
  return {
    async rpc(fn, args) { const { data, error } = await admin.rpc(fn, args ?? {}); return { data, error: error ? { message: error.message } : null }; },
    async subscriptionPlan(profileId) {
      const { data } = await admin.from('hdm_subscriptions').select('plan').eq('profile_id', profileId).maybeSingle();
      return (data?.plan as string | undefined) ?? null;
    },
  };
}
