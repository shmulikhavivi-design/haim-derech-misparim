# =====================================================================
# חיים דרך מספרים — בדיקת דפדפן לאפשרות 2 (כרטיס פעם אחת): מעבר לדף שמירת הכרטיס, חזרה, השלמת התשלום, הודעות.
# התשובות של פונקציית השרת מדומות בדפדפן (אין מפתחות Sandbox של Morning); המסד והחשבונות — Staging אמיתי. בלי חיוב.
# הפונקציות ב-Staging פרוסות עם MORNING_LIVE=0, ולכן השרת מסרב לפתוח דף תשלום (503) — זה מה שבודקים שקורה,
# ושהמסד רשם ניסיון תשלום אחד עם הסכמה, והמסלול לא השתנה. משתמשי בדיקה זמניים נמחקים בסוף.
# =====================================================================
import json, os, random, string, subprocess, sys, http.server, threading, functools
from playwright.sync_api import sync_playwright

DB = os.environ['STAGING_DB_URL']; KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', ''); PAGE = os.environ['PAGE']
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'cfl{RUN}_'; MAIL = f'hdm-cfl-{RUN}-'
PW = 'Mco-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(20))
if not KEY.startswith('sb_publishable_'): print('⛔ no publishable key'); sys.exit(2)

def sql(q):
    r = subprocess.run(['psql', DB, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q], capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError('sql: ' + r.stderr.strip()[:200])
    return r.stdout.strip()
results = []
def check(name, ok, got=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {str(got)[:240]}'), flush=True)

CRYPT = 'extensions.crypt' if sql("select count(*) from pg_proc where proname='crypt' and pronamespace='extensions'::regnamespace") != '0' else 'crypt'
SALT = CRYPT.replace('crypt', 'gen_salt')
IDS = {'buyer': PFX + 'buyer', 'declined': PFX + 'declined', 'pending': PFX + 'pending'}
IDS_SQL = "array[" + ",".join(f"'{v}'" for v in IDS.values()) + "]"

def cleanup():
    sql(f"""begin;
      delete from public.hdm_payments where profile_id = any({IDS_SQL});
      delete from public.hdm_billing_tokens where profile_id = any({IDS_SQL});
      delete from public.hdm_billing_customers where profile_id = any({IDS_SQL});
      delete from public.hdm_consents where profile_id = any({IDS_SQL});
      delete from public.hdm_checkouts where profile_id = any({IDS_SQL});
      delete from public.hdm_subscription_events where profile_id = any({IDS_SQL});
      delete from public.hdm_subscriptions where profile_id = any({IDS_SQL});
      delete from public.docs where collection = 'profiles' and id = any({IDS_SQL});
      delete from public.hdm_accounts where profile_id = any({IDS_SQL});
      delete from auth.users where email like '{MAIL}%@example.invalid';
      commit;""")
    return sql(f"select (select count(*) from auth.users where email like '{MAIL}%') + (select count(*) from public.hdm_checkouts where profile_id like '{PFX}%') + (select count(*) from public.hdm_accounts where profile_id like '{PFX}%')")

def create():
    for k in IDS: create_one(k)
def create_one(k):
    consent = sql("select public.hdm_required_terms_version()")
    pid, email = IDS[k], f'{MAIL}{k}@example.invalid'
    profile = json.dumps({'currentName': 'קונה בדיקה', 'birthdate': '1990-01-01', 'birthFirstName': 'א', 'birthLastName': 'ב', 'gender': 'אישה',
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

html_dir = os.path.dirname(os.path.abspath(PAGE))
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=html_dir))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()
APP = f'http://127.0.0.1:{srv.server_address[1]}/{os.path.basename(PAGE)}'
errors, fn_calls, fn_status = [], [], []

def login(pg, who='buyer'):
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
    pg.fill('#li-email', f'{MAIL}{who}@example.invalid'); pg.fill('#li-pass', PW); pg.click('#li-submit')
    try: pg.wait_for_function("() => myId || document.getElementById('li-status').textContent.trim()", timeout=15000)
    except Exception: pass
    pg.wait_for_timeout(800); return pg.evaluate("() => myId")

def step(name, fn):
    try: return fn()
    except Exception as e:
        vis = ''
        try: vis = pg_dbg[0].evaluate("() => Array.from(document.querySelectorAll('.signup,.about-screen,[id$=-screen]')).filter(e=>getComputedStyle(e).display!=='none' && e.offsetParent!==null || getComputedStyle(e).position==='fixed' && getComputedStyle(e).display!=='none').map(e=>e.id||e.className).slice(0,8).join(',')")
        except Exception: pass
        raise RuntimeError(f'{name}: {str(e)[:120]} | visible: {vis}')
pg_dbg = [None]
def checkout_and_pay(pg, plan):
    pg_dbg[0] = pg
    pg.evaluate("() => { try { if (window.hdmEnt) hdmEnt.billing = null; } catch (e) {} }")
    pg.evaluate("() => hdmOpenPlans()")
    try: pg.wait_for_function("() => hdmEnt && hdmEnt.forId === myId && !hdmEnt.error && hdmEnt.billing", timeout=15000)
    except Exception: pass
    pg.wait_for_timeout(400)
    step('כפתור הצטרפות במסך המנויים', lambda: pg.locator(f'#hdm-plan-buy-{plan}').click(timeout=8000, force=True))
    pg.wait_for_timeout(600)
    t0 = step('עמוד התשלום נפתח', lambda: pg.inner_text('#hdm-checkout-body', timeout=8000))
    step('לחיצה על תשלום בלי סימון', lambda: pg.locator('#hdm-co-pay').click(timeout=8000, force=True)); pg.wait_for_timeout(400)
    blocked = pg.inner_text('#hdm-co-msg')
    step('סימון התקנון', lambda: pg.locator('#hdm-co-accept').check(timeout=8000, force=True)); pg.wait_for_timeout(300)
    step('לחיצה על תשלום', lambda: pg.locator('#hdm-co-pay').click(timeout=8000, force=True))
    try: pg.wait_for_function("() => !hdmCo.busy && hdmCo.msg && !/פותחים/.test(hdmCo.msg)", timeout=20000)
    except Exception: pass
    pg.wait_for_timeout(300)
    return t0, blocked, pg.inner_text('#hdm-co-msg')


GROW = 'credit-checkout-form'
GROW_URL = 'https://secure.meshulam.co.il/credit-checkout-form?l=e2e-test'
calls = []
def server_charge(pid):
    """מה ש-morning-checkout עושה אחרי חיוב מאושר: תפיסה + אירוע תשלום מאומת (מדומה, בלי Morning)."""
    ck = sql(f"select id from public.hdm_checkouts where profile_id='{pid}' and status='pending' order by created_at desc limit 1")
    sql(f"select public.hdm_billing_claim_checkout('{ck}', 'morning-charge:{ck}')")
    sql(f"select public.hdm_billing_save_token('{pid}', 'tok-{RUN}-{pid[-4:]}', '4580')")
    return sql(f"""select public.hdm_billing_apply_grow_event(jsonb_build_object('transactionId', 'morning:doc-{RUN}-{pid}', 'kind', 'initial',
                   'outcome', 'approved', 'amountAgorot', (select amount_agorot from public.hdm_checkouts where id='{ck}'), 'checkoutId', '{ck}'))::text""")
def start_checkout(pid, plan):
    sql(f"""select set_config('request.jwt.claims', json_build_object('sub', (select auth_user_id from public.hdm_accounts where profile_id='{pid}'), 'role', 'authenticated')::text, false)""")
def route_fn(pg, script):
    """script: פונקציה (step, body) → dict תשובה מדומה של morning-checkout"""
    def h(route):
        try: b = json.loads(route.request.post_data or '{}')
        except Exception: b = {}
        step = b.get('step', 'start'); calls.append(step)
        resp = script(step, b)
        route.fulfill(status=200 if resp.get('mode') in ('redirect', 'charged', 'failed', 'card_saved') else 202,
                      content_type='application/json', headers={'access-control-allow-origin': '*'}, body=json.dumps(resp))
    pg.route('**/functions/v1/morning-checkout', h)
    # דף Grow מדומה (לא יוצאים לאינטרנט, אין כרטיס)
    pg.route('https://secure.meshulam.co.il/**', lambda r: r.fulfill(status=200, content_type='text/html; charset=utf-8',
             body='<!doctype html><meta charset="utf-8"><title>Grow</title><p>דף שמירת כרטיס מדומה</p>'))
def toast(pg):
    try: return pg.inner_text('#hdm-toast', timeout=500)
    except Exception: return ''
def plan_of(pid): return sql(f"select public.hdm_plan_of('{pid}')")

print(f'ריצה {RUN}', flush=True)
code = 1
try:
    create()
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        def ctx():
            c = br.new_context(); c.add_init_script(f"try{{ localStorage.setItem('hdm_staging_publishable_key', {json.dumps(KEY)}); }}catch(e){{}}"); return c
        # 1. הצטרפות: מעבר לדף שמירת הכרטיס של Grow (בלי חיוב)
        c = ctx(); pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)))
        route_fn(pg, lambda step, b: {'mode': 'redirect', 'url': GROW_URL} if step == 'start' else {'mode': 'waiting'})
        pg.goto(APP + '?billing=preview'); pg.wait_for_timeout(2500)
        check('התחברות', login(pg) == IDS['buyer'])
        pg.evaluate("() => { try { if (window.hdmEnt) hdmEnt.billing = null; } catch (e) {} }")
        pg.evaluate("() => hdmOpenPlans()")
        try: pg.wait_for_function("() => hdmEnt && hdmEnt.forId === myId && !hdmEnt.error && hdmEnt.billing", timeout=15000)
        except Exception: pass
        pg.wait_for_timeout(400)
        pg.locator('#hdm-plan-buy-basic').click(timeout=8000, force=True); pg.wait_for_timeout(600)
        co = pg.inner_text('#hdm-checkout-body', timeout=8000)
        check('עמוד התשלום מסביר: כרטיס פעם אחת, נשמר אצל Grow, הפעלה רק אחרי אישור', 'פעם אחת' in co and 'Grow' in co and 'לא אצלנו' in co and 'רק אחרי אישור' in co, co[-400:])
        pg.locator('#hdm-co-accept').check(timeout=8000, force=True); pg.wait_for_timeout(300)
        pg.locator('#hdm-co-pay').click(timeout=8000, force=True)
        try: pg.wait_for_url('https://secure.meshulam.co.il/**', timeout=15000)
        except Exception: pass
        check('הועבר לדף המאובטח של Grow לשמירת הכרטיס', pg.url.startswith('https://secure.meshulam.co.il/'), pg.url)
        ck = sql(f"select id from public.hdm_checkouts where profile_id='{IDS['buyer']}' and status='pending' order by created_at desc limit 1")
        check('נפתח ניסיון תשלום אחד (בסיסי ₪29.90), עדיין בלי חיוב', bool(ck) and sql(f"select amount_agorot||'|'||plan from public.hdm_checkouts where id='{ck}'") == '2990|basic', ck)
        check('לפני שמירת הכרטיס — המנוי לא פעיל', plan_of(IDS['buyer']) == 'free')
        c.close()
        # 2. חזרה מ-Grow: קודם "ממתין", ואז השרת מחייב ומפעיל — המסך מציג אישור, ולא ממשיך לבקש
        calls.clear(); state = {'n': 0}
        def complete_script(step, b):
            if step != 'complete': return {'mode': 'waiting'}
            state['n'] += 1
            if state['n'] == 1: return {'mode': 'waiting'}
            if state['n'] == 2: server_charge(IDS['buyer']); return {'mode': 'charged', 'result': 'started'}
            return {'mode': 'charged', 'result': 'already_paid'}
        c = ctx(); pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)))
        route_fn(pg, complete_script)
        pg.goto(APP + f'?billing=card&ck={ck}'); pg.wait_for_timeout(2500); login(pg)
        check('הכתובת נוקתה מ-billing=card', 'billing=card' not in pg.url, pg.url)
        try: pg.wait_for_function("() => /התשלום אושר והמנוי הופעל/.test((document.getElementById('hdm-toast')||{}).textContent||'')", timeout=30000)
        except Exception: pass
        check('אחרי החזרה: הודעה "התשלום אושר והמנוי הופעל"', 'התשלום אושר והמנוי הופעל' in toast(pg), toast(pg))
        check('המנוי הופעל במסד רק אחרי אירוע התשלום (בסיסי, מתחדש)', sql(f"select public.hdm_plan_of('{IDS['buyer']}')||'|'||auto_renew from public.hdm_subscriptions where profile_id='{IDS['buyer']}'") == 'basic|true')
        n_before = state['n']; pg.wait_for_timeout(9000)
        check('אחרי האישור — האפליקציה מפסיקה לבקש (אין בקשות חיוב נוספות)', state['n'] == n_before == 2, [n_before, state['n']])
        check('ניסיון התשלום שולם, ונרשם תשלום אחד', sql(f"select (select status from public.hdm_checkouts where id='{ck}')||'|'||(select count(*) from public.hdm_payments where profile_id='{IDS['buyer']}')") == 'paid|1')
        check('נשמרו רק טוקן ו-4 ספרות', sql(f"select card_last4 from public.hdm_billing_tokens where profile_id='{IDS['buyer']}'") == '4580')
        c.close()
        # 3. כרטיס נדחה: הודעה, והמנוי לא מופעל
        c = ctx(); pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)))
        route_fn(pg, lambda step, b: {'mode': 'redirect', 'url': GROW_URL} if step == 'start' else {'mode': 'failed'})
        pg.goto(APP + '?billing=preview'); pg.wait_for_timeout(2500); login(pg, 'declined')
        pg.evaluate("() => hdmOpenPlans()"); pg.wait_for_timeout(2500)
        pg.locator('#hdm-plan-buy-plus').click(timeout=8000, force=True); pg.wait_for_timeout(500)
        pg.locator('#hdm-co-accept').check(timeout=8000, force=True); pg.locator('#hdm-co-pay').click(timeout=8000, force=True)
        try: pg.wait_for_url('https://secure.meshulam.co.il/**', timeout=15000)
        except Exception: pass
        ck2 = sql(f"select id from public.hdm_checkouts where profile_id='{IDS['declined']}' and status='pending' order by created_at desc limit 1")
        pg.goto(APP + f'?billing=card&ck={ck2}'); pg.wait_for_timeout(2500); login(pg, 'declined')
        try: pg.wait_for_function("() => /נדחה/.test((document.getElementById('hdm-toast')||{}).textContent||'')", timeout=20000)
        except Exception: pass
        check('כרטיס נדחה: הודעה ברורה', 'נדחה' in toast(pg), toast(pg))
        check('כרטיס נדחה: המנוי לא הופעל', plan_of(IDS['declined']) == 'free')
        c.close()
        # 4. תשלום בתהליך: כפתור "השלמת התשלום" במסך המנויים
        c = ctx(); pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)))
        st4 = {'n': 0}
        def pending_script(step, b):
            if step == 'start': return {'mode': 'redirect', 'url': GROW_URL}
            st4['n'] += 1; server_charge(IDS['pending']) if st4['n'] == 1 else None
            return {'mode': 'charged', 'result': 'started' if st4['n'] == 1 else 'already_paid'}
        route_fn(pg, pending_script)
        pg.goto(APP + '?billing=preview'); pg.wait_for_timeout(2500); login(pg, 'pending')
        pg.evaluate("() => hdmOpenPlans()"); pg.wait_for_timeout(2500)
        pg.locator('#hdm-plan-buy-basic').click(timeout=8000, force=True); pg.wait_for_timeout(500)
        pg.locator('#hdm-co-accept').check(timeout=8000, force=True); pg.locator('#hdm-co-pay').click(timeout=8000, force=True)
        try: pg.wait_for_url('https://secure.meshulam.co.il/**', timeout=15000)
        except Exception: pass
        pg.goto(APP + '?billing=preview'); pg.wait_for_timeout(2500); login(pg, 'pending')
        pg.evaluate("() => { try { if (window.hdmEnt) hdmEnt.billing = null; } catch (e) {} hdmOpenPlans(); }"); pg.wait_for_timeout(3500)
        check('תשלום בתהליך: מוצג כפתור "השלמת התשלום"', pg.locator('#hdm-card-complete').count() == 1)
        if pg.locator('#hdm-card-complete').count(): pg.locator('#hdm-card-complete').click(force=True)
        try: pg.wait_for_function("() => /התשלום אושר והמנוי הופעל/.test((document.getElementById('hdm-toast')||{}).textContent||'')", timeout=20000)
        except Exception: pass
        check('"השלמת התשלום" → אישור והפעלה (חיוב אחד)', plan_of(IDS['pending']) == 'basic' and sql(f"select count(*) from public.hdm_payments where profile_id='{IDS['pending']}'") == '1')
        c.close()
        check('אין שגיאות JavaScript בדף', not errors, errors[:3])
        br.close()
    code = 0 if all(results) else 1
except Exception as e:
    print('ERROR', str(e)[:300]); code = 1
finally:
    left = cleanup()
    print(f'ניקוי: נשארו {left} רשומות בדיקה')
    print(f'SUMMARY {sum(results)}/{len(results)} עברו')
sys.exit(code)
