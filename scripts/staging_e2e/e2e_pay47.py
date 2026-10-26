# =====================================================================
# חיים דרך מספרים — בדיקות Staging לתיקון התשלומים (PR #47, תקלת 26.10). בלי חיוב: הסליקה ב-Staging כבויה (MORNING_LIVE=0),
# ותשובות morning-checkout בדפדפן מדומות (route) כדי לבדוק את התנהגות האפליקציה. משתמשי בדיקה ונתונים נמחקים בסוף.
#   א. השרת (הפונקציות שנפרסו ל-Staging מהקוד של PR #47): הרשאות, סליקה כבויה, המשימה המתוזמנת לא נוגעת כשכבוי.
#   ב. הדפדפן: חזרה מ-Grow בלי חיבור → נשמר ומושלם אחרי התחברות; 401 / 502 / 409; origin נשלח; הודעות נכונות.
# =====================================================================
import json, os, random, string, subprocess, sys, http.server, threading, functools, urllib.request, uuid
from playwright.sync_api import sync_playwright
DB = os.environ['STAGING_DB_URL']; KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', ''); PAGE = os.environ['PAGE']
CRON = os.environ.get('HDM_CRON_SECRET', ''); SB = 'https://ousepgdvzammgkxkweze.supabase.co'
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'p47{RUN}_'; MAIL = f'hdm-p47-{RUN}-'; DOM = 'example.invalid'
PW = 'P47-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(20)) + '1!'
if not KEY.startswith('sb_publishable_'): print('⛔ no publishable key'); sys.exit(2)
def sql(q):
    r = subprocess.run(['psql', DB, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q], capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError('sql: ' + r.stderr.strip()[:200])
    return r.stdout.strip()
results = []
def check(name, ok, got=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {str(got)[:300]}'), flush=True)
CRYPT = 'extensions.crypt' if sql("select count(*) from pg_proc where proname='crypt' and pronamespace='extensions'::regnamespace") != '0' else 'crypt'
SALT = CRYPT.replace('crypt', 'gen_salt')
REQ = sql("select public.hdm_required_terms_version()")
PID, EMAIL = PFX + 'buyer', f'{MAIL}buyer@{DOM}'
def create():
    profile = json.dumps({'currentName': 'קונה בדיקה', 'birthdate': '1990-01-01', 'birthFirstName': 'א', 'birthLastName': 'ב', 'gender': 'אישה', 'age': '36',
                          'lookingFor': 'גברים', 'location': 'חיפה', 'photoUrl': 'data:image/png;base64,iVBORw0KGgo=', 'createdAt': 0}, ensure_ascii=False)
    sql(f"""begin;
      with u as (
        insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                                created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
        values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', '{EMAIL}', {CRYPT}('{PW}', {SALT}('bf')), now(),
                '{{"provider":"email","providers":["email"]}}', '{{}}', now(), now(), '', '', '', '') returning id)
      , i as (insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
              select gen_random_uuid(), u.id::text, u.id, jsonb_build_object('sub', u.id::text, 'email', '{EMAIL}', 'email_verified', true), 'email', now(), now(), now() from u)
      , a as (insert into public.hdm_accounts (auth_user_id, profile_id) select id, '{PID}' from u)
      insert into public.hdm_consents (user_id, profile_id, version, source) select id, '{PID}', '{REQ}', 'signup' from u;
      insert into public.docs (collection, id, data) values ('profiles', '{PID}', $j${profile}$j$::jsonb);
      commit;""")
def cleanup():
    sql(f"""begin;
      delete from public.hdm_payments where profile_id = '{PID}';
      delete from public.hdm_checkouts where profile_id = '{PID}';
      delete from public.hdm_billing_customers where profile_id = '{PID}';
      delete from public.hdm_billing_tokens where profile_id = '{PID}';
      delete from public.hdm_subscription_events where profile_id = '{PID}';
      delete from public.hdm_subscriptions where profile_id = '{PID}';
      delete from public.docs where id like '{PFX}%';
      delete from public.hdm_consents where user_id in (select id from auth.users where email like '{MAIL}%');
      delete from public.hdm_accounts where profile_id = '{PID}';
      delete from auth.users where email like '{MAIL}%'; commit;""")
    return sql(f"select (select count(*) from auth.users where email like '{MAIL}%') + (select count(*) from public.hdm_checkouts where profile_id='{PID}') + (select count(*) from public.hdm_billing_customers where profile_id='{PID}')")
def http(method, path, body=None, headers=None):
    req = urllib.request.Request(SB + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={'apikey': KEY, 'content-type': 'application/json', **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=60) as r: return r.status, json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        try: return e.code, json.loads(e.read() or b'{}')
        except Exception: return e.code, {}
d = os.path.dirname(os.path.abspath(PAGE))
s_ = __import__('http.server').server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(__import__('http.server').server.SimpleHTTPRequestHandler, directory=d))
s_.RequestHandlerClass.log_message = lambda *a: None; threading.Thread(target=s_.serve_forever, daemon=True).start()
ORIGIN = f'http://127.0.0.1:{s_.server_address[1]}'; APP = f'{ORIGIN}/{os.path.basename(PAGE)}'
errors = []
CORS = {'access-control-allow-origin': '*', 'access-control-allow-headers': 'authorization, content-type, apikey, x-client-info', 'access-control-allow-methods': 'POST, OPTIONS'}
def mock(ctx, plan_list, calls):
    """plan_list: רשימת תשובות לפי הסדר (status, body); אחרונה חוזרת על עצמה."""
    def h(route):
        r = route.request
        if r.method == 'OPTIONS': return route.fulfill(status=204, headers=CORS)
        try: calls.append(json.loads(r.post_data or '{}'))
        except Exception: calls.append({})
        st, b = plan_list[min(len(calls) - 1, len(plan_list) - 1)]
        route.fulfill(status=st, headers={**CORS, 'content-type': 'application/json'}, body=json.dumps(b))
    ctx.route('**/functions/v1/morning-checkout', h)
def newctx(br):
    c = br.new_context(viewport={'width': 390, 'height': 844})
    c.add_init_script(f"try{{ localStorage.setItem('hdm_staging_publishable_key', {json.dumps(KEY)}); }}catch(e){{}}")
    return c
def login(pg):
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
    pg.fill('#li-email', EMAIL); pg.fill('#li-pass', PW); pg.click('#li-submit')
    try: pg.wait_for_function("() => myId", timeout=20000)
    except Exception: pass
    pg.wait_for_timeout(800)
def toast(pg): return pg.evaluate("() => { var t = document.getElementById('hdm-toast'); return t ? t.textContent : ''; }")
def pend(pg): return pg.evaluate("() => localStorage.getItem('hdm_pending_card_ck')")
def wait_calls(pg, calls, n, ms=25000):
    for _ in range(ms // 500):
        if len(calls) >= n: break
        pg.wait_for_timeout(500)
    pg.wait_for_timeout(1500)

print(f'ריצה {RUN}', flush=True)
code = 1
try:
    create()
    # ---------------- א. השרת (Staging, הקוד של PR #47, סליקה כבויה) ----------------
    st, b = http('POST', '/functions/v1/morning-checkout', {'checkoutId': str(uuid.uuid4()), 'origin': 'https://haimderechmisparim.com'})
    check('שרת: בלי התחברות → 401', st == 401, [st, b])
    st, tok = http('POST', '/auth/v1/token?grant_type=password', {'email': EMAIL, 'password': PW})
    jwt = tok.get('access_token', '')
    st, b = http('POST', '/functions/v1/morning-checkout', {'checkoutId': str(uuid.uuid4()), 'origin': 'https://haimderechmisparim.com'}, {'authorization': f'Bearer {jwt}'})
    check('שרת: משתמש שלא ברשימת הבדיקה → 403, בלי פנייה ל-Morning', st == 403 and b.get('error') == 'not_open', [st, b])
    # ניסיון ממתין "ישן" עם לקוח Morning — מה שהמשימה המתוזמנת הייתה משלימה. כשהסליקה כבויה — לא נוגעת.
    uid = sql(f"select auth_user_id from public.hdm_accounts where profile_id='{PID}'")
    ck = sql(f"""insert into public.hdm_checkouts (user_id, profile_id, plan, amount_agorot, terms_version, created_at, expires_at)
                 values ('{uid}', '{PID}', 'plus', 4890, public.hdm_billing_current_terms(), now() - interval '3 minutes', now() + interval '20 minutes') returning id""").splitlines()[0]
    sql(f"insert into public.hdm_billing_customers (profile_id, morning_client_id) values ('{PID}', 'p47-fake-{RUN}')")
    st, b = http('POST', '/functions/v1/hdm-billing-worker', {}, {'x-hdm-cron': 'wrong'})
    check('משימה מתוזמנת: בלי הסוד → 401', st == 401, [st, b])
    if CRON:
        st, b = http('POST', '/functions/v1/hdm-billing-worker', {}, {'x-hdm-cron': CRON})
        cards = (b or {}).get('cards')
        check('משימה מתוזמנת: רצה עם הקוד החדש ומדלגת כשהסליקה כבויה (MORNING_OFF)', st in (200, 500) and isinstance(cards, dict) and cards.get('skipped') in ('MORNING_OFF', 'dry_run'), [st, b])
    row = sql(f"select status || '|' || coalesce(grow_process_id,'∅') from public.hdm_checkouts where id='{ck}'")
    check('משימה מתוזמנת: הניסיון לא נתפס ולא שונה, אין תשלום', row == 'pending|∅' and sql(f"select count(*) from public.hdm_payments where profile_id='{PID}'") == '0', row)
    check('המסלול לא השתנה (חינם)', sql(f"select public.hdm_plan_of('{PID}')") == 'free')
    sql(f"update public.hdm_checkouts set status='expired', closed_at=now() where id='{ck}'")

    # ---------------- ב. הדפדפן (תשובות מדומות — בלי חיוב) ----------------
    CK = str(uuid.uuid4())
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        # 1. חזרה מ-Grow לכתובת שבה הלקוח לא מחובר (המקרה של 26.10) → נשמר → מושלם אוטומטית אחרי התחברות
        c = newctx(br); calls = []; mock(c, [(200, {'mode': 'charged', 'result': 'started'})], calls)
        pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)[:200]))
        pg.goto(f'{APP}?billing=card&ck={CK}'); pg.wait_for_timeout(3000)
        check('חזרה בלי חיבור: הניסיון נשמר בדפדפן והכתובת נוקתה', (CK in (pend(pg) or '')) and 'billing=card' not in pg.url, [pend(pg), pg.url])
        check('חזרה בלי חיבור: לא נשלחה בקשה לשרת לפני התחברות', len(calls) == 0, calls)
        login(pg); wait_calls(pg, calls, 1)
        check('אחרי התחברות: "השלמת התשלום" נשלחה אוטומטית לאותו ניסיון', any(x.get('step') == 'complete' and x.get('checkoutId') == CK for x in calls), calls)
        check('אחרי התחברות: הודעת הצלחה והניסיון נמחק מהדפדפן', 'התשלום אושר' in toast(pg) and not pend(pg), [toast(pg), pend(pg)])
        check('בקשת השלמה אחת בלבד (אין שליחה כפולה מהדפדפן)', len([x for x in calls if x.get('step') == 'complete']) == 1, calls)
        c.close()
        # 2. ניסיון ממתין שמור + כניסה מאוחרת יותר (אחרי שהלולאה הראשונה הסתיימה) → המנגנון החוזר משלים
        c = newctx(br); calls = []; mock(c, [(200, {'mode': 'charged', 'result': 'started'})], calls)
        c.add_init_script(f"try{{ localStorage.setItem('hdm_pending_card_ck', JSON.stringify({{ ck: '{CK}', t: Date.now() }})); }}catch(e){{}}")
        pg = c.new_page(); pg.goto(APP); pg.wait_for_timeout(1500); login(pg); wait_calls(pg, calls, 1)
        check('כניסה מאוחרת: ניסיון שמור הושלם אוטומטית', any(x.get('step') == 'complete' and x.get('checkoutId') == CK for x in calls) and 'התשלום אושר' in toast(pg), [calls, toast(pg)])
        c.close()
        # 3. 401 בהשלמה → "צריך להתחבר שוב", לא נמחק
        c = newctx(br); calls = []; mock(c, [(401, {'error': 'auth'})], calls)
        pg = c.new_page(); pg.goto(APP); pg.wait_for_timeout(1500); login(pg)
        pg.evaluate(f"() => {{ localStorage.setItem('hdm_pending_card_ck', JSON.stringify({{ ck: '{CK}', t: Date.now() }})); window.hdmCardComplete('{CK}'); }}"); wait_calls(pg, calls, 1)
        check('401: הודעה "צריך להתחבר שוב — לא בוצע חיוב" (לא "לא הצלחנו לפתוח את הדף")', 'צריך להתחבר שוב' in toast(pg) and 'לא בוצע חיוב' in toast(pg), toast(pg))
        check('401: הניסיון נשאר שמור להשלמה אחרי התחברות', CK in (pend(pg) or ''), pend(pg))
        c.close()
        # 4. תקלה זמנית (502) ואז הצלחה → ניסיון חוזר אחד, הצלחה
        c = newctx(br); calls = []; mock(c, [(502, {'error': 'UPSTREAM'}), (200, {'mode': 'charged', 'result': 'started'})], calls)
        pg = c.new_page(); pg.goto(APP); pg.wait_for_timeout(1500); login(pg)
        pg.evaluate(f"() => window.hdmCardComplete('{CK}')"); wait_calls(pg, calls, 2)
        check('502 ואז הצלחה: ניסיון חוזר אחד והודעת הצלחה', len(calls) == 2 and 'התשלום אושר' in toast(pg), [calls, toast(pg)])
        c.close()
        # 5. ניסיון שפג (409) → הודעה מתאימה, בלי ניסיון חוזר, נמחק
        c = newctx(br); calls = []; mock(c, [(409, {'error': 'not_pending', 'status': 'expired'})], calls)
        pg = c.new_page(); pg.goto(APP); pg.wait_for_timeout(1500); login(pg)
        pg.evaluate(f"() => {{ localStorage.setItem('hdm_pending_card_ck', JSON.stringify({{ ck: '{CK}', t: Date.now() }})); window.hdmCardComplete('{CK}'); }}"); wait_calls(pg, calls, 1, 8000)
        check('409: "ניסיון התשלום פג… לא בוצע חיוב נוסף", בלי ניסיון חוזר', 'פג' in toast(pg) and len(calls) == 1 and not pend(pg), [toast(pg), calls, pend(pg)])
        c.close()
        # 6. פתיחת דף התשלום: נשלח origin; תקלה בפתיחה → ההודעה המקורית (רק כאן)
        c = newctx(br); calls = []; mock(c, [(502, {'error': 'UPSTREAM', 'step': 'start'})], calls)
        pg = c.new_page(); pg.goto(APP + '?billing=preview'); pg.wait_for_timeout(2000); login(pg)
        pg.evaluate("() => hdmOpenPlans()")
        try: pg.wait_for_function("() => hdmEnt && hdmEnt.forId === myId && !hdmEnt.error && hdmEnt.billing", timeout=15000)
        except Exception: pass
        pg.locator('#hdm-plan-buy-plus').click(timeout=8000, force=True); pg.wait_for_timeout(600)
        pg.locator('#hdm-co-accept').check(timeout=8000, force=True); pg.locator('#hdm-co-pay').click(timeout=8000, force=True)
        try: pg.wait_for_function("() => !hdmCo.busy && hdmCo.msg && !/פותחים/.test(hdmCo.msg)", timeout=20000)
        except Exception: pass
        msg = pg.inner_text('#hdm-co-msg')
        check('פתיחת הדף: הדפדפן שולח את הכתובת שלו (origin) לשרת', any(x.get('origin') == ORIGIN for x in calls), calls)
        check('פתיחת הדף נכשלה: "לא הצלחנו לפתוח את הדף המאובטח… לא בוצע חיוב"', 'לא הצלחנו לפתוח' in msg and 'לא בוצע חיוב' in msg, msg)
        check('המסלול לא השתנה (חינם)', sql(f"select public.hdm_plan_of('{PID}')") == 'free')
        c.close()
        check('אין שגיאות JavaScript בדף', not errors, errors[:3])
        br.close()
    code = 0 if all(results) else 1
except Exception as e:
    print('ERROR', str(e)[:400]); code = 1
finally:
    left = cleanup()
    print(f'ניקוי: נשארו {left} רשומות בדיקה')
    print(f'SUMMARY {sum(results)}/{len(results)} עברו')
sys.exit(code)
