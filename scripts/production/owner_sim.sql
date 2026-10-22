-- סימולציית חידוש וביטול על המנוי האמיתי של הבעלים — בתוך עסקה שמבוטלת תמיד. אין קריאה ל-Morning ואין חיוב.
begin;
create or replace function pg_temp.as_user(p_uid uuid, p_sql text) returns text language plpgsql as $$
declare r text; begin begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true); perform set_config('role', 'authenticated', true);
  execute p_sql into r; execute 'reset role'; return 'ok:' || coalesce(r, '');
exception when others then execute 'reset role'; return 'err:' || sqlerrm; end; end $$;
create or replace function pg_temp.as_service(p_sql text) returns text language plpgsql as $$
declare r text; begin begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true); perform set_config('role', 'service_role', true);
  execute p_sql into r; execute 'reset role'; return 'ok:' || coalesce(r, '');
exception when others then execute 'reset role'; return 'err:' || sqlerrm; end; end $$;
create temp table t_res (n serial, name text, exp text, got text, ok boolean);
create or replace function pg_temp.chk(nm text, e text, g text) returns void language sql as $$
  insert into t_res (name, exp, got, ok) values (nm, e, g, coalesce(g, '∅') like e) $$;
do $$
declare
  uid uuid := '__OID__'::uuid; pid text; s public.hdm_subscriptions%rowtype; c jsonb; e1 timestamptz; e2 timestamptz; r text;
begin
  select profile_id into pid from public.hdm_checkouts where user_id = uid and status = 'paid' order by closed_at desc nulls last limit 1;
  perform pg_temp.chk('נמצא תשלום ששולם לבעלים', 'yes', case when pid is null then 'no' else 'yes' end);
  if pid is null then return; end if;
  select * into s from public.hdm_subscriptions where profile_id = pid;
  perform pg_temp.chk('מנוי: מקור תשלום, בסיסי, פעיל, מתחדש', 'payment|basic|active|true', s.source||'|'||s.plan||'|'||s.status||'|'||s.auto_renew);
  perform pg_temp.chk('כרטיס שמור קיים', 'true', (exists (select 1 from public.hdm_billing_tokens where profile_id = pid))::text);
  perform pg_temp.chk('לפני המועד — אין חידוש', '0', (select count(*)::text from jsonb_array_elements(substr(pg_temp.as_service('select public.hdm_billing_claim_due_renewals(500)::text'),4)::jsonb) x where x->>'profileId' = pid));
  -- הגענו למועד החידוש
  e1 := s.current_period_end;
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pid;
  c := coalesce((select x from jsonb_array_elements(substr(pg_temp.as_service('select public.hdm_billing_claim_due_renewals(500)::text'),4)::jsonb) x where x->>'profileId' = pid limit 1), '{}');
  perform pg_temp.chk('במועד — נתפס חיוב חידוש אחד ב-₪29.90 עם הכרטיס השמור', '2990|true', (c->>'amountAgorot')||'|'||((c->>'token') is not null)::text);
  perform pg_temp.chk('תפיסה כפולה לאותה תקופה — לא נתפס שוב', '0', (select count(*)::text from jsonb_array_elements(substr(pg_temp.as_service('select public.hdm_billing_claim_due_renewals(500)::text'),4)::jsonb) x where x->>'profileId' = pid));
  r := pg_temp.as_service(format('select public.hdm_billing_apply_morning_renewal(%L::jsonb)::text', jsonb_build_object('chargeId', c->>'chargeId', 'transactionId', 'morning:SIMULATION-'||gen_random_uuid(), 'outcome', 'approved', 'amountAgorot', 2990)));
  perform pg_temp.chk('אישור חידוש (מדומה) — הוארך', '%renewed%', r);
  select current_period_end into e2 from public.hdm_subscriptions where profile_id = pid;
  perform pg_temp.chk('הוארך בחודש, באותו יום בחודש', 'true', (e2 > now() + interval '27 days' and e2 < now() + interval '32 days')::text);
  perform pg_temp.chk('אחרי החידוש — עדיין בסיסי', 'basic', public.hdm_plan_of(pid));
  -- הגנה מחיוב כפול: אותה תקופה שכבר חודשה לא נתפסת שוב
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pid;
  perform pg_temp.chk('אותה תקופה לא מחויבת פעמיים', '0', (select count(*)::text from jsonb_array_elements(substr(pg_temp.as_service('select public.hdm_billing_claim_due_renewals(500)::text'),4)::jsonb) x where x->>'profileId' = pid));
  -- כישלון כרטיס (תקופה אחרת: בתוך עסקה אחת השעון לא זז, ותקופה זהה נחסמת בכוונה כחיוב כפול)
  update public.hdm_subscriptions set current_period_end = now() - interval '3 minutes' where profile_id = pid;
  c := coalesce((select x from jsonb_array_elements(substr(pg_temp.as_service('select public.hdm_billing_claim_due_renewals(500)::text'),4)::jsonb) x where x->>'profileId' = pid limit 1), '{}');
  r := pg_temp.as_service(format('select public.hdm_billing_apply_morning_renewal(%L::jsonb)::text', jsonb_build_object('chargeId', c->>'chargeId', 'transactionId', 'morning-fail:SIM-'||gen_random_uuid(), 'outcome', 'failed', 'amountAgorot', 2990)));
  perform pg_temp.chk('כרטיס נדחה — לא הוארך', '%failed%', r);
  perform pg_temp.chk('אחרי כישלון — אין ניסיון נוסף לפני 48 שעות', '0', (select count(*)::text from jsonb_array_elements(substr(pg_temp.as_service('select public.hdm_billing_claim_due_renewals(500)::text'),4)::jsonb) x where x->>'profileId' = pid));
  perform pg_temp.chk('אחרי כישלון — לא יום אחד יותר מהתקופה ששולמה (חינם)', 'free', public.hdm_plan_of(pid));
  -- ביטול מנוי
  update public.hdm_subscriptions set current_period_end = now() + interval '20 days', status = 'active', failed_attempts = 0 where profile_id = pid;
  delete from public.hdm_renewal_charges where profile_id = pid;
  r := pg_temp.as_user(uid, 'select public.hdm_billing_cancel()::text');
  perform pg_temp.chk('ביטול מתוך האפליקציה מצליח', 'ok:%"canceled": true%', r);
  perform pg_temp.chk('אחרי ביטול — החידוש כבוי', 'false|canceled', (select auto_renew::text||'|'||status from public.hdm_subscriptions where profile_id = pid));
  perform pg_temp.chk('אחרי ביטול — פעיל עד סוף התקופה', 'basic', public.hdm_plan_of(pid));
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pid;
  perform pg_temp.chk('אחרי ביטול, כשמגיע המועד — לא נתפס חיוב', '0', (select count(*)::text from jsonb_array_elements(substr(pg_temp.as_service('select public.hdm_billing_claim_due_renewals(500)::text'),4)::jsonb) x where x->>'profileId' = pid));
  perform pg_temp.chk('אחרי סוף התקופה — חוזר לחינם', 'free', public.hdm_plan_of(pid));
end $$;
do $hdm$ begin
  raise exception 'HDM_SIM passed=% total=% failed=%', (select count(*) filter (where ok) from t_res), (select count(*) from t_res),
    coalesce((select string_agg(name||' ⇒ '||coalesce(got,'∅'), ' | ') from t_res where not ok), '-');
end $hdm$;
rollback;
