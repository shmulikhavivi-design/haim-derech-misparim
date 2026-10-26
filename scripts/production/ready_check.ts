// readycheck — Morning בקריאה בלבד: אימות, מסוף Grow פעיל עם שמירת כרטיסים, סוג מסמך 320. אין POST שיוצר/מחייב.
import { MorningClient } from '../../supabase/functions/_shared/morning.ts';
const envMap: Record<string, string> = { MORNING_API_BASE: 'https://api.greeninvoice.co.il/api/v1' };
const env = (k: string) => envMap[k] ?? Deno.env.get(k) ?? '';
const m = new MorningClient(env, fetch);
const out: string[] = [];
try { const b = await m.businessMe() as Record<string, unknown>; out.push(`Morning: אימות ✅, עסק פעיל ${b.active ? '✅' : '❌'}`); } catch (e) { out.push(`Morning: אימות ❌ ${String(e).slice(0, 120)}`); }
try {
  const p = (await m.request('GET', '/plugins', undefined, false)) as unknown as Record<string, unknown>[];
  const g = p.find((x) => x.id === '53ed9395-02de-4902-a1dd-28dd3f74a5fa');
  out.push(g ? `מסוף Grow: פעיל ${g.active ? '✅' : '❌'} | תשלומים ${g.payments ? '✅' : '❌'} | שמירת כרטיסים ${g.tokens ? '✅' : '❌'}` : 'מסוף Grow לא נמצא ❌');
} catch (e) { out.push(`מסופים ❌ ${String(e).slice(0, 120)}`); }
try { const d = await m.documentInfo(320) as Record<string, unknown>; out.push(`חשבונית מס/קבלה: ${d.type === 320 ? '✅' : '❌'}`); } catch (e) { out.push(`מסמך ❌ ${String(e).slice(0, 120)}`); }
console.log(`::notice title=rc-morning::${out.join(' | ')}`);
