// חיים דרך מספרים — grow-mock: תחליף Grow לבדיקות, Staging בלבד (HDM_ENV=staging + GROW_MOCK=1). הלוגיקה: ../_shared/grow_mock.ts
import { mockHandler } from '../_shared/grow_mock.ts';
Deno.serve((req) => mockHandler(req, (k) => Deno.env.get(k) ?? '', fetch));
