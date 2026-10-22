-- =====================================================================
-- חיים דרך מספרים — בדיקות ביטול המנוי (21). הכול מתבטל בסוף — לא נשמר כלום.
-- אירועי Grow ותשובות Grow מדומים בלבד (אין חיבור ל-Grow, אין חיובים, לא נשלח מייל). רץ על Staging אחרי 21.
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.hdm_cancel_requests') is null then
    raise exception 'עצירה: מנגנון ביטול המנוי (21) לא מותקן. שום דבר לא הורץ.';
  end if;
end $$;

create or replace function pg_temp.as_user(p_uid uuid, p_sql text)
returns text language plpgsql as $$
declare r text;
begin
  begin
    perform set_config('request.jwt.claims',
      case when p_uid is null then '{"role":"anon"}'
           else json_build_object('sub', p_uid, 'role', 'authenticated')::text end, true);
    perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
    perform set_config('role', case when p_uid is null then 'anon' else 'authenticated' end, true);
    execute p_sql into r;
    execute 'reset role';
    return 'ok:' || coalesce(r, '');
  exception when others then
    execute 'reset role';
    return 'err:' || sqlerrm;
  end;
end $$;

create or replace function pg_temp.as_service(p_sql text)
returns text language plpgsql as $$
declare r text;
begin
  begin
    perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
    perform set_config('role', 'service_role', true);
    execute p_sql into r;
    execute 'reset role';
    return 'ok:' || coalesce(r, '');
  exception when others then
    execute 'reset role';
    return 'err:' || sqlerrm;
  end;
end $$;

create or replace function pg_temp.ev(tx text, kind text, outcome text, amt int, ck uuid, dd text)
returns text language sql as $$
  select pg_temp.as_service(format('select public.hdm_billing_apply_grow_event(%L::jsonb)::text',
    jsonb_build_object('transactionId', tx, 'kind', kind, 'outcome', outcome, 'amountAgorot', amt,
                       'checkoutId', ck, 'directDebitId', dd)))
$$;

-- הצטרפות מדומה: ניסיון תשלום עם הסכמה + תשלום מאושר מ-Grow
create or replace function pg_temp.join_plan(u uuid, pl text, amt int, tx text, dd text)
returns text language plpgsql as $$
declare r text; ck uuid;
begin
  r := pg_temp.as_user(u, format('select public.hdm_billing_start_checkout(%L, %L, true)::text', pl, public.hdm_billing_current_terms()));
  ck := (substr(r, 4)::jsonb->>'checkoutId')::uuid;
  return pg_temp.ev(tx, 'initial', 'approved', amt, ck, dd);
end $$;

create temp table t_res (n serial, area text, name text, exp text, got text, ok boolean);
create or replace function pg_temp.chk(a text, nm text, e text, g text) returns void language sql as $$
  insert into t_res (area, name, exp, got, ok) values (a, nm, e, g, coalesce(g, '∅') like e)
$$;
grant all on t_res to service_role, authenticated, anon;

do $$
declare
  pfx text := 'cx' || substr(md5(random()::text), 1, 6);
  uA uuid := gen_random_uuid();   -- מנוי עם סדרת חיובים ב-Grow: בטיפול → כשל → אישור
  uB uuid := gen_random_uuid();   -- מנוי בלי סדרה ב-Grow: מאושר מיד
  uR uuid := gen_random_uuid();   -- ביטול בתוך 14 יום עם בקשת החזר
  uL uuid := gen_random_uuid();   -- אחרי 14 יום: אין החזר
  uM uuid := gen_random_uuid();   -- פלוס ידני (כמו 4 החשבונות הקיימים)
  pA text; pB text; pR text; pL text; pM text; r text; st jsonb; ob bigint; e1 timestamptz;
  req text := public.hdm_required_terms_version();
begin
  insert into auth.users (id, email, aud, role, created_at, raw_user_meta_data)
  select u, pfx || '_' || k || '@example.invalid', 'authenticated', 'authenticated', now(), '{}'::jsonb
    from unnest(array[uA, uB, uR, uL, uM], array['a', 'b', 'r', 'l', 'm']) as x(u, k);
  pA := substr(pg_temp.as_user(uA, 'select public.hdm_claim_profile()'), 4);
  pB := substr(pg_temp.as_user(uB, 'select public.hdm_claim_profile()'), 4);
  pR := substr(pg_temp.as_user(uR, 'select public.hdm_claim_profile()'), 4);
  pL := substr(pg_temp.as_user(uL, 'select public.hdm_claim_profile()'), 4);
  pM := substr(pg_temp.as_user(uM, 'select public.hdm_claim_profile()'), 4);
  insert into public.hdm_consents (user_id, profile_id, version, source)
  select u, p, req, 'gate' from unnest(array[uA, uB, uR, uL, uM], array[pA, pB, pR, pL, pM]) as x(u, p);
  insert into public.docs (collection, id, data)
  select 'profiles', p, jsonb_build_object('currentName', 'בודקת', 'gender', 'אישה', 'birthdate', '1990-01-01')
    from unnest(array[pA, pB, pR, pL, pM]) as p;

  -- ---- הרשאות ----
  perform pg_temp.chk('הרשאות', 'אורח לא יכול לבטל', 'err:%', pg_temp.as_user(null, 'select public.hdm_billing_cancel()::text'));
  perform pg_temp.chk('הרשאות', 'משתמש לא יכול לאשר ביטול מול Grow בעצמו', 'err:%permission denied%', pg_temp.as_user(uA, 'select public.hdm_billing_outbox_done(1, true)::text'));
  perform pg_temp.chk('הרשאות', 'משתמש לא רואה תקלות ביטול', 'err:%permission denied%', pg_temp.as_user(uA, 'select count(*)::text from public.hdm_billing_cancel_issues()'));
  perform pg_temp.chk('הרשאות', 'משתמש לא רואה תור מיילים', 'err:%permission denied%', pg_temp.as_user(uA, 'select count(*)::text from public.hdm_email_outbox_pending()'));
  perform pg_temp.chk('הרשאות', 'משתמש לא קורא בקשות ביטול', 'err:%permission denied%', pg_temp.as_user(uA, 'select count(*)::text from public.hdm_cancel_requests'));
  perform pg_temp.chk('הרשאות', 'משתמש לא קורא מיילים', 'err:%permission denied%', pg_temp.as_user(uA, 'select count(*)::text from public.hdm_email_outbox'));
  perform pg_temp.chk('הרשאות', 'משתמש לא מסמן מייל כנשלח', 'err:%permission denied%', pg_temp.as_user(uA, 'select public.hdm_email_outbox_done(1, true)::text'));

  -- ---- מנוי עם סדרת חיובים ב-Grow ----
  perform pg_temp.chk('הכנה', 'פלוס בתשלום הופעל (מדומה)', 'ok:%started%', pg_temp.join_plan(uA, 'plus', 4890, pfx || 'TA', pfx || 'DDA'));
  select current_period_end into e1 from public.hdm_subscriptions where profile_id = pA;
  st := substr(pg_temp.as_user(uA, 'select public.hdm_billing_status()::text'), 4)::jsonb;
  perform pg_temp.chk('לפני ביטול', 'יש אפשרות ביטול', 'true', st->>'canCancel');
  perform pg_temp.chk('לפני ביטול', 'הצטרפות היום — זכאי לבקש החזר (14 יום)', 'true', st->>'refundEligible');
  perform pg_temp.chk('לפני ביטול', 'אין בקשת ביטול', 'null', coalesce(st->'cancel', 'null'::jsonb)::text);

  r := pg_temp.as_user(uA, 'select public.hdm_billing_cancel()::text');
  perform pg_temp.chk('ביטול', 'הבקשה התקבלה — במצב "בטיפול" (לא "בוטל")', 'ok:%"already": false%"cancelState": "pending"%', r);
  perform pg_temp.chk('ביטול', 'החידוש נעצר מיד', 'false|canceled', (select auto_renew::text || '|' || status from public.hdm_subscriptions where profile_id = pA));
  perform pg_temp.chk('ביטול', 'הגישה לפלוס נשמרת עד סוף התקופה', 'plus', public.hdm_plan_of(pA));
  perform pg_temp.chk('ביטול', 'נרשמה בקשה מול Grow, מקושרת לבקשת הביטול', '1',
    (select count(*)::text from public.hdm_cancel_requests c join public.hdm_grow_outbox o on o.id = c.outbox_id
      where c.profile_id = pA and c.state = 'pending' and c.grow_required and o.grow_direct_debit_id = pfx || 'DDA' and o.done_at is null));
  perform pg_temp.chk('ביטול', 'מועד הבקשה ותאריך הסיום נשמרו', 'true',
    (select (requested_at is not null and active_until = e1 and user_id = uA)::text from public.hdm_cancel_requests where profile_id = pA));
  st := substr(pg_temp.as_user(uA, 'select public.hdm_billing_status()::text'), 4)::jsonb;
  perform pg_temp.chk('מצב', 'הלקוח רואה "בטיפול"', 'pending', st->'cancel'->>'state');
  perform pg_temp.chk('מצב', 'אין חיוב הבא', 'null', coalesce(st->'nextChargeAt', 'null'::jsonb)::text);
  perform pg_temp.chk('מצב', 'מוצג תאריך סיום המנוי', 'true', ((st->>'activeUntil')::timestamptz = e1 and (st->'cancel'->>'activeUntil')::timestamptz = e1)::text);
  perform pg_temp.chk('מייל', 'נכנס לתור מייל "הבקשה התקבלה"', '1', (select count(*)::text from public.hdm_email_outbox where profile_id = pA and kind = 'cancel_received'));
  perform pg_temp.chk('מייל', 'עוד אין מייל "הביטול אושר"', '0', (select count(*)::text from public.hdm_email_outbox where profile_id = pA and kind = 'cancel_confirmed'));
  perform pg_temp.chk('מייל', 'המייל: ממתין לאישור, תאריך סיום, החשבון לא נמחק', 'true',
    (select (body_text like '%ממתין לאישור סופי מספק הסליקה%' and body_text like '%' || public.hdm_fmt_date_il(e1) || '%'
             and body_text like '%לא מוחק את החשבון%' and body_text like '%שלום בודקת%')::text
       from public.hdm_email_outbox where profile_id = pA and kind = 'cancel_received'));

  -- כפילות ומניעת חיובים
  perform pg_temp.chk('כפילות', 'לחיצה שנייה — לא כופל', 'ok:%"already": true%"cancelState": "pending"%', pg_temp.as_user(uA, 'select public.hdm_billing_cancel()::text'));
  perform pg_temp.chk('כפילות', 'בקשה אחת, פעולה אחת מול Grow, מייל אחד', '1|1|1',
    (select count(*) from public.hdm_cancel_requests where profile_id = pA)::text || '|' ||
    (select count(*) from public.hdm_grow_outbox where grow_direct_debit_id = pfx || 'DDA')::text || '|' ||
    (select count(*) from public.hdm_email_outbox where profile_id = pA)::text);
  perform pg_temp.as_service(format('select public.hdm_billing_save_token(%L, %L, ''1234'')::text', pA, pfx || 'TOKEN'));
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pA;
  perform pg_temp.chk('חיובים', 'גם כשמגיע מועד החידוש — לא נתפס חיוב', 'ok:0',
    pg_temp.as_service(format('select count(*)::text from jsonb_array_elements(public.hdm_billing_claim_due_renewals(500)) x where x->>''profileId'' = %L', pA)));
  perform pg_temp.chk('חיובים', 'חיוב שמגיע מ-Grow אחרי הביטול — לא מאריך, מסומן להחזר', 'ok:%"result": "after_cancel"%"needsReview": true%',
    pg_temp.ev(pfx || 'RA', 'renewal', 'approved', 4890, null, pfx || 'DDA'));
  update public.hdm_subscriptions set current_period_end = e1 where profile_id = pA;

  -- כשל מול Grow
  select outbox_id into ob from public.hdm_cancel_requests where profile_id = pA;
  perform pg_temp.as_service(format('select public.hdm_billing_outbox_done(%s, false, ''timeout'')::text', ob));
  perform pg_temp.chk('כשל Grow', 'כשל ראשון — עדיין "בטיפול", לא לטיפול ידני', 'pending|false',
    (select state || '|' || needs_review from public.hdm_cancel_requests where profile_id = pA));
  perform pg_temp.chk('כשל Grow', 'הכשל נרשם', 'timeout|1', (select last_error || '|' || attempts from public.hdm_grow_outbox where id = ob));
  perform pg_temp.as_service(format('select public.hdm_billing_outbox_done(%s, false, ''timeout'')::text', ob));
  perform pg_temp.as_service(format('select public.hdm_billing_outbox_done(%s, false, ''503'')::text', ob));
  perform pg_temp.chk('כשל Grow', 'אחרי 3 כשלים — מסומן לטיפול ידני', 'pending|true',
    (select state || '|' || needs_review from public.hdm_cancel_requests where profile_id = pA));
  perform pg_temp.chk('כשל Grow', 'מופיע ברשימת התקלות למנהל', 'ok:1',
    pg_temp.as_service(format('select count(*)::text from public.hdm_billing_cancel_issues() where profile_id = %L and needs_review and attempts = 3', pA)));
  st := substr(pg_temp.as_user(uA, 'select public.hdm_billing_status()::text'), 4)::jsonb;
  perform pg_temp.chk('כשל Grow', 'הלקוח רואה עיכוב, לא "בוטל"', 'pending|true', (st->'cancel'->>'state') || '|' || (st->'cancel'->>'delayed'));
  perform pg_temp.chk('כשל Grow', 'עדיין אין מייל "אושר"', '0', (select count(*)::text from public.hdm_email_outbox where profile_id = pA and kind = 'cancel_confirmed'));
  perform pg_temp.chk('כשל Grow', 'החיובים חסומים גם בזמן התקלה', 'false', (select auto_renew::text from public.hdm_subscriptions where profile_id = pA));

  -- אישור מ-Grow
  perform pg_temp.as_service(format('select public.hdm_billing_outbox_done(%s, true)::text', ob));
  perform pg_temp.chk('אישור Grow', 'רק עכשיו — "בוטל" (אושר)', 'confirmed|false|true',
    (select state || '|' || needs_review || '|' || (confirmed_at is not null) from public.hdm_cancel_requests where profile_id = pA));
  perform pg_temp.chk('אישור Grow', 'הפעולה מול Grow נסגרה', 'true', (select (done_at is not null and not needs_review)::text from public.hdm_grow_outbox where id = ob));
  perform pg_temp.chk('אישור Grow', 'מייל "הביטול אושר" בתור', '1', (select count(*)::text from public.hdm_email_outbox where profile_id = pA and kind = 'cancel_confirmed'));
  perform pg_temp.chk('אישור Grow', 'נוסח המייל', 'true',
    (select (subject like 'אישור ביטול מנוי%' and body_text like '%אושר%' and body_text like '%לא יתבצעו חיובים נוספים%' and body_text like '%לא מוחק את החשבון%')::text
       from public.hdm_email_outbox where profile_id = pA and kind = 'cancel_confirmed'));
  perform pg_temp.chk('אישור Grow', 'נרשם ביומן המנוי', '1', (select count(*)::text from public.hdm_subscription_events where profile_id = pA and action = 'cancel_confirmed'));
  perform pg_temp.as_service(format('select public.hdm_billing_outbox_done(%s, true)::text', ob));
  perform pg_temp.chk('אישור Grow', 'אישור כפול — לא שולח מייל שני', '1', (select count(*)::text from public.hdm_email_outbox where profile_id = pA and kind = 'cancel_confirmed'));
  st := substr(pg_temp.as_user(uA, 'select public.hdm_billing_status()::text'), 4)::jsonb;
  perform pg_temp.chk('אישור Grow', 'הלקוח רואה "בוטל" ותאריך סיום', 'confirmed', st->'cancel'->>'state');
  perform pg_temp.chk('אישור Grow', 'עד סוף התקופה — עדיין פלוס', 'plus', public.hdm_plan_of(pA));
  perform pg_temp.chk('אישור Grow', 'אי אפשר להצטרף מחדש עד סוף התקופה', 'err:HDM_BILLING_STILL_ACTIVE%',
    pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', public.hdm_billing_current_terms())));

  -- סוף התקופה
  update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = pA;
  perform pg_temp.chk('סוף תקופה', 'חוזר למסלול החינמי', 'free', public.hdm_plan_of(pA));
  perform pg_temp.chk('סוף תקופה', 'החשבון והפרופיל נשמרים', '1|1',
    (select count(*) from public.hdm_accounts where profile_id = pA)::text || '|' ||
    (select count(*) from public.docs where collection = 'profiles' and id = pA)::text);
  perform pg_temp.chk('סוף תקופה', 'אפשר להצטרף מחדש', 'ok:%checkoutId%',
    pg_temp.as_user(uA, format('select public.hdm_billing_start_checkout(''basic'', %L, true)::text', public.hdm_billing_current_terms())));

  -- ---- בלי סדרת חיובים ב-Grow: אין מה לבטל שם, מאושר מיד ----
  perform pg_temp.join_plan(uB, 'basic', 2990, pfx || 'TB', null);
  perform pg_temp.chk('בלי סדרה', 'ביטול — מאושר מיד', 'ok:%"cancelState": "confirmed"%', pg_temp.as_user(uB, 'select public.hdm_billing_cancel()::text'));
  perform pg_temp.chk('בלי סדרה', 'לא נרשמה פעולה מול Grow', '0|false',
    (select count(*) from public.hdm_grow_outbox where profile_id = pB)::text || '|' ||
    (select grow_required::text from public.hdm_cancel_requests where profile_id = pB));
  perform pg_temp.chk('בלי סדרה', 'מייל "אושר" בלבד', 'cancel_confirmed', (select string_agg(kind, ',') from public.hdm_email_outbox where profile_id = pB));

  -- ---- בקשת החזר בתוך 14 יום ----
  perform pg_temp.join_plan(uR, 'vip', 7990, pfx || 'TR', pfx || 'DDR');
  r := pg_temp.as_user(uR, 'select public.hdm_billing_cancel(true)::text');
  perform pg_temp.chk('החזר', 'ביטול עם בקשת החזר', 'ok:%"cancelState": "pending"%"refundRequested": true%', r);
  perform pg_temp.chk('החזר', 'הבקשה פתוחה לטיפול', 'true|true|open',
    (select refund_eligible || '|' || refund_requested || '|' || refund_state from public.hdm_cancel_requests where profile_id = pR));
  perform pg_temp.chk('ביטול עסקה', 'המייל: ביטול עסקה לפי החוק, השירות הופסק, החזר לפי החוק', 'true',
    (select (body_text like '%לבטל את העסקה לפי חוק הגנת הצרכן%' and body_text like '%השירות הופסק עם הביטול%'
             and body_text like '%בניכוי התמורה עבור התקופה שבה השירות ניתן%')::text from public.hdm_email_outbox where profile_id = pR));
  perform pg_temp.chk('ביטול עסקה', 'השירות מופסק עם הביטול: המסלול חזר לחינם', 'free', public.hdm_plan_of(pR));
  perform pg_temp.chk('ביטול עסקה', 'תאריך הסיום הוא מועד הביטול', 'true',
    (select (active_until <= now() + interval '1 minute')::text from public.hdm_cancel_requests where profile_id = pR));
  perform pg_temp.chk('החזר', 'מופיע ברשימה למנהל', 'ok:1',
    pg_temp.as_service(format('select count(*)::text from public.hdm_billing_cancel_issues() where profile_id = %L and refund_state = ''open''', pR)));
  st := substr(pg_temp.as_user(uR, 'select public.hdm_billing_status()::text'), 4)::jsonb;
  perform pg_temp.chk('ביטול עסקה', 'הלקוח רואה את אישור ביטול העסקה גם אחרי שהשירות הופסק', 'true|open|false', (st->'cancel'->>'refundRequested') || '|' || (st->'cancel'->>'refundState') || '|' || (st->>'paid'));

  -- ---- אחרי 14 יום ----
  perform pg_temp.join_plan(uL, 'plus', 4890, pfx || 'TL', pfx || 'DDL');
  update public.hdm_subscriptions set period_anchor = now() - interval '20 days',
         current_period_end = public.hdm_billing_add_months(now() - interval '20 days', 1) where profile_id = pL;
  perform pg_temp.chk('14 יום', 'עברו 20 יום — אין זכאות להחזר', 'ok:false', pg_temp.as_user(uL, 'select public.hdm_billing_status()->>''refundEligible'''));
  perform pg_temp.chk('14 יום', 'בקשת החזר אחרי 14 יום — נדחית, שום דבר לא משתנה', 'err:HDM_BILLING_REFUND_WINDOW%', pg_temp.as_user(uL, 'select public.hdm_billing_cancel(true)::text'));
  perform pg_temp.chk('14 יום', 'עדיין מתחדש (הביטול לא בוצע)', 'true', (select auto_renew::text from public.hdm_subscriptions where profile_id = pL));
  perform pg_temp.chk('14 יום', 'ביטול רגיל — עובד', 'ok:%"cancelState": "pending"%"refundRequested": false%', pg_temp.as_user(uL, 'select public.hdm_billing_cancel(false)::text'));
  perform pg_temp.chk('ביטול רגיל', 'המנוי נשאר פעיל עד סוף התקופה ששולמה', 'plus', public.hdm_plan_of(pL));
  perform pg_temp.chk('ביטול רגיל', 'המייל: פעיל עד סוף התקופה, בלי חיוב נוסף, בלי החזר יחסי, זכויות החוק נשמרות', 'true',
    (select (bool_and(body_text like '%המנוי יישאר פעיל עד%' and body_text like '%ללא חיוב נוסף%' and body_text like '%אינו מזכה בהחזר יחסי%'
             and body_text like '%חוק הגנת הצרכן נשמרות%' and body_text not like '%14 יום%'))::text from public.hdm_email_outbox where profile_id = pL));

  -- ---- פלוס ידני (חשבונות קיימים) ----
  perform public.hdm_admin_set_plan(pM, 'plus', null, 'בדיקה: פלוס ללא הגבלה');
  perform pg_temp.chk('ותיקים', 'אין מנוי בתשלום לבטל', 'err:HDM_BILLING_NOTHING_TO_CANCEL%', pg_temp.as_user(uM, 'select public.hdm_billing_cancel()::text'));
  perform pg_temp.chk('ותיקים', 'נשאר פלוס, בלי בקשת ביטול', 'plus|0', public.hdm_plan_of(pM) || '|' || (select count(*) from public.hdm_cancel_requests where profile_id = pM)::text);
  perform pg_temp.chk('ותיקים', 'מצב: אין ביטול ואין החזר', 'ok:%"canCancel": false%"refundEligible": false%', pg_temp.as_user(uM, 'select public.hdm_billing_status()::text'));
  perform pg_temp.chk('בידוד', 'משתמש אחר לא רואה את הביטול שלי', 'null', coalesce(substr(pg_temp.as_user(uM, 'select public.hdm_billing_status()::text'), 4)::jsonb->'cancel', 'null'::jsonb)::text);

  -- ---- תור המיילים (פונקציית השרת) ----
  perform pg_temp.chk('תור מיילים', 'פונקציית השרת מקבלת כתובת מהחשבון', 'ok:' || pfx || '_a@example.invalid',
    pg_temp.as_service(format('select to_email from public.hdm_email_outbox_pending(500) where to_email = %L limit 1', pfx || '_a@example.invalid')));
  perform pg_temp.as_service(format('select public.hdm_email_outbox_done(%s, true)::text', (select min(id) from public.hdm_email_outbox where profile_id = pA)));
  perform pg_temp.chk('תור מיילים', 'מייל שנשלח יוצא מהתור', 'ok:1',
    pg_temp.as_service(format('select count(*)::text from public.hdm_email_outbox_pending(500) where to_email = %L', pfx || '_a@example.invalid')));
  perform pg_temp.as_service(format('select public.hdm_email_outbox_done(%s, false, ''smtp down'')::text', (select id from public.hdm_email_outbox where profile_id = pB)));
  perform pg_temp.chk('תור מיילים', 'שליחה שנכשלה נשארת בתור לניסיון נוסף', 'ok:1',
    pg_temp.as_service(format('select count(*)::text from public.hdm_email_outbox_pending(500) where to_email = %L', pfx || '_b@example.invalid')));
end $$;

select n, area as "תחום", name as "בדיקה", case when ok then '✅' else '❌ צפוי ' || exp || ' התקבל ' || coalesce(got, '∅') end as "תוצאה"
  from t_res order by n;
select 'עברו ' || count(*) filter (where ok) || ' מתוך ' || count(*) as "סיכום" from t_res;

rollback;
