# =====================================================================
# חיים דרך מספרים — בדיקת דפדפן: התראות סליקה — רק למקבל ההתראות, סימון "טופל". בלי חיוב.
# התשובות של פונקציית השרת מדומות בדפדפן (אין מפתחות Sandbox של Morning); המסד והחשבונות — Staging אמיתי. בלי חיוב.
# הפונקציות ב-Staging פרוסות עם MORNING_LIVE=0, ולכן השרת מסרב לפתוח דף תשלום (503) — זה מה שבודקים שקורה,
# ושהמסד רשם ניסיון תשלום אחד עם הסכמה, והמסלול לא השתנה. משתמשי בדיקה זמניים נמחקים בסוף.
# =====================================================================
import json, os, random, string, subprocess, sys, http.server, threading, functools
from playwright.sync_api import sync_playwright

DB = os.environ['STAGING_DB_URL']; KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', ''); PAGE = os.environ['PAGE']
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'alr{RUN}_'; MAIL = f'life.through.numbers333+hdm-alr-{RUN}-'
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
IDS = {'owner': PFX + 'owner', 'user': PFX + 'user'}
IDS_SQL = "array[" + ",".join(f"'{v}'" for v in IDS.values()) + "]"

def cleanup():
    sql(f"""begin;
      delete from public.hdm_billing_alerts where profile_id = any({IDS_SQL});
      delete from public.hdm_payments where profile_id = any({IDS_SQL});
      delete from public.hdm_billing_tokens where profile_id = any({IDS_SQL});
      delete from public.hdm_billing_customers where profile_id = any({IDS_SQL});
      delete from public.hdm_consents where profile_id = any({IDS_SQL});
      delete from public.hdm_checkouts where profile_id = any({IDS_SQL});
      delete from public.hdm_subscription_events where profile_id = any({IDS_SQL});
      delete from public.hdm_subscriptions where profile_id = any({IDS_SQL});
      delete from public.docs where collection = 'profiles' and id = any({IDS_SQL});
      delete from public.hdm_accounts where profile_id = any({IDS_SQL});
      delete from auth.users where email like '{MAIL}%@gmail.com';
      commit;""")
    return sql(f"select (select count(*) from auth.users where email like '{MAIL}%') + (select count(*) from public.hdm_checkouts where profile_id like '{PFX}%') + (select count(*) from public.hdm_accounts where profile_id like '{PFX}%')")

def create():
    for k in IDS: create_one(k)
def create_one(k):
    consent = sql("select public.hdm_required_terms_version()")
    pid, email = IDS[k], f'{MAIL}{k}@gmail.com'
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
    pg.fill('#li-email', f'{MAIL}{who}@gmail.com'); pg.fill('#li-pass', PW); pg.click('#li-submit')
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



print(f'ריצה {RUN}', flush=True)
code = 1
try:
    create()
    sql(f"insert into public.hdm_billing_alert_recipients (user_id) select auth_user_id from public.hdm_accounts where profile_id='{IDS['owner']}'")
    sql(f"select public.hdm_billing_alert_add('first_charge_failed', '{IDS['user']}', 'e2e-{RUN}-1', 2990, 'כרטיס נדחה — בדיקה')")
    sql(f"select public.hdm_billing_alert_add('charge_unconfirmed', '{IDS['user']}', 'e2e-{RUN}-2', 4890, 'חיוב בלי אישור — בדיקה')")
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        def ctx():
            c = br.new_context(); c.add_init_script(f"try{{ localStorage.setItem('hdm_staging_publishable_key', {json.dumps(KEY)}); }}catch(e){{}}"); return c
        # משתמש רגיל — אין התראות
        c = ctx(); pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)))
        pg.goto(APP); pg.wait_for_timeout(2500); login(pg, 'user'); pg.evaluate("() => hdmCheckBillingAlerts(true)"); pg.wait_for_timeout(2500)
        check('משתמש רגיל — לא מוצג באנר התראות', pg.locator('#hdm-alert-banner').count() == 0)
        c.close()
        # מקבל ההתראות — באנר עם 2, רשימה, "טופל"
        c = ctx(); pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)))
        pg.goto(APP); pg.wait_for_timeout(2500); login(pg, 'owner'); pg.evaluate("() => hdmCheckBillingAlerts(true)"); pg.wait_for_timeout(2500)
        b = pg.inner_text('#hdm-alert-banner') if pg.locator('#hdm-alert-banner').count() else ''
        check('מקבל ההתראות — באנר "התראות סליקה: 2"', '2' in b and 'התראות סליקה' in b, b)
        pg.locator('#hdm-alert-banner').click(force=True); pg.wait_for_timeout(500)
        lst = pg.inner_text('#hdm-alert-list') if pg.locator('#hdm-alert-list').count() else ''
        check('הרשימה מציגה סוג, סכום ופרטים', 'חיוב ראשון נדחה' in lst and '₪29.90' in lst and 'חיוב בלי אישור' in lst and '₪48.90' in lst, lst[:300])
        pg.locator('#hdm-alert-list button:has-text("טופל")').first.click(force=True); pg.wait_for_timeout(2500)
        b2 = pg.inner_text('#hdm-alert-banner') if pg.locator('#hdm-alert-banner').count() else ''
        check('אחרי "טופל" — נשארה התראה אחת', '1' in b2, b2)
        check('במסד: התראה אחת סומנה כטופלה', sql(f"select count(*) from public.hdm_billing_alerts where profile_id='{IDS['user']}' and resolved_at is not null") == '1')
        c.close()
        check('אין שגיאות JavaScript בדף', not errors, errors[:3])
        br.close()
    code = 0 if all(results) else 1
except Exception as e:
    print('ERROR', str(e)[:300]); code = 1
finally:
    try: sql(f"delete from public.hdm_billing_alert_recipients where user_id in (select auth_user_id from public.hdm_accounts where profile_id = any({IDS_SQL}))")
    except Exception: pass
    left = cleanup()
    print(f'ניקוי: נשארו {left} רשומות בדיקה')
    print(f'SUMMARY {sum(results)}/{len(results)} עברו')
sys.exit(code)
