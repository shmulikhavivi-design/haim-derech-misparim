# =====================================================================
# חיים דרך מספרים — בדיקת דפדפן: VIP "בקרוב" + כפתור "המשך לתשלום מאובטח" לבסיסי ופלוס (PR #38) מול Staging. בלי חיוב.
# הפונקציות ב-Staging פרוסות עם MORNING_LIVE=0, ולכן השרת מסרב לפתוח דף תשלום (503) — זה מה שבודקים שקורה,
# ושהמסד רשם ניסיון תשלום אחד עם הסכמה, והמסלול לא השתנה. משתמשי בדיקה זמניים נמחקים בסוף.
# =====================================================================
import json, os, random, string, subprocess, sys, http.server, threading, functools
from playwright.sync_api import sync_playwright

DB = os.environ['STAGING_DB_URL']; KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', ''); PAGE = os.environ['PAGE']
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'vip{RUN}_'; MAIL = f'hdm-vip-{RUN}-'
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
IDS = {'buyer': PFX + 'buyer'}
IDS_SQL = "array[" + ",".join(f"'{v}'" for v in IDS.values()) + "]"

def cleanup():
    sql(f"""begin;
      delete from public.hdm_payments where profile_id = any({IDS_SQL});
      delete from public.hdm_checkouts where profile_id = any({IDS_SQL});
      delete from public.hdm_subscription_events where profile_id = any({IDS_SQL});
      delete from public.hdm_subscriptions where profile_id = any({IDS_SQL});
      delete from public.docs where collection = 'profiles' and id = any({IDS_SQL});
      delete from public.hdm_accounts where profile_id = any({IDS_SQL});
      delete from auth.users where email like '{MAIL}%@example.invalid';
      commit;""")
    return sql(f"select (select count(*) from auth.users where email like '{MAIL}%') + (select count(*) from public.hdm_checkouts where profile_id like '{PFX}%') + (select count(*) from public.hdm_accounts where profile_id like '{PFX}%')")

def create():
    consent = sql("select public.hdm_required_terms_version()")
    pid, email = IDS['buyer'], f'{MAIL}buyer@example.invalid'
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

def login(pg):
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
    pg.fill('#li-email', f'{MAIL}buyer@example.invalid'); pg.fill('#li-pass', PW); pg.click('#li-submit')
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
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        def ctx():
            c = br.new_context(); c.add_init_script(f"try{{ localStorage.setItem('hdm_staging_publishable_key', {json.dumps(KEY)}); }}catch(e){{}}"); return c
        # 1. בלי preview: הסליקה כבויה — לא נפתח ניסיון תשלום ולא נקרא השרת
        c = ctx(); pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)))
        pg.on('request', lambda r: fn_calls.append(r.url) if '/functions/v1/' in r.url else None)
        pg.goto(APP); pg.wait_for_timeout(2500)
        check('התחברות', login(pg) == IDS['buyer'])
        t0, blocked, msg = checkout_and_pay(pg, 'basic')
        check('עמוד התשלום: מסלול בסיסי ₪29.90, חידוש אוטומטי ותנאי ביטול', '₪29.90' in t0 and 'חידוש אוטומטי' in t0 and 'ביטול' in t0, t0[:300])
        check('בלי סימון התקנון — נחסם', 'לא ניתן להמשיך לתשלום' in blocked, blocked)
        check('הסליקה כבויה: הודעה שלא בוצע חיוב, בלי פנייה לשרת', 'לא בוצע ולא יבוצע שום חיוב' in msg and not fn_calls, [msg, fn_calls])
        check('הסליקה כבויה: לא נפתח ניסיון תשלום במסד', sql(f"select count(*) from public.hdm_checkouts where profile_id='{IDS['buyer']}'") == '0')
        c.close()
        # 2. עם preview (Staging בלבד): הכפתור עובר את כל המסלול עד Morning, והשרת מסרב כי MORNING_LIVE=0
        for plan, amt in [('basic', 2990), ('plus', 4890)]:
            fn_calls.clear()
            c = ctx(); pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)))
            pg.on('request', lambda r: fn_calls.append(r.url) if '/functions/v1/' in r.url else None)
            pg.on('response', lambda r: fn_status.append(r.status) if '/functions/v1/morning-checkout' in r.url and r.request.method == 'POST' else None)
            pg.goto(APP + '?billing=preview'); pg.wait_for_timeout(2500); login(pg)
            sql(f"update public.hdm_checkouts set status='expired', closed_at=now() where profile_id='{IDS['buyer']}' and status='pending'")
            t0, blocked, msg = checkout_and_pay(pg, plan)
            check(f'{plan}: הכפתור קרא לפונקציית התשלום morning-checkout', any('/functions/v1/morning-checkout' in u for u in fn_calls), fn_calls)
            row = sql(f"select plan || '|' || amount_agorot || '|' || status || '|' || terms_version from public.hdm_checkouts where profile_id='{IDS['buyer']}' and status='pending' order by created_at desc limit 1")
            check(f'{plan}: נפתח ניסיון תשלום אחד בסכום ₪{amt/100:.2f} עם גרסת התנאים', row.startswith(f'{plan}|{amt}|pending|'), row)
            check(f'{plan}: השרת סירב — משתמש שלא ברשימת הבדיקה (403) — מוצג שלא בוצע חיוב', 'לא בוצע חיוב' in msg and 403 in fn_status, [msg, fn_status])
            check(f'{plan}: לא הייתה הפניה לדף תשלום', pg.url.startswith(APP), pg.url)
            check(f'{plan}: המסלול לא השתנה (עדיין חינם)', sql(f"select public.hdm_plan_of('{IDS['buyer']}')") == 'free')
            c.close()

        # 2ב. VIP "בקרוב": מוצג, בלי הצטרפות; אין לשונית VIP בעמוד התשלום; גם פנייה ישירה לשרת נחסמת
        c = ctx(); pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)))
        pg.goto(APP + '?billing=preview'); pg.wait_for_timeout(2500); login(pg)
        pg.evaluate("() => hdmOpenPlans()")
        try: pg.wait_for_function("() => hdmEnt && hdmEnt.forId === myId && !hdmEnt.error", timeout=15000)
        except Exception: pass
        pg.wait_for_timeout(600)
        card = pg.inner_text('#hdm-plan-card-vip') if pg.locator('#hdm-plan-card-vip').count() else ''
        check('VIP מוצג במסך המנויים עם "בקרוב" והמחיר', 'בקרוב' in card and '79.90' in card, card[:200])
        check('VIP: כפתור "בקרוב" מושבת, ואין כפתור הצטרפות', pg.locator('#hdm-plan-soon-vip').is_disabled() and pg.locator('#hdm-plan-buy-vip').count() == 0)
        check('בסיסי ופלוס עם כפתור הצטרפות', pg.locator('#hdm-plan-buy-basic').count() == 1 and pg.locator('#hdm-plan-buy-plus').count() == 1)
        pg.evaluate("() => hdmOpenCheckout('plus')"); pg.wait_for_timeout(500)
        check('עמוד התשלום: יש לשוניות בסיסי ופלוס, אין לשונית VIP', pg.locator('#hdm-co-tab-basic').count() == 1 and pg.locator('#hdm-co-tab-plus').count() == 1 and pg.locator('#hdm-co-tab-vip').count() == 0)
        pg.evaluate("() => { hdmCoSelect('vip'); }"); pg.wait_for_timeout(200)
        check('אי אפשר לבחור VIP בעמוד התשלום (גם בקוד)', pg.evaluate("() => hdmCo.plan") == 'plus')
        pg.evaluate("() => { try{ hdmCloseLayer('hdm-checkout-screen'); }catch(e){} hdmOpenCheckout('vip'); }"); pg.wait_for_timeout(300)
        check('hdmOpenCheckout(vip) לא פותח עמוד תשלום', pg.evaluate("() => hdmCo.plan") != 'vip')
        sql(f"update public.hdm_checkouts set status='expired', closed_at=now() where profile_id='{IDS['buyer']}' and status='pending'")
        res = pg.evaluate("""async () => { const t = await window.__sb.rpc('hdm_billing_status'); const bt = t && t.data && t.data.termsVersion;
            const r = await window.__sb.rpc('hdm_billing_start_checkout', { p_plan: 'vip', p_terms_version: bt || '', p_accept: true });
            return JSON.stringify({ err: r.error && (r.error.message + ' ' + (r.error.hint||'')), data: r.data }); }""")
        check('פנייה ישירה לשרת להצטרפות ל-VIP — נחסמת', 'HDM_BILLING_PLAN_SOON' in res or 'בקרוב' in res, res)
        check('לא נוצר ניסיון תשלום ל-VIP', sql(f"select count(*) from public.hdm_checkouts where profile_id='{IDS['buyer']}' and plan='vip'") == '0')
        c.close()
        # 3. לחיצה כפולה: אותו ניסיון תשלום
        c = ctx(); pg = c.new_page(); pg.goto(APP + '?billing=preview'); pg.wait_for_timeout(2500); login(pg)
        before = sql(f"select count(*) from public.hdm_checkouts where profile_id='{IDS['buyer']}'")
        checkout_and_pay(pg, 'plus')
        after = sql(f"select count(*) from public.hdm_checkouts where profile_id='{IDS['buyer']}'")
        check('לחיצה חוזרת על אותו מסלול — אין ניסיון תשלום נוסף (אותו ניסיון)', before == after, [before, after])
        c.close()
        # 4. חזרה מעמוד התשלום עם ?billing=return לא מסמנת "שולם"
        c = ctx(); pg = c.new_page(); pg.goto(APP + '?billing=return&ck=00000000-0000-0000-0000-000000000000'); pg.wait_for_timeout(3500); login(pg)
        check('חזרה מעמוד התשלום לא מפעילה מנוי (רק השרת מאשר)', sql(f"select public.hdm_plan_of('{IDS['buyer']}')") == 'free')
        check('הכתובת נוקתה מ-billing=return', 'billing=return' not in pg.url, pg.url)
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
