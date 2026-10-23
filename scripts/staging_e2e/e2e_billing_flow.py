# =====================================================================
# חיים דרך מספרים — בדיקת זרימה מקצה לקצה מול הפונקציות החיות ב-Staging (בלי Morning ובלי חיוב):
#   1. מנוי מופעל רק אחרי אישור תשלום מהשרת: משתמש לא יכול להפעיל בעצמו, webhook מזויף / בלי טוקן / חזרה מהדף — לא מפעילים
#   2. פרטי כרטיס לא נשמרים: אין עמודות כרטיס במסד, נשמרים רק מזהה טוקן של Morning ו-4 ספרות
#   3. ביטול מפסיק את החידוש: מנוי שבוטל לא נתפס לחיוב גם כשהגיע מועדו (ומנוי שלא בוטל — כן)
# משתמשי בדיקה זמניים (כתובת האפליקציה + כינוי) — נמחקים בסוף, גם בכישלון.
# =====================================================================
import json, os, random, string, subprocess, sys, uuid, urllib.request, urllib.error

DB = os.environ['STAGING_DB_URL']; KEY = os.environ['STAGING_PUBLISHABLE_KEY']
WT = os.environ['MORNING_WEBHOOK_TOKEN']; CS = os.environ['HDM_CRON_SECRET']
BASE = 'https://ousepgdvzammgkxkweze.supabase.co'
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'flw{RUN}_'; MAIL = f'life.through.numbers333+hdm-flw-{RUN}-'
PW = 'Flw-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(20))
IDS = {k: PFX + k for k in ('a', 'b')}
IDS_SQL = "array[" + ",".join(f"'{v}'" for v in IDS.values()) + "]"

def sql(q):
    r = subprocess.run(['psql', DB, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q], capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError('sql: ' + r.stderr.strip()[:200])
    return r.stdout.strip()
def http(method, path, body=None, headers=None):
    h = {'apikey': KEY, 'content-type': 'application/json'}; h.update(headers or {})
    req = urllib.request.Request(BASE + path, data=None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode()), method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r: t = r.read().decode(); code = r.status
    except urllib.error.HTTPError as e: t = e.read().decode(); code = e.code
    try: return code, json.loads(t) if t else None
    except Exception: return code, t
results = []
def check(name, ok, got=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {str(got)[:240]}'), flush=True)

CRYPT = 'extensions.crypt' if sql("select count(*) from pg_proc where proname='crypt' and pronamespace='extensions'::regnamespace") != '0' else 'crypt'
SALT = CRYPT.replace('crypt', 'gen_salt')
def cleanup():
    sql(f"""begin;
      delete from public.hdm_renewal_charges where profile_id = any({IDS_SQL});
      delete from public.hdm_billing_tokens where profile_id = any({IDS_SQL});
      delete from public.hdm_payments where profile_id = any({IDS_SQL}) or grow_transaction_id like 'morning:{PFX}%';
      delete from public.hdm_email_outbox where profile_id = any({IDS_SQL});
      delete from public.hdm_cancel_requests where profile_id = any({IDS_SQL});
      delete from public.hdm_grow_outbox where profile_id = any({IDS_SQL});
      delete from public.hdm_checkouts where profile_id = any({IDS_SQL});
      delete from public.hdm_subscription_events where profile_id = any({IDS_SQL});
      delete from public.hdm_subscriptions where profile_id = any({IDS_SQL});
      delete from public.docs where collection = 'profiles' and id = any({IDS_SQL});
      delete from public.hdm_accounts where profile_id = any({IDS_SQL});
      delete from auth.users where email like '{MAIL}%@gmail.com';
      commit;""")
    return sql(f"select (select count(*) from auth.users where email like '{MAIL}%') + (select count(*) from public.hdm_checkouts where profile_id like '{PFX}%') + (select count(*) from public.hdm_payments where profile_id like '{PFX}%') + (select count(*) from public.hdm_subscriptions where profile_id like '{PFX}%')")
def create(k):
    consent = sql("select public.hdm_required_terms_version()")
    pid, email = IDS[k], f'{MAIL}{k}@gmail.com'
    profile = json.dumps({'currentName': 'בדיקה', 'birthdate': '1990-01-01', 'birthFirstName': 'א', 'birthLastName': 'ב', 'gender': 'אישה',
                          'lookingFor': 'גברים', 'location': 'חיפה', 'photoUrl': 'data:image/png;base64,iVBORw0KGgo=', 'createdAt': 0}, ensure_ascii=False)
    sql(f"""begin;
      with u as (
        insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                                created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
        values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', '{email}', {CRYPT}('{PW}', {SALT}('bf')), now(),
                '{{"provider":"email","providers":["email"]}}', '{{}}', now(), now(), '', '', '', '') returning id)
      , i as (insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
              select gen_random_uuid(), u.id::text, u.id, jsonb_build_object('sub', u.id::text, 'email', '{email}', 'email_verified', true), 'email', now(), now(), now() from u)
      , a as (insert into public.hdm_accounts (auth_user_id, profile_id) select id, '{pid}' from u)
      insert into public.hdm_consents (user_id, profile_id, version, source) select id, '{pid}', '{consent}', 'signup' from u;
      insert into public.docs (collection, id, data) values ('profiles', '{pid}', $j${profile}$j$::jsonb);
      commit;""")
    code, j = http('POST', '/auth/v1/token?grant_type=password', {'email': email, 'password': PW})
    if code != 200: raise RuntimeError(f'login {k}: {code}')
    return j['access_token']
rpc = lambda jwt, fn, args: http('POST', f'/rest/v1/rpc/{fn}', args, {'authorization': f'Bearer {jwt}'})
plan_of = lambda k: sql(f"select public.hdm_plan_of('{IDS[k]}')")

print(f'ריצה {RUN}', flush=True)
code_exit = 1
try:
    ja, jb = create('a'), create('b')
    terms = sql("select public.hdm_billing_current_terms()")

    # ---------- 1. הפעלה רק אחרי אישור תשלום מהשרת ----------
    c, r = rpc(ja, 'hdm_billing_start_checkout', {'p_plan': 'basic', 'p_terms_version': terms, 'p_accept': True})
    ck = (r or {}).get('checkoutId') if isinstance(r, dict) else None
    check('משתמש פותח ניסיון תשלום (בסיסי ₪29.90)', c == 200 and ck and r.get('amountAgorot') == 2990, [c, r])
    check('אחרי פתיחת התשלום — עדיין חינם', plan_of('a') == 'free')
    c, r = rpc(ja, 'hdm_billing_apply_grow_event', {'p': {'transactionId': f'morning:{PFX}self', 'kind': 'initial', 'outcome': 'approved', 'amountAgorot': 2990, 'checkoutId': ck}})
    check('משתמש לא יכול לדווח "שולם" בעצמו (אין הרשאה)', c in (401, 403, 404) and plan_of('a') == 'free', [c, r])
    c, r = rpc(ja, 'hdm_billing_save_token', {'p_profile': IDS['a'], 'p_token': 'x', 'p_last4': '1111'})
    check('משתמש לא יכול לשמור כרטיס בעצמו', c in (401, 403, 404), [c, r])
    c, r = http('POST', f'/functions/v1/morning-webhook?ck={ck}', {'documentId': f'{PFX}fake'})
    check('webhook בלי הטוקן הסודי — נחסם (401), לא הופעל', c == 401 and plan_of('a') == 'free', [c, r])
    c0, r0 = http('POST', f'/functions/v1/morning-webhook?t={WT}', {})
    check('webhook עם הטוקן הנכון עובר את שלב הזיהוי (400 = אין מסמך)', c0 == 400, [c0, r0])
    c, r = http('POST', f'/functions/v1/morning-webhook?t={WT}&ck={ck}', {'documentId': f'{PFX}fake-doc'})
    check('webhook עם טוקן אבל מסמך שלא אומת מול Morning — לא הופעל', c >= 400 and plan_of('a') == 'free', [c, r])
    check('ניסיון התשלום עדיין ממתין (לא סומן כשולם)', sql(f"select status from public.hdm_checkouts where id='{ck}'") == 'pending')
    # כך השרת קולט תשלום אחרי שאימת את המסמך מול Morning (morning-webhook → hdm_billing_apply_grow_event, הרשאת שרת בלבד)
    ev = json.dumps({'transactionId': f'morning:{PFX}doc1', 'kind': 'initial', 'outcome': 'approved', 'amountAgorot': 2990, 'checkoutId': ck, 'raw': {'provider': 'morning', 'documentId': f'{PFX}doc1'}})
    res = sql(f"select public.hdm_billing_apply_grow_event('{ev}'::jsonb)->>'result'")
    check('תשלום מאומת מהשרת → המנוי הופעל (בסיסי)', res == 'started' and plan_of('a') == 'basic', [res, plan_of('a')])
    end1 = sql(f"select current_period_end from public.hdm_subscriptions where profile_id='{IDS['a']}'")
    res2 = sql(f"select public.hdm_billing_apply_grow_event('{ev}'::jsonb)->>'result'")
    check('אותו אישור פעמיים — נקלט פעם אחת, התקופה לא הוארכה', sql(f"select count(*) from public.hdm_payments where grow_transaction_id='morning:{PFX}doc1'") == '1'
          and sql(f"select current_period_end from public.hdm_subscriptions where profile_id='{IDS['a']}'") == end1, res2)

    # ---------- 2. פרטי כרטיס לא נשמרים ----------
    cols = sql("""select string_agg(table_name||'.'||column_name, ',') from information_schema.columns
                  where table_schema='public' and table_name like 'hdm\\_%' and column_name ~* '(card_?num|card_?number|^pan$|cvv|cvc|holder|credit_?card|^cc_)'""")
    check('אין במסד עמודות של מספר כרטיס מלא / CVV', cols == '', cols)
    sql(f"select public.hdm_billing_save_token('{IDS['a']}', 'morning-token-{PFX}', '4242')")
    row = sql(f"select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_schema='public' and table_name='hdm_billing_tokens'")
    # ב-Staging יש עמודות נוספות (payer_name, payer_phone, card_exp) מניסוי Grow הישיר (26, PR #39) — לא חלק מחבילת Production (08)
    check('בזרימת Morning נשמרים רק מזהה טוקן + 4 ספרות (שאר העמודות ריקות)', sql(f"select coalesce(grow_token,'')||'|'||coalesce(card_last4,'')||'|'||(to_jsonb(t) - 'profile_id' - 'grow_token' - 'card_last4' - 'updated_at')::text from public.hdm_billing_tokens t where profile_id='{IDS['a']}'")
          in (f'morning-token-{PFX}|4242|{{}}', f'morning-token-{PFX}|4242|{{"card_exp": null, "payer_name": null, "payer_phone": null}}'), row)
    check('4 ספרות בלבד (המסד דוחה יותר)', 'check' in sql("select pg_get_constraintdef(oid) from pg_constraint where conrelid='public.hdm_billing_tokens'::regclass and contype='c' limit 1").lower())
    c, r = http('GET', f'/rest/v1/hdm_billing_tokens?select=*', headers={'authorization': f'Bearer {ja}'})
    check('משתמש לא יכול לקרוא את טבלת הכרטיסים', c in (401, 403, 404) or r == [], [c, r])
    raw = sql(f"select string_agg(raw::text, ' ') from public.hdm_payments where profile_id='{IDS['a']}'")
    check('רשומת התשלום לא מכילה פרטי כרטיס', not any(w in raw.lower() for w in ('cardnumber', 'cvv', 'expir', '4580')), raw[:200])

    # ---------- 3. ביטול מפסיק את החידוש ----------
    ckb = rpc(jb, 'hdm_billing_start_checkout', {'p_plan': 'plus', 'p_terms_version': terms, 'p_accept': True})[1]['checkoutId']
    evb = json.dumps({'transactionId': f'morning:{PFX}doc2', 'kind': 'initial', 'outcome': 'approved', 'amountAgorot': 4890, 'checkoutId': ckb})
    check('משתמש ב׳: מנוי פלוס פעיל', sql(f"select public.hdm_billing_apply_grow_event('{evb}'::jsonb)->>'result'") == 'started' and plan_of('b') == 'plus')
    sql(f"select public.hdm_billing_save_token('{IDS['b']}', 'morning-token-{PFX}b', '1234')")
    c, r = rpc(ja, 'hdm_billing_cancel', {'p_refund': False})
    check('משתמש א׳ מבטל באפליקציה', c == 200, [c, r])
    st = sql(f"select auto_renew::text||'|'||status from public.hdm_subscriptions where profile_id='{IDS['a']}'")
    check('אחרי הביטול: החידוש כבוי, המנוי עדיין פעיל עד סוף התקופה', st.startswith('false|') and plan_of('a') == 'basic', st)
    check('אחרי הביטול: תאריך הסיום לא השתנה', sql(f"select current_period_end from public.hdm_subscriptions where profile_id='{IDS['a']}'") == end1)
    # מועד החידוש הגיע לשניהם
    sql(f"update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = any({IDS_SQL})")
    claimed = sql("select coalesce(string_agg(x->>'profileId', ','), '') from jsonb_array_elements(public.hdm_billing_claim_due_renewals(100)) x")
    check('מועד החידוש: המבוטל לא נתפס לחיוב', IDS['a'] not in claimed, claimed)
    check('מועד החידוש: מי שלא ביטל — נתפס לחיוב (ביקורת)', IDS['b'] in claimed, claimed)
    again = sql("select coalesce(string_agg(x->>'profileId', ','), '') from jsonb_array_elements(public.hdm_billing_claim_due_renewals(100)) x")
    check('הרצה כפולה של החידוש — לא נתפס חיוב שני לאותה תקופה', IDS['b'] not in again, again)
    c, r = http('POST', '/functions/v1/morning-renewals', b'', {'x-hdm-cron': CS})
    check('פונקציית החידוש החיה: הסליקה כבויה ב-Staging — לא חייבה אף אחד', c == 200 and isinstance(r, dict) and r.get('skipped') == 'MORNING_OFF', [c, r])
    code_exit = 0 if all(results) else 1
except Exception as e:
    print('ERROR', str(e)[:300]); code_exit = 1
finally:
    left = cleanup(); print(f'ניקוי: נשארו {left} רשומות בדיקה'); print(f'SUMMARY {sum(results)}/{len(results)} עברו')
sys.exit(code_exit)
