# =====================================================================
# חיים דרך מספרים — תקלת 22.10: הרשמה בדפדפן אחד, אישור מייל, כניסה מדפדפן אחר (כמו קישור שנפתח ב-Gmail / מכשיר אחר / כתובת אחרת).
# רץ על Staging בלבד, פעם עם הגרסה החיה (main) ופעם עם התיקון (PR #40). משתמשי בדיקה זמניים נמחקים בסוף. בלי חיוב.
# =====================================================================
import json, os, random, string, subprocess, sys, http.server, threading, functools, base64
from playwright.sync_api import sync_playwright
DB = os.environ['STAGING_DB_URL']; KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', '')
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6)); MAIL = f'life.through.numbers333+hdm-xdev-{RUN}-'
PW = 'Xdv-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(16)) + '1!'
def sql(q):
    r = subprocess.run(['psql', DB, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q], capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError('sql: ' + r.stderr.strip()[:200])
    return r.stdout.strip()
open('/tmp/p.png', 'wb').write(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAVklEQVR4nO3PQQ0AIBDAsIN/z2CCB0nZrSs0M2tm1nIu8MAAAAAAAAAAAAD/AwAAAAAAAPg3AAAAAAAAAH4FAAAAAAAAAB4AAAAAAAAAAAAAAAD8C4w/ASBzA3EPAAAAAElFTkSuQmCC'))
results = []
def check(name, ok, got=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {str(got)[:240]}'), flush=True)
def serve(page):
    d = os.path.dirname(os.path.abspath(page))
    s = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=d))
    s.RequestHandlerClass.log_message = lambda *a: None; threading.Thread(target=s.serve_forever, daemon=True).start()
    return f'http://127.0.0.1:{s.server_address[1]}/{os.path.basename(page)}'
def signup(pg, app, email):
    pg.goto(app, wait_until='networkidle'); pg.wait_for_timeout(1200)
    pg.evaluate("() => { try { var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; } catch(e){}; openSignup(); }"); pg.wait_for_timeout(600)
    pg.fill('#su-name', 'בדיקת מכשיר'); 
    pg.fill('#su-birth', '1990-05-17') if pg.get_attribute('#su-birth', 'type') == 'date' else pg.fill('#su-birth', '17/05/1990')
    pg.select_option('#su-gender', 'אישה'); pg.fill('#su-city', 'חיפה'); pg.fill('#su-email', email); pg.fill('#su-pass', PW)
    pg.check('#su-consent', force=True); pg.evaluate('submitSignup()'); pg.wait_for_timeout(900)
    pg.set_input_files('#su2-photo-input', '/tmp/p.png'); pg.wait_for_timeout(600)
    for sel in pg.evaluate("() => [...document.querySelectorAll('#signup-step2 select')].map(s => s.id)"):
        v = pg.evaluate("(id) => { const o = [...document.getElementById(id).options].find(o => o.value); return o ? o.value : '' }", sel)
        if v: pg.select_option('#' + sel, v)
    for iid, val in [('su2-height', '165'), ('su2-agemin', '30'), ('su2-agemax', '45'), ('su2-bio', 'בדיקה')]:
        try:
            if pg.locator('#' + iid).count() and pg.locator('#' + iid).is_visible() and pg.locator('#' + iid).evaluate('e => e.tagName') != 'SELECT': pg.fill('#' + iid, val)
        except Exception: pass
    pg.evaluate('submitSignupStep2()'); pg.wait_for_timeout(900)
    pg.fill('#su3-first', 'בדיקה'); pg.fill('#su3-last', 'מכשיר')
    if pg.locator('#su3-job').count(): pg.fill('#su3-job', 'בדיקות')
    pg.locator('#su3-chips .su-chip').first.click(); pg.evaluate('submitSignupStep3()'); pg.wait_for_timeout(7000)
    return pg.inner_text('#su3-status')
def login(pg, app, email):
    pg.goto(app, wait_until='networkidle'); pg.wait_for_timeout(1200)
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
    pg.fill('#li-email', email); pg.fill('#li-pass', PW); pg.click('#li-submit')
    try: pg.wait_for_function("() => myId || document.getElementById('li-status').textContent.trim()", timeout=20000)
    except Exception: pass
    pg.wait_for_timeout(1500)
    return pg.evaluate("() => myId"), pg.inner_text('#li-status')
def cleanup():
    sql(f"""begin;
      delete from public.docs where collection = 'profiles' and id in (select a.profile_id from public.hdm_accounts a join auth.users u on u.id = a.auth_user_id where u.email like '{MAIL}%');
      delete from public.hdm_consents where user_id in (select id from auth.users where email like '{MAIL}%');
      delete from public.hdm_accounts where auth_user_id in (select id from auth.users where email like '{MAIL}%');
      delete from auth.users where email like '{MAIL}%'; commit;""")
    return sql(f"select count(*) from auth.users where email like '{MAIL}%'")
try:
    with sync_playwright() as p:
        br = p.chromium.launch()
        for label, page, expect in [('הגרסה החיה (main)', os.environ['PAGE_OLD'], False), ('התיקון (PR #40)', os.environ['PAGE_NEW'], True)]:
            app = serve(page); email = f"{MAIL}{'old' if not expect else 'new'}@gmail.com"
            a = br.new_context(viewport={'width': 390, 'height': 844}); pa = a.new_page()
            st = signup(pa, app, email); a.close()
            needs = 'מייל' in st
            check(f'{label}: הרשמה בדפדפן א׳ → "שלחנו מייל לאישור"', needs, st)
            sql(f"update auth.users set email_confirmed_at = now() where email = '{email}' and email_confirmed_at is null")   # = לחיצה על קישור האישור
            b = br.new_context(viewport={'width': 390, 'height': 844}); pb = b.new_page()   # דפדפן ב׳: בלי שום נתון מקומי
            my, msg = login(pb, app, email); b.close()
            prof = sql(f"select count(*) from public.docs d join public.hdm_accounts acc on acc.profile_id = d.id join auth.users u on u.id = acc.auth_user_id where d.collection = 'profiles' and u.email = '{email}'")
            ok = bool(my) and prof == '1'
            if expect: check(f'{label}: כניסה מדפדפן ב׳ אחרי אישור → נכנסת, הפרופיל נשמר', ok, f'myId={my} profile={prof} msg={msg}')
            else: check(f'{label}: משחזר את התקלה (כניסה מדפדפן ב׳ נתקעת בלי פרופיל)', not ok, f'myId={my} profile={prof} msg={msg}')
            if not expect: print('הודעה בגרסה החיה: ' + msg.strip()[:160], flush=True)
            if expect:
                meta = sql(f"select coalesce(raw_user_meta_data->>'hdm_pending', 'null') from auth.users where email = '{email}'")
                check(f'{label}: העותק בשרת נמחק אחרי שהפרופיל נשמר', meta == 'null', meta[:80])
        br.close()
finally:
    left = cleanup(); print(f'ניקוי: נשארו {left} משתמשי בדיקה', flush=True)
print(f'SUMMARY {sum(results)}/{len(results)} עברו'); sys.exit(0 if all(results) and results else 1)
