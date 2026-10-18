# =====================================================================
# חיים דרך מספרים — בדיקת דפדפן: כפתור "ביטול מנוי" ומדיניות ביטול מנוי בגרסה שעולה לאוויר
# (staging.html שממנו נבנה index.html) מול Staging בלבד. בלי סליקה, בלי חיובים, בלי שינוי במסד מצד הדף.
# משתמשי בדיקה: hdm-cxl-<ריצה>-*@example.invalid, מזהי פרופיל cxl<ריצה>_*. בסוף — ובכל כישלון — הכול נמחק.
# משתני סביבה: STAGING_DB_URL (סוד), STAGING_PUBLISHABLE_KEY (מפתח ציבורי), PAGE (נתיב ל-staging.html)
# =====================================================================
import json, os, random, string, subprocess, sys, http.server, threading, functools
from playwright.sync_api import sync_playwright

DB = os.environ['STAGING_DB_URL']
KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', '')
PAGE = os.environ.get('PAGE', 'staging.html')
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'cxl{RUN}_'
MAIL = f'hdm-cxl-{RUN}-'
PW = 'Cxl-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(20))
if not KEY.startswith('sb_publishable_'):
    print('⛔ STAGING_PUBLISHABLE_KEY חסר או לא ציבורי'); sys.exit(2)

def sql(q):
    r = subprocess.run(['psql', DB, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q], capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError('sql: ' + r.stderr.strip()[:200])
    return r.stdout.strip()

results = []
def check(name, ok, got=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {str(got)[:200]}'), flush=True)

CRYPT = 'extensions.crypt' if sql("select count(*) from pg_proc where proname='crypt' and pronamespace='extensions'::regnamespace") != '0' else 'crypt'
SALT = CRYPT.replace('crypt', 'gen_salt')
PEOPLE = {'free': 'פנינה חינם', 'plus': 'פלורה ותיקה'}
IDS = {k: PFX + k for k in PEOPLE}
IDS_SQL = "array[" + ",".join(f"'{v}'" for v in IDS.values()) + "]"

def cleanup():
    sql(f"""begin;
      delete from public.hdm_subscription_events where profile_id = any({IDS_SQL});
      delete from public.hdm_subscriptions where profile_id = any({IDS_SQL});
      delete from public.docs where collection = 'profiles' and id = any({IDS_SQL});
      delete from public.hdm_accounts where profile_id = any({IDS_SQL});
      delete from auth.users where email like '{MAIL}%@example.invalid';
      commit;""")
    return sql(f"""select (select count(*) from auth.users where email like '{MAIL}%') + (select count(*) from public.hdm_accounts where profile_id like '{PFX}%')
                 + (select count(*) from public.hdm_subscriptions where profile_id like '{PFX}%')""")

def create_people():
    consent = sql("select public.hdm_required_terms_version()")
    for k, name in PEOPLE.items():
        pid, email = IDS[k], f'{MAIL}{k}@example.invalid'
        profile = json.dumps({'currentName': name, 'birthdate': '1990-01-01', 'birthFirstName': 'א', 'birthLastName': 'ב', 'gender': 'אישה',
                              'lookingFor': 'גברים', 'location': 'חיפה', 'photoUrl': 'data:image/png;base64,iVBORw0KGgo=', 'createdAt': 0}, ensure_ascii=False)
        sql(f"""begin;
          with u as (
            insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                                    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                                    confirmation_token, recovery_token, email_change_token_new, email_change)
            values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', '{email}',
                    {CRYPT}('{PW}', {SALT}('bf')), now(), '{{"provider":"email","providers":["email"]}}', '{{}}', now(), now(), '', '', '', '')
            returning id)
          , i as (insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
                  select gen_random_uuid(), u.id::text, u.id, jsonb_build_object('sub', u.id::text, 'email', '{email}', 'email_verified', true), 'email', now(), now(), now() from u)
          , a as (insert into public.hdm_accounts (auth_user_id, profile_id) select id, '{pid}' from u)
          insert into public.hdm_consents (user_id, profile_id, version, source) select id, '{pid}', '{consent}', 'signup' from u;
          insert into public.docs (collection, id, data) values ('profiles', '{pid}', $j${profile}$j$::jsonb);
          commit;""")
    # ותיקה: פלוס ידני ללא הגבלת זמן וללא תשלום (כמו 4 החשבונות הקיימים)
    sql(f"select public.hdm_admin_set_plan('{IDS['plus']}', 'plus', null, 'e2e cancel policy')")

html_dir = os.path.dirname(os.path.abspath(PAGE))
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=html_dir))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()
APP = f'http://127.0.0.1:{srv.server_address[1]}/{os.path.basename(PAGE)}'
seen_hosts, errors, billing_calls = set(), [], []

def on_request(r):
    seen_hosts.add(r.url.split('/')[2])
    if 'hdm_billing' in r.url or 'hdm_checkout' in r.url: billing_calls.append(r.url)

def new_page(ctx, url):
    pg = ctx.new_page(); pg.on('pageerror', lambda e: errors.append(str(e))); pg.on('request', on_request)
    pg.goto(url); pg.wait_for_timeout(2500)
    return pg

def login(pg, k):
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
    pg.fill('#li-email', f'{MAIL}{k}@example.invalid'); pg.fill('#li-pass', PW); pg.click('#li-submit')
    try: pg.wait_for_function("() => myId || document.getElementById('li-status').textContent.trim()", timeout=15000)
    except Exception: pass
    pg.wait_for_timeout(500)
    return pg.evaluate("() => myId")

def wait_plan(pg):
    try: pg.wait_for_function("() => hdmEnt && hdmEnt.forId === myId && !hdmEnt.error", timeout=15000)
    except Exception: pass
    pg.wait_for_timeout(400)

NOT_DONE = ['המנוי בוטל', 'בקשת הביטול התקבלה ב', 'בוטל בהצלחה']

print(f'ריצה {RUN}', flush=True)
exit_code = 1
try:
    create_people()
    subs_before = sql("select count(*) || '|' || coalesce(max(updated_at)::text, '') from public.hdm_subscriptions")
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        def ctx_new():
            c = br.new_context(); c.add_init_script(f"try{{ localStorage.setItem('hdm_staging_publishable_key', {json.dumps(KEY)}); }}catch(e){{}}"); return c

        # --- לא מחובר: מסך הפתיחה ---
        c = ctx_new(); pg = new_page(c, APP)
        check('מסך הפתיחה: קישור "ביטול מנוי"', pg.locator('#auth-cancel-link').count() == 1)
        check('מסך הפתיחה: קישור "מדיניות ביטול מנוי"', pg.locator('#auth-cancel-policy').count() == 1)
        pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; }catch(e){} }")
        pg.click('#auth-cancel-link'); pg.wait_for_timeout(300)
        lt = pg.inner_text('#legal-body')
        check('לא מחובר: "ביטול מנוי" פותח את מדיניות הביטול', pg.inner_text('#legal-title') == 'מדיניות ביטול מנוי' and 'איך מבטלים' in lt, lt[:200])
        need = ['מתחדש אוטומטית', 'איך מבטלים', 'ביטול מנוי', 'לא יתבצע שום חיוב נוסף', '3 ימי עסקים', 'סוף התקופה ששולמה',
                'ביטול בתוך 14 יום', 'לא ייגבו דמי ביטול', 'אינו מחיקת חשבון', 'תאריך סיום המנוי', 'עדיין לא פתוחים לרכישה', 'life.through.numbers333@gmail.com']
        miss = [w for w in need if w not in lt]
        check('תוכן המדיניות: כל הסעיפים הנדרשים', not miss, miss)
        pg.evaluate("() => closeLegal()")
        c.close()

        # --- חינם ---
        c = ctx_new(); pg = new_page(c, APP)
        check('חינם: התחברות', login(pg, 'free') == IDS['free'])
        check('מסך ראשי: קישור "ניהול מנוי"', 'ניהול מנוי' in pg.inner_text('#hdm-plans-link'))
        pg.evaluate("() => hdmOpenPlans()"); wait_plan(pg)
        t = pg.inner_text('#hdm-plans-body')
        check('כותרת: "ניהול מנוי"', pg.inner_text('#hdm-plans-screen .about-title').strip() == 'ניהול מנוי')
        check('יש כפתור "ביטול מנוי" באזור האישי', pg.locator('#hdm-bill-cancel').count() == 1)
        check('לפני רכישה: הסבר חידוש וביטול + קישור למדיניות', pg.locator('#hdm-plans-policy a').count() == 1 and 'מתחדשים אוטומטית' in t, t[-300:])
        check('אין אפשרות רכישה: כל כפתורי המסלולים כבויים', pg.locator('.hdm-plan-btn:not([disabled])').count() == 0 and 'בקרוב' in t)
        pg.click('#hdm-bill-cancel'); pg.wait_for_timeout(300)
        t = pg.inner_text('#hdm-plans-body')
        check('לחיצה: הסבר שאין מנוי בתשלום ולא בוצע חיוב', 'אין לך מנוי בתשלום' in t and 'לא בוצע שום חיוב' in t, t[:400])
        check('לחיצה: מוסבר איך הביטול יעבוד כשהרכישה תיפתח', 'עדיין לא פתוחים לרכישה' in t and 'לא מוחק את החשבון' in t, t[:500])
        check('לא מוצג ביטול שבוצע', not any(w in t for w in NOT_DONE), t[:400])
        pg.click('#hdm-plans-policy a'); pg.wait_for_timeout(300)
        check('הקישור במסך המסלולים פותח את המדיניות', pg.inner_text('#legal-title') == 'מדיניות ביטול מנוי')
        pg.evaluate("() => closeLegal()")
        check('הגדרות: "ביטול מנוי" ו"מדיניות ביטול מנוי"', pg.locator('#set-cancel-sub').count() == 1 and pg.locator('#set-cancel-policy').count() == 1)
        pg.evaluate("() => { hdmCloseLayer('hdm-plans-screen'); hdmCancelEntry(); }"); wait_plan(pg)
        check('"ביטול מנוי" בהגדרות: פותח ישר את הסבר הביטול', pg.locator('#hdm-cancel-info').count() == 1)
        c.close()

        # --- פלוס ידני (ללא תשלום) ---
        c = ctx_new(); pg = new_page(c, APP)
        check('ותיקה: התחברות', login(pg, 'plus') == IDS['plus'])
        pg.evaluate("() => hdmCancelEntry()"); wait_plan(pg)
        t = pg.inner_text('#hdm-plans-body')
        check('ותיקה: "המסלול הוגדר ללא תשלום — אין מנוי בתשלום לבטל"', 'הוגדר ללא תשלום' in t and 'פלוס' in t, t[:400])
        check('ותיקה: לא מוצג ביטול שבוצע', not any(w in t for w in NOT_DONE), t[:400])
        check('ותיקה: נשארה בפלוס', sql(f"select public.hdm_plan_of('{IDS['plus']}')") == 'plus')
        c.close()

        check('הדף לא קרא לשום פונקציית חיוב/ביטול בשרת', not billing_calls, billing_calls[:2])
        check('לא השתנה שום מנוי במסד', sql("select count(*) || '|' || coalesce(max(updated_at)::text, '') from public.hdm_subscriptions") == subs_before)
        check('אין שגיאות JavaScript בדף', not errors, errors[:2])
        check('הדף פנה רק ל-Staging (לא לפרויקט הפעיל)', not any('qtspzigjlbtckqfyaubp' in h for h in seen_hosts), sorted(seen_hosts))
        br.close()
    exit_code = 0 if results and all(results) else 1
except Exception as e:
    print('FAIL שגיאה בבדיקה: ' + str(e)[:300], flush=True); exit_code = 1
finally:
    left = cleanup()
    print(f'ניקוי: נשארו {left} רשומות בדיקה', flush=True)
    if left != '0': exit_code = 1
    srv.shutdown()
print(f'SUMMARY {sum(results)}/{len(results)} passed', flush=True)
sys.exit(exit_code)
