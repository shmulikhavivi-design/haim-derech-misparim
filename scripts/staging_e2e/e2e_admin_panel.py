# =====================================================================
# חיים דרך מספרים — לוח ניהול בתוך האפליקציה (Staging): מנהל רואה "ניהול" ופותח את הלוח במסך אייפון; משתמש רגיל לא רואה,
# והשרת מסרב לו. משתמשי בדיקה זמניים נמחקים בסוף. בלי חיוב.
# =====================================================================
import json, os, random, string, subprocess, sys, http.server, threading, functools
from playwright.sync_api import sync_playwright
DB = os.environ['STAGING_DB_URL']; PAGE = os.environ['PAGE']
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6)); PFX = f'adm{RUN}_'; MAIL = f'hdm-adm-{RUN}-'
PW = 'Adm-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(18)) + '1!'
def sql(q):
    r = subprocess.run(['psql', DB, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q], capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError('sql: ' + r.stderr.strip()[:200])
    return r.stdout.strip()
results = []
def check(name, ok, got=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {str(got)[:240]}'), flush=True)
CRYPT = 'extensions.crypt' if sql("select count(*) from pg_proc where proname='crypt' and pronamespace='extensions'::regnamespace") != '0' else 'crypt'
SALT = CRYPT.replace('crypt', 'gen_salt')
def create(k, admin):
    consent = sql("select public.hdm_required_terms_version()"); pid, email = PFX + k, f'{MAIL}{k}@example.invalid'
    prof = json.dumps({'currentName': 'בדיקת ניהול ' + k, 'birthdate': '1988-03-03', 'gender': 'אישה', 'lookingFor': 'גברים', 'location': 'חיפה', 'photoUrl': 'data:image/png;base64,iVBORw0KGgo=', 'createdAt': 0}, ensure_ascii=False)
    sql(f"""begin;
      with u as (insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
        values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', '{email}', {CRYPT}('{PW}', {SALT}('bf')), now(), '{{"provider":"email","providers":["email"]}}', '{{}}', now(), now(), '', '', '', '') returning id)
      , i as (insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at) select gen_random_uuid(), u.id::text, u.id, jsonb_build_object('sub', u.id::text, 'email', '{email}', 'email_verified', true), 'email', now(), now(), now() from u)
      , a as (insert into public.hdm_accounts (auth_user_id, profile_id) select id, '{pid}' from u)
      , ad as (insert into public.hdm_admins (auth_user_id) select id from u where {str(admin).lower()})
      insert into public.hdm_consents (user_id, profile_id, version, source) select id, '{pid}', '{consent}', 'signup' from u;
      insert into public.docs (collection, id, data) values ('profiles', '{pid}', $j${prof}$j$::jsonb); commit;""")
def cleanup():
    sql(f"""begin; delete from public.docs where collection = 'profiles' and id like '{PFX}%'; delete from public.hdm_consents where profile_id like '{PFX}%';
      delete from public.hdm_accounts where profile_id like '{PFX}%'; delete from public.hdm_profile_private where profile_id like '{PFX}%'; delete from auth.users where email like '{MAIL}%'; commit;""")
    return sql(f"select count(*) from auth.users where email like '{MAIL}%'")
d = os.path.dirname(os.path.abspath(PAGE))
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=d)); srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start(); APP = f'http://127.0.0.1:{srv.server_address[1]}/{os.path.basename(PAGE)}'
def login(pg, who):
    pg.goto(APP, wait_until='networkidle'); pg.wait_for_timeout(1200)
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
    pg.fill('#li-email', f'{MAIL}{who}@example.invalid'); pg.fill('#li-pass', PW); pg.click('#li-submit')
    try: pg.wait_for_function("() => myId", timeout=20000)
    except Exception: pass
    pg.wait_for_timeout(1200); return pg.evaluate("() => myId")
try:
    create('admin', True); create('user', False)
    with sync_playwright() as p:
        for eng, name in [(p.chromium, 'Chrome'), (p.webkit, 'Safari')]:
            try: br = eng.launch()
            except Exception as e: print(f'SKIP {name}: {e}'); continue
            dev = p.devices['iPhone 13'] if name == 'Safari' else {'viewport': {'width': 390, 'height': 844}}
            errs = []
            ctx = br.new_context(**dev); pg = ctx.new_page(); pg.on('pageerror', lambda e: errs.append(str(e)))
            check(f'{name}: מנהל מתחבר', bool(login(pg, 'admin')))
            pg.evaluate("() => openSettings()"); pg.wait_for_timeout(2500)
            check(f'{name}: מנהל — כפתור "ניהול" מופיע בהגדרות', pg.locator('#set-admin').is_visible())
            pg.evaluate("() => hdmOpenAdmin()"); pg.wait_for_timeout(4000)
            txt = pg.inner_text('#admin-screen')
            check(f'{name}: הלוח נפתח עם משתמשים, מסלולים, הכנסות וגיל', all(k in txt for k in ('נשים', 'גברים', 'נרשמו היום', 'משלמים פעילים', 'מנויים שבוטלו', 'רק תשלומים שאושרו בפועל', 'סטטוס תשלומים', 'החידוש הבא', 'גיל ומין')), txt[:300])
            check(f'{name}: רשימת משתמשים נטענה', 'נמצאו' in pg.inner_text('#adm-users-count'), pg.inner_text('#adm-users-count'))
            pg.check('#adm-tests'); pg.wait_for_timeout(2500); pg.fill('#adm-q', RUN); pg.wait_for_timeout(2500)
            lst = pg.inner_text('#adm-users')
            check(f'{name}: חיפוש + "כולל בדיקה" → משתמשי הבדיקה מסומנים "בדיקה"', 'בדיקת ניהול admin' in lst and 'בדיקה' in lst, lst[:200])
            w = pg.evaluate("() => document.documentElement.scrollWidth <= window.innerWidth + 1")
            check(f'{name}: בלי גלילה לרוחב במסך אייפון', w)
            check(f'{name}: מתעדכן אוטומטית', 'מתעדכן כל דקה' in pg.inner_text('#adm-updated'))
            check(f'{name}: אין שגיאות JavaScript', not errs, errs[:2]); ctx.close()
            ctx = br.new_context(**dev); pg = ctx.new_page()
            check(f'{name}: משתמש רגיל מתחבר', bool(login(pg, 'user')))
            pg.evaluate("() => openSettings()"); pg.wait_for_timeout(2500)
            check(f'{name}: משתמש רגיל — אין כפתור "ניהול"', not pg.locator('#set-admin').is_visible())
            r = pg.evaluate("async () => { try { await window.__hdmRpc('hdm_admin_dashboard', { p_include_tests: true }); return 'got-data'; } catch(e) { return String(e && e.message || e); } }")
            check(f'{name}: משתמש רגיל שקורא לשרת ישירות — נדחה', 'HDM_NOT_ADMIN' in r, r)
            r = pg.evaluate("async () => { try { await window.__hdmRpc('hdm_admin_users', {}); return 'got-data'; } catch(e) { return String(e && e.message || e); } }")
            check(f'{name}: משתמש רגיל — רשימת המשתמשים נדחית', 'HDM_NOT_ADMIN' in r, r)
            pg.evaluate("() => hdmOpenAdmin()"); pg.wait_for_timeout(1500)
            check(f'{name}: משתמש רגיל — הלוח לא נפתח', not pg.locator('#admin-screen').is_visible()); ctx.close(); br.close()
finally:
    print(f'ניקוי: נשארו {cleanup()} משתמשי בדיקה', flush=True)
print(f'SUMMARY {sum(results)}/{len(results)} עברו'); sys.exit(0 if all(results) and results else 1)
