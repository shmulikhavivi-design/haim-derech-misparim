// paydiagthree — קריאה בלבד: פרטי הטוקן החדש מול מזהה הלקוח במסד; הרצה יבשה של findCardToken. בלי חיוב, בלי יצירה.
import { MorningClient, findCardToken } from '../../supabase/functions/_shared/morning.ts';
const envMap: Record<string, string> = { MORNING_API_BASE: 'https://api.greeninvoice.co.il/api/v1' };
const env = (k: string) => envMap[k] ?? Deno.env.get(k) ?? '';
const m = new MorningClient(env, fetch);
const cid = Deno.env.get('CID') ?? '';
const out: Record<string, unknown> = { cidLen: cid.length };
const all = await m.searchTokens({ page: 1, pageSize: 10 }) as Record<string, unknown>;
out.tokens = ((all.items ?? []) as Record<string, unknown>[]).map((t) => ({ keys: Object.keys(t), status: t.status, created: t.creationDate,
  extEqCid: t.externalKey === cid, extLen: String(t.externalKey ?? '').length, clientId: (t.client as Record<string, unknown> | undefined)?.id === cid,
  numLen: String(t.number ?? '').length, type: t.type, expired: t.expired }));
try { out.byExt = await m.searchTokens({ externalKey: cid, page: 1, pageSize: 10 }).then((r) => ({ total: (r as Record<string, unknown>).total, n: (((r as Record<string, unknown>).items ?? []) as unknown[]).length })); } catch (e) { out.byExtErr = String(e).slice(0, 300); }
try { const t = await findCardToken(m, cid, 0); out.find = t ? { found: true, last4: !!t.last4 } : { found: false }; } catch (e) { out.findErr = String(e).slice(0, 300); }
try { const c = await m.request('GET', `/clients/${encodeURIComponent(cid)}`); const cc = c as Record<string, unknown>; out.client = { active: cc.active, emails: Array.isArray(cc.emails) ? cc.emails.length : 0, created: cc.creationDate }; } catch (e) { out.clientErr = String(e).slice(0, 300); }
Deno.writeTextFileSync(Deno.args[0], JSON.stringify(out, null, 1));
