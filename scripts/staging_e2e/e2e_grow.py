# =====================================================================
# חיים דרך מספרים — בדיקה מקצה לקצה של חיבור Grow מול Staging בלבד, עם תחליף Grow (grow-mock).
#
# מה נבדק: הפונקציות האמיתיות שנפרסו ל-Staging (grow-checkout, grow-webhook, grow-renewals) + מסד Staging אמיתי.
# Grow עצמה מוחלפת ב-grow-mock (באותו פרויקט Staging): אין פנייה ל-Grow, אין כרטיס אמיתי, אין חיוב.
# משתמשי בדיקה בלבד: hdm-grow-<ריצה>-*@example.invalid, פרופילים grow<ריצה>_*. בסוף — ובכל כישלון — הכול נמחק.
# משתנים: STAGING_DB_URL, STAGING_PUBLISHABLE_KEY, GROW_WEBHOOK_TOKEN, HDM_CRON_SECRET (נוצרו בהרצה, לא נשמרים)
# =====================================================================
import json, os, random, string, subprocess, sys, urllib.request, urllib.error, urllib.parse

SB = 'https://ousepgdvzammgkxkweze.supabase.co'          # Staging בלבד
DB = os.environ['STAGING_DB_URL']
KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', '')
WH = os.environ['GROW_WEBHOOK_TOKEN']
CRON = os.environ['HDM_CRON_SECRET']
if 'qtspzigjlbtckqfyaubp' in DB or 'ousepgdvzammgkxkweze' not in DB:
    print('⛔ לא Staging'); sys.exit(2)
if not KEY.startswith('sb_publishable_'):
    print('⛔ STAGING_PUBLISHABLE_KEY חסר'); sys.exit(2)

RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX, MAIL = f'grow{RUN}_', f'hdm-grow-{RUN}-'
PW = 'Grow-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(20))
PEOPLE = {'basic': 'בתיה בסיסית', 'plus': 'פנינה פלוס', 'vip': 'ורד VIP', 'bad': 'בדיקת זיוף', 'stat': 'שרית מבטלת'}
IDS = {k: PFX + k for k in PEOPLE}
IDS_SQL = 'array[' + ','.join(f"'{v}'" for v in IDS.values()) + ']'
PRICE = {'basic': 2990, 'plus': 4890, 'vip': 7990}

def sql(q):
    r = subprocess.run(['psql', DB, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q], capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError('sql: ' + r.stderr.strip()[:300])
    return r.stdout.strip()

results = []
def check(name, ok, got=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {str(got)[:300]}'), flush=True)

def http(method, url, body=None, headers=None, form=False):
    h = dict(headers or {})
    data = None
    if body is not None:
        data = urllib.parse.urlencode(body).encode() if form else json.dumps(body).encode()
        h['content-type'] = 'application/x-www-form-urlencoded' if form else 'application/json'
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r: code, raw = r.status, r.read()
    except urllib.error.HTTPError as e: code, raw = e.code, e.read()
    try: return code, json.loads(raw or b'null')
    except ValueError: return code, raw.decode(errors='replace')[:300]

TOK = {}
def login(k):
    c, j = http('POST', f'{SB}/auth/v1/token?grant_type=password', {'email': f'{MAIL}{k}@example.invalid', 'password': PW}, {'apikey': KEY})
    if c != 200: raise RuntimeError(f'login {k}: {c} {j}')
    TOK[k] = j['access_token']
def auth(k): return {'apikey': KEY, 'authorization': f'Bearer {TOK[k]}'}
def rpc(k, fn, args=None):
    return http('POST', f'{SB}/rest/v1/rpc/{fn}', args or {}, auth(k))
def checkout(k, ck):
    return http('POST', f'{SB}/functions/v1/grow-checkout', {'checkoutId': ck}, auth(k))
def renewals(secret=CRON):
    return http('POST', f'{SB}/functions/v1/grow-renewals', {}, {'x-hdm-cron': secret})
def webhook(note, token=WH, ck=''):
    q = urllib.parse.urlencode({'t': token, **({'ck': ck} if ck else {})})
    return http('POST', f'{SB}/functions/v1/grow-webhook?{q}', note, {}, form=True)
def plan_of(k): return sql(f"select public.hdm_plan_of('{IDS[k]}')")
def terms(): return sql('select public.hdm_billing_current_terms()')

def cleanup():
    sql(f"""begin;
      delete from public.hdm_payments where profile_id = any({IDS_SQL}) or checkout_id in (select id from public.hdm_checkouts where profile_id = any({IDS_SQL}));
      delete from public.hdm_renewal_charges where profile_id = any({IDS_SQL});
      delete from public.hdm_checkouts where profile_id = any({IDS_SQL});
      delete from public.hdm_subscription_events where profile_id = any({IDS_SQL});
      delete from public.hdm_cancel_requests where profile_id = any({IDS_SQL});
      delete from public.hdm_email_outbox where profile_id = any({IDS_SQL});
      delete from public.hdm_grow_outbox where profile_id = any({IDS_SQL});
      delete from public.hdm_subscriptions where profile_id = any({IDS_SQL});
      delete from public.hdm_billing_tokens where profile_id = any({IDS_SQL});
      delete from public.docs where collection = 'profiles' and id = any({IDS_SQL});
      delete from public.hdm_accounts where profile_id = any({IDS_SQL});
      delete from auth.users where email like '{MAIL}%@example.invalid';
      commit;""")
    return sql(f"""select (select count(*) from auth.users where email like '{MAIL}%') + (select count(*) from public.hdm_accounts where profile_id like '{PFX}%')
      + (select count(*) from public.hdm_checkouts where profile_id like '{PFX}%') + (select count(*) from public.hdm_payments where profile_id like '{PFX}%')
      + (select count(*) from public.hdm_subscriptions where profile_id like '{PFX}%') + (select count(*) from public.hdm_billing_tokens where profile_id like '{PFX}%')
      + (select count(*) from public.hdm_renewal_charges where profile_id like '{PFX}%') + (select count(*) from public.hdm_cancel_requests where profile_id like '{PFX}%')""")

def create_people():
    crypt = 'extensions.crypt' if sql("select count(*) from pg_proc where proname='crypt' and pronamespace='extensions'::regnamespace") != '0' else 'crypt'
    salt = crypt.replace('crypt', 'gen_salt')
    consent = sql('select public.hdm_required_terms_version()')
    for k, name in PEOPLE.items():
        pid, email = IDS[k], f'{MAIL}{k}@example.invalid'
        prof = json.dumps({'currentName': name, 'birthdate': '1990-01-01', 'gender': 'אישה', 'createdAt': 0}, ensure_ascii=False)
        sql(f"""begin;
          with u as (insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data,
                       raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
                     values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', '{email}',
                       {crypt}('{PW}', {salt}('bf')), now(), '{{"provider":"email","providers":["email"]}}', '{{}}', now(), now(), '', '', '', '') returning id)
          , i as (insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
                  select gen_random_uuid(), u.id::text, u.id, jsonb_build_object('sub', u.id::text, 'email', '{email}', 'email_verified', true), 'email', now(), now(), now() from u)
          , a as (insert into public.hdm_accounts (auth_user_id, profile_id) select id, '{pid}' from u)
          insert into public.hdm_consents (user_id, profile_id, version, source) select id, '{pid}', '{consent}', 'signup' from u;
          insert into public.docs (collection, id, data) values ('profiles', '{pid}', $j${prof}$j$::jsonb);
          commit;""")
        login(k)

def buy(k, plan, scenario='ok'):
    """הצטרפות: ניסיון תשלום → grow-checkout → "הלקוח משלם" בדף של התחליף → הודעת שרת ל-grow-webhook"""
    c, j = rpc(k, 'hdm_billing_start_checkout', {'p_plan': plan, 'p_terms_version': terms(), 'p_accept': True})
    if c != 200: return None, None, (c, j)
    ck = j['checkoutId']
    c2, j2 = checkout(k, ck)
    if c2 != 200 or (j2 or {}).get('mode') != 'redirect': return ck, None, (c2, j2)
    c3, j3 = http('GET', j2['url'] + f'&scenario={scenario}')
    return ck, j3, (c3, j2)

def main():
    create_people()
    t = terms()

    # ---------- אבטחה ----------
    check('webhook בלי טוקן → 401', webhook({'data[transactionId]': '1'}, token='')[0] == 401)
    check('webhook עם טוקן שגוי → 401', webhook({'data[transactionId]': '1'}, token='x' * 40)[0] == 401)
    check('grow-checkout בלי התחברות → 401', http('POST', f'{SB}/functions/v1/grow-checkout', {'checkoutId': '00000000-0000-0000-0000-000000000000'}, {'apikey': KEY})[0] == 401)
    check('grow-renewals בלי סוד → 401', renewals('wrong-' + 'x' * 40)[0] == 401)

    # ---------- 1. הצטרפות לשלושת המסלולים ----------
    for plan in ('basic', 'plus', 'vip'):
        ck, pay, meta = buy(plan, plan)
        res = ((pay or {}).get('webhook') or {}).get('result')
        check(f'{plan}: דף תשלום נוצר והתשלום אושר', res == 'started', meta if not pay else pay.get('webhook'))
        check(f'{plan}: המסלול פעיל', plan_of(plan) == plan, plan_of(plan))
        amt = sql(f"select amount_agorot from public.hdm_payments where checkout_id = '{ck}' and kind = 'initial'") if ck else ''
        check(f'{plan}: נגבה בדיוק ₪{PRICE[plan] / 100:.2f}', amt == str(PRICE[plan]), amt)
        card = sql(f"select concat_ws('|', left(grow_token, 3), card_last4, payer_name, payer_phone) from public.hdm_billing_tokens where profile_id = '{IDS[plan]}'")
        check(f'{plan}: כרטיס ופרטי משלם נשמרו', card == 'CT-|4580|נועה בדיקה|0500000000', card)
        if plan == 'basic' and pay:
            note = pay['note']
            check('אותה הודעה שוב → לא נקלטת פעמיים', (webhook(note)[1] or {}).get('result') == 'already_processed')
            c, j = checkout('plus', ck)
            check('ניסיון תשלום של משתמש אחר → 404', c == 404, (c, j))

    # ---------- 2. הודעה מזויפת / סכום שונה ----------
    ck, pay, meta = buy('bad', 'basic', 'forged')
    check('הודעה מזויפת (Grow לא מכירה את העסקה) → נדחית', (pay or {}).get('webhookStatus') == 400, pay)
    check('הודעה מזויפת → המסלול לא הופעל', plan_of('bad') == 'free', plan_of('bad'))
    sql(f"update public.hdm_checkouts set status = 'expired', closed_at = now() where id = '{ck}'")
    ck, pay, meta = buy('bad', 'basic', 'wrongsum')
    check('Grow מדווחת ₪1.00 במקום ₪29.90 → לא מופעל, מסומן לבדיקה',
          ((pay or {}).get('webhook') or {}).get('result') == 'amount_mismatch' and plan_of('bad') == 'free', pay)

    # ---------- 3. חידוש אוטומטי (basic) ----------
    sql(f"update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = '{IDS['basic']}'")
    anchor = sql(f"select period_anchor from public.hdm_subscriptions where profile_id = '{IDS['basic']}'")
    c, j = renewals()
    check('חידוש: grow-renewals רץ', c == 200 and (j or {}).get('renewed', 0) >= 1, (c, j))
    ext = sql(f"select current_period_end > now() + interval '20 days' from public.hdm_subscriptions where profile_id = '{IDS['basic']}'")
    check('חידוש: המנוי הוארך בחודש', ext == 't', ext)
    check('חידוש: אותו תאריך חיוב', sql(f"select period_anchor from public.hdm_subscriptions where profile_id = '{IDS['basic']}'") == anchor)
    rd = sql(f"select coalesce(grow_direct_debit_id, '') from public.hdm_subscriptions where profile_id = '{IDS['basic']}'")
    check('חידוש: נשמר recurringDebitId מ-Grow', rd.startswith('RD-'), rd)
    paid = sql(f"select amount_agorot from public.hdm_payments where profile_id = '{IDS['basic']}' and kind = 'renewal' and outcome = 'approved'")
    check('חידוש: נגבה ₪29.90', paid == '2990', paid)
    c, j = renewals()
    n = sql(f"select count(*) from public.hdm_renewal_charges where profile_id = '{IDS['basic']}'")
    check('חידוש: הרצה שנייה לא מחייבת שוב', n == '1', n)

    # ---------- 4. חיוב שנכשל (plus) ----------
    sql(f"update public.hdm_billing_tokens set grow_token = 'DECLINE-{RUN}' where profile_id = '{IDS['plus']}'")
    sql(f"update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = '{IDS['plus']}'")
    pe = sql(f"select current_period_end from public.hdm_subscriptions where profile_id = '{IDS['plus']}'")
    c, j = renewals()
    check('כישלון: כרטיס נדחה נרשם ככישלון', (j or {}).get('failed', 0) >= 1, (c, j))
    st = sql(f"select status || '|' || (current_period_end = '{pe}'::timestamptz) from public.hdm_subscriptions where profile_id = '{IDS['plus']}'")
    check('כישלון: המנוי לא הוארך, מצב past_due', st == 'past_due|true', st)
    renewals()
    n = sql(f"select count(*) from public.hdm_renewal_charges where profile_id = '{IDS['plus']}'")
    check('כישלון: אין ניסיון חוזר לפני 48 שעות', n == '1', n)

    # ---------- 5. שדרוג יחסי (basic → plus) ----------
    sql(f"""update public.hdm_subscriptions set period_anchor = now() - interval '15 days',
              current_period_end = public.hdm_billing_add_months(now() - interval '15 days', 1) where profile_id = '{IDS['basic']}'""")
    pe = sql(f"select current_period_end from public.hdm_subscriptions where profile_id = '{IDS['basic']}'")
    c, q = rpc('basic', 'hdm_billing_upgrade_quote', {'p_plan': 'plus'})
    due = (q or {}).get('chargeNowAgorot') if c == 200 else None
    check('שדרוג: סכום יחסי ₪8–₪11', isinstance(due, int) and 800 <= due <= 1100, (c, q))
    c, j = rpc('basic', 'hdm_billing_start_upgrade', {'p_plan': 'plus', 'p_terms_version': t, 'p_accept': True, 'p_quoted_agorot': due})
    c2, j2 = checkout('basic', (j or {}).get('checkoutId', ''))
    check('שדרוג: חיוב בכרטיס השמור אושר', c2 == 200 and (j2 or {}).get('result') == 'upgraded', (c, j, c2, j2))
    check('שדרוג: המסלול פלוס', plan_of('basic') == 'plus', plan_of('basic'))
    check('שדרוג: תאריך החיוב לא השתנה', sql(f"select current_period_end from public.hdm_subscriptions where profile_id = '{IDS['basic']}'") == pe)
    up = sql(f"select amount_agorot from public.hdm_payments where profile_id = '{IDS['basic']}' and kind = 'upgrade'")
    check('שדרוג: נגבה בדיוק הסכום שאושר', up == str(due), up)

    # ---------- 6. ביטול חידוש (basic, עכשיו פלוס) ----------
    c, j = rpc('basic', 'hdm_billing_cancel', {'p_refund': False})
    check('ביטול: התקבל, "בטיפול"', c == 200 and (j or {}).get('cancelState') == 'pending', (c, j))
    check('ביטול: הגישה נשארת עד סוף התקופה', plan_of('basic') == 'plus')
    c, j = renewals()
    check('ביטול: אושר בשרת', (j or {}).get('cancelsConfirmed', 0) >= 1, (c, j))
    stc = sql(f"select state from public.hdm_cancel_requests where profile_id = '{IDS['basic']}' order by requested_at desc limit 1")
    check('ביטול: מצב הבקשה confirmed', stc == 'confirmed', stc)
    sql(f"update public.hdm_subscriptions set current_period_end = now() - interval '1 minute' where profile_id = '{IDS['basic']}'")
    before = sql(f"select count(*) from public.hdm_renewal_charges where profile_id = '{IDS['basic']}'")
    renewals()
    after = sql(f"select count(*) from public.hdm_renewal_charges where profile_id = '{IDS['basic']}'")
    check('ביטול: בסוף התקופה אין חיוב נוסף', before == after, (before, after))
    check('ביטול: בסוף התקופה המסלול חינם', plan_of('basic') == 'free', plan_of('basic'))

    # ---------- 7. ביטול עסקה לפי החוק (vip, בתוך 14 יום) ----------
    c, j = rpc('vip', 'hdm_billing_cancel', {'p_refund': True})
    check('לפי החוק: הבקשה התקבלה', c == 200 and (j or {}).get('refundRequested') is True, (c, j))
    check('לפי החוק: השירות הופסק', plan_of('vip') == 'free', plan_of('vip'))
    check('לפי החוק: החזר פתוח לטיפול', sql(f"select refund_state from public.hdm_cancel_requests where profile_id = '{IDS['vip']}'") == 'open')

rc = 1
try:
    main()
    rc = 0 if results and all(results) else 1
except Exception as e:
    print('ERROR', str(e)[:400]); rc = 1
finally:
    try:
        left = cleanup(); print(f'ניקוי: נשארו {left} רשומות בדיקה'); rc = rc or (0 if left == '0' else 1)
    except Exception as e:
        print('ERROR cleanup', str(e)[:300]); rc = 1
print(f'SUMMARY {sum(results)}/{len(results)}')
sys.exit(rc)
