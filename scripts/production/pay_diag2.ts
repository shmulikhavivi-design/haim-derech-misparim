// paydiagtwo — בדיקת Morning בקריאה בלבד: אימות OAuth, פרטי העסק (סטטוס בלבד), חיפוש לקוחות וטוקנים. אין POST שמזיז כסף או יוצר משהו.
import { MorningClient, MorningError } from '../../supabase/functions/_shared/morning.ts';
const envMap: Record<string, string> = { MORNING_API_BASE: 'https://api.greeninvoice.co.il/api/v1' };
const env = (k: string) => envMap[k] ?? Deno.env.get(k) ?? '';
const out: Record<string, unknown> = {};
const m = new MorningClient(env, fetch);
const step = async (name: string, f: () => Promise<unknown>) => {
  try { out[name] = { ok: true, data: await f() }; }
  catch (e) { out[name] = { ok: false, code: e instanceof MorningError ? e.code : 'ERR', status: e instanceof MorningError ? e.status : 0,
                            msg: e instanceof Error ? e.message.slice(0, 400) : String(e), body: e instanceof MorningError ? e.body : null }; }
};
await step('businessMe', async () => { const b = await m.businessMe() as Record<string, unknown>; return { keys: Object.keys(b), active: b.active, type: b.type, status: b.status }; });
await step('docInfo320', () => m.documentInfo(320));
await step('clientsRecent', async () => { const r = await m.searchClients({ page: 1, pageSize: 5 }) as Record<string, unknown>; return { total: r.total, n: (r.items as unknown[] | undefined)?.length }; });
await step('tokensRecent', async () => { const r = await m.searchTokens({ page: 1, pageSize: 10 }) as Record<string, unknown>;
  return { total: r.total, items: ((r.items ?? []) as Record<string, unknown>[]).map((t) => ({ status: t.status, created: t.creationDate, hasExt: !!t.externalKey })) }; });
await step('plugins', () => m.request('GET', '/plugins', undefined, false));
Deno.writeTextFileSync(Deno.args[0], JSON.stringify(out, null, 1));
