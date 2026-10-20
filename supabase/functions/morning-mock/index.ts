// חיים דרך מספרים — morning-mock: תחליף Morning לבדיקות, Staging בלבד (HDM_ENV=staging + MORNING_MOCK=1). הלוגיקה: ../_shared/morning_mock.ts
import { morningMockHandler } from '../_shared/morning_mock.ts';
Deno.serve((req) => morningMockHandler(req, (k) => Deno.env.get(k) ?? ''));
