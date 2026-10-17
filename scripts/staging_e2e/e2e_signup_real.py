# =====================================================================
# חיים דרך מספרים — בדיקת הרשמה אמיתית מול Supabase Auth של Staging (בלי עקיפות):
#   מכשיר A: טופס הרשמה מלא → בקשת הרשמה אמיתית → Supabase שולח מייל אישור אמיתי
#   → אישור דרך נקודת האימות האמיתית של Supabase (/auth/v1/verify — אותה בקשה שהקישור במייל מבצע)
#   → מכשיר B (דפדפן נקי): התחברות → כניסה לאפליקציה עם הפרופיל שמולא במכשיר A.
# המייל נשלח לכתובת של האפליקציה עצמה (life.through.numbers333+…@gmail.com), לא לאף משתמש.
# המשתמש נמחק בסוף ובכל כישלון. Staging בלבד.
# משתני סביבה: STAGING_DB_URL (סוד), STAGING_PUBLISHABLE_KEY, PAGE
# =====================================================================
import base64, json, os, random, string, subprocess, sys, http.server, threading, functools, urllib.request, urllib.error
from playwright.sync_api import sync_playwright

STG = 'https://ousepgdvzammgkxkweze.supabase.co'
DB = os.environ['STAGING_DB_URL']
KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', '')
PAGE = os.environ.get('PAGE', 'staging.html')
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
EMAIL = f'life.through.numbers333+hdm-real-{RUN}@gmail.com'
PW = 'Real-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(20))
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')
if not KEY.startswith('sb_publishable_'):
    print('⛔ STAGING_PUBLISHABLE_KEY חסר או לא ציבורי'); sys.exit(2)

def sql(q):
    r = subprocess.run(['psql', DB, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q], capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError('sql: ' + r.stderr.strip()[:300])
    return r.stdout.strip()
def lit(s): return "'" + str(s).replace("'", "''") + "'"

results = []
def check(name, ok, got=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {str(got)[:300]}'), flush=True)

def cleanup():
    sql(f"""begin;
      delete from public.docs d using public.hdm_accounts a, auth.users u
       where u.email like 'life.through.numbers333+hdm-real-%' and a.auth_user_id = u.id and d.collection = 'profiles' and d.id = a.profile_id;
      delete from public.hdm_profile_private p using public.hdm_accounts a, auth.users u
       where u.email like 'life.through.numbers333+hdm-real-%' and a.auth_user_id = u.id and p.profile_id = a.profile_id;
      delete from public.hdm_consents where user_id in (select id from auth.users where email like 'life.through.numbers333+hdm-real-%');
      delete from public.hdm_accounts where auth_user_id in (select id from auth.users where email like 'life.through.numbers333+hdm-real-%');
      delete from auth.users where email like 'life.through.numbers333+hdm-real-%';
      commit;""")
    return sql("select count(*) from auth.users where email like 'life.through.numbers333+hdm-real-%'")

def verify(token_hash, typ='signup', want_body=False):
    rq = urllib.request.Request(STG + '/auth/v1/verify', data=json.dumps({'type': typ, 'token_hash': token_hash}).encode(),
                                headers={'apikey': KEY, 'Content-Type': 'application/json'}, method='POST')
    try:
        r = urllib.request.urlopen(rq, timeout=30)
        return json.loads(r.read()) if want_body else r.status
    except urllib.error.HTTPError as e: return f'{e.code} {e.read()[:200]!r}'

def token_login(pw):
    rq = urllib.request.Request(STG + '/auth/v1/token?grant_type=password', data=json.dumps({'email': EMAIL, 'password': pw}).encode(),
                                headers={'apikey': KEY, 'Content-Type': 'application/json'}, method='POST')
    try: return urllib.request.urlopen(rq, timeout=30).status
    except urllib.error.HTTPError as e: return e.code

html_dir = os.path.dirname(os.path.abspath(PAGE))
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=html_dir))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()
APP = f'http://127.0.0.1:{srv.server_address[1]}/{os.path.basename(PAGE)}'
errors, seen_hosts = [], set()

def new_page(br):
    c = br.new_context()
    pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e))); pg.on('request', lambda r: seen_hosts.add(r.url.split('/')[2]))
    pg.goto(APP); pg.wait_for_timeout(2500)
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; }catch(e){} }")
    return c, pg

def login(pg, pw=None):
    pg.evaluate("() => openLogin()")
    pg.fill('#li-email', EMAIL); pg.fill('#li-pass', pw or PW); pg.click('#li-submit')
    try: pg.wait_for_function("() => (myId && (document.querySelector('.screen.active')||{}).id === 'screen-match') || document.getElementById('li-status').textContent.trim() || window.__hdmComplete", timeout=25000)
    except Exception: pass
    pg.wait_for_timeout(800)
    return pg.evaluate("() => ({ myId: myId, status: document.getElementById('li-status').textContent, complete: !!window.__hdmComplete, screen: (document.querySelector('.screen.active')||{}).id })")

print(f'ריצה {RUN}', flush=True)
exit_code = 1
try:
    with sync_playwright() as p:
        br = p.chromium.launch()
        # ---- מכשיר A: הרשמה אמיתית ----
        cA, pgA = new_page(br)
        resp = []
        pgA.on('response', lambda r: resp.append(r.status) if '/auth/v1/signup' in r.url else None)
        pgA.evaluate("() => chooseAuth('signup')")
        pgA.fill('#su-name', 'נגה ברק'); pgA.fill('#su-birth', '1991-06-15'); pgA.select_option('#su-gender', 'אישה'); pgA.fill('#su-city', 'נתניה')
        pgA.fill('#su-email', EMAIL); pgA.fill('#su-pass', PW); pgA.check('#su-consent')
        pgA.click('#signup-screen .su-submit'); pgA.wait_for_timeout(400)
        pgA.set_input_files('#su2-photo-input', files=[{'name': 'p.png', 'mimeType': 'image/png', 'buffer': PNG}]); pgA.wait_for_timeout(300)
        for sel, v in [('#su2-looking', 'גברים'), ('#su2-marital', 'רווק/ה'), ('#su2-children', 'לא'), ('#su2-smoking', 'לא')]: pgA.select_option(sel, v)
        pgA.fill('#su2-agemin', '30'); pgA.fill('#su2-agemax', '45')
        pgA.click('#signup-step2 .su-submit'); pgA.wait_for_timeout(400)
        pgA.fill('#su3-first', 'נגה'); pgA.fill('#su3-last', 'ברק'); pgA.locator('#su3-chips .su-chip').first.click()
        pgA.click('#signup-step3 .su-submit')
        try: pgA.wait_for_function("() => document.getElementById('su3-status').textContent.trim() || myId", timeout=30000)
        except Exception: pass
        msg = pgA.inner_text('#su3-status')
        check('הרשמה אמיתית: Supabase קיבל את ההרשמה', resp and resp[-1] == 200, resp)
        check('מכשיר A: "שלחנו אליך מייל לאישור" (אישור מייל פעיל ב-Staging)', 'שלחנו אליך מייל' in msg, msg)
        u = sql(f"select (email_confirmed_at is null)::text || '|' || (raw_user_meta_data->'hdm_pending_profile'->>'currentName') || '|' || (coalesce(confirmation_token,'') <> '')::text || '|' || (confirmation_sent_at is not null)::text from auth.users where email = {lit(EMAIL)}")
        check('במסד: המשתמש נוצר, לא מאומת, עם הפרופיל הממתין, ונשלח מייל אישור', u == 'true|נגה ברק|true|true', u)
        check('במסד: עוד לא נוצר פרופיל', sql(f"select count(*) from public.hdm_accounts a join auth.users u on u.id=a.auth_user_id where u.email={lit(EMAIL)}") == '0')
        cA.close()

        # ---- התחברות לפני אישור המייל ----
        cP, pgP = new_page(br)
        r = login(pgP)
        check('לפני אישור המייל: "צריך קודם לאשר את כתובת האימייל"', 'לאשר את כתובת האימייל' in r['status'] and not r['myId'], r)
        cP.close()

        # ---- אישור המייל: אותה בקשה שהקישור במייל מבצע ----
        th = sql(f"select confirmation_token from auth.users where email = {lit(EMAIL)}")
        v = verify(th)
        check('אישור המייל דרך נקודת האימות של Supabase', v == 200, v)
        check('במסד: המשתמש מאומת', sql(f"select (email_confirmed_at is not null)::text from auth.users where email = {lit(EMAIL)}") == 'true')

        # ---- מכשיר B: דפדפן נקי ----
        cB, pgB = new_page(br)
        r = login(pgB)
        check('מכשיר B: ההתחברות נכנסת ישר לאפליקציה', r['screen'] == 'screen-match' and r['myId'] and 'אין פרופיל' not in r['status'] and not r['complete'], r)
        row = sql(f"""select a.profile_id || '|' || (d.data->>'currentName') || '|' || (d.data->>'location') || '|' ||
                         coalesce((u.raw_user_meta_data->'hdm_pending_profile') <> 'null'::jsonb, false)::text
                      from auth.users u join public.hdm_accounts a on a.auth_user_id = u.id
                      join public.docs d on d.collection = 'profiles' and d.id = a.profile_id where u.email = {lit(EMAIL)}""")
        parts = row.split('|')
        check('במסד: פרופיל נשמר עם מה שמולא במכשיר A', len(parts) == 4 and parts[0] == r['myId'] and parts[1] == 'נגה ברק' and parts[2] == 'נתניה', row)
        check('במסד: הפרטים הממתינים נמחקו מהחשבון', len(parts) == 4 and parts[3] == 'false', row)
        check('האישור לתנאים נרשם מההרשמה', sql(f"select count(*) from public.hdm_consents c join auth.users u on u.id=c.user_id where u.email={lit(EMAIL)}") == '1')
        PID = r['myId']

        # ---- אבטחה: מה נשמר ואיפה ----
        check('אבטחה: תאריך הלידה והשם מלידה לא בפרופיל הגלוי', sql(f"select (data ?| array['birthdate','birthFirstName','birthLastName'])::text from public.docs where collection='profiles' and id={lit(PID)}") == 'false')
        check('אבטחה: הפרטים האישיים נמחקו מנתוני החשבון אחרי יצירת הפרופיל', sql(f"select coalesce(raw_user_meta_data->'hdm_pending_profile','null'::jsonb)::text from auth.users where email={lit(EMAIL)}") == 'null')
        check('אבטחה: נשמר רק מזהה הפרופיל שהשרת קבע (לא מזהה שהדפדפן בחר בשם משתמש אחר)', sql(f"select count(*) from public.hdm_accounts where profile_id={lit(PID)}") == '1')

        # ---- התנתקות והתחברות חוזרת ----
        pgB.evaluate("() => logoutToAuthChoice()"); pgB.wait_for_timeout(800)
        out = pgB.evaluate("() => ({ myId: myId, choice: getComputedStyle(document.getElementById('auth-choice-screen')).display })")
        check('התנתקות: יוצא מהחשבון ומוצג מסך ההרשמה/התחברות', not out['myId'] and out['choice'] != 'none', out)
        pgB.reload(); pgB.wait_for_timeout(3000)
        check('אחרי התנתקות ורענון: לא מתחבר אוטומטית', not pgB.evaluate("() => myId"))
        pgB.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; }catch(e){} }")
        r3 = login(pgB)
        check('התחברות חוזרת: אותו פרופיל', r3['screen'] == 'screen-match' and r3['myId'] == PID, r3)
        pgB.reload(); pgB.wait_for_timeout(5000)
        check('אחרי רענון: נשאר מחובר', pgB.evaluate("() => myId") == PID, pgB.evaluate("() => myId"))

        # ---- שכחתי סיסמה: בקשה אמיתית, Supabase שולח מייל ----
        pgB.evaluate("() => logoutToAuthChoice()"); pgB.wait_for_timeout(600)
        pgB.evaluate("() => { openLogin(); hdmOpenForgot(); }"); pgB.wait_for_timeout(300)
        pgB.fill('#fp-email', EMAIL); pgB.click('#fp-submit')
        try: pgB.wait_for_function("() => document.getElementById('fp-status').textContent.trim()", timeout=20000)
        except Exception: pass
        fs = pgB.inner_text('#fp-status')
        rs = sql(f"select (recovery_sent_at > now() - interval '5 minutes')::text || '|' || (coalesce(recovery_token,'') <> '')::text from auth.users where email={lit(EMAIL)}")
        check('שכחתי סיסמה: Supabase שלח מייל איפוס (נרשם במסד)', rs == 'true|true', [fs, rs])
        check('שכחתי סיסמה: הודעה למשתמש', bool(fs.strip()) and 'נכשל' not in fs, fs)
        cB.close()

        # ---- הקישור מהמייל: אימות אמיתי → מסך סיסמה חדשה → כניסה ----
        tk = verify(sql(f"select recovery_token from auth.users where email={lit(EMAIL)}"), 'recovery', True)
        check('קישור האיפוס: אימות דרך Supabase', isinstance(tk, dict) and tk.get('access_token'), tk)
        cR, pgR = new_page(br)
        pgR.goto(APP + '?hdm_reset=1#access_token=' + tk['access_token'] + '&refresh_token=' + tk['refresh_token'] + '&expires_in=3600&token_type=bearer&type=recovery')
        try: pgR.wait_for_function("() => { const i = document.getElementById('rp-pass'); return i && i.offsetParent !== null; }", timeout=15000)
        except Exception: pass
        check('קישור האיפוס פותח את מסך הסיסמה החדשה', pgR.evaluate("() => { const i = document.getElementById('rp-pass'); return !!(i && i.offsetParent !== null); }"))
        NEWPW = 'New-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(16))
        pgR.fill('#rp-pass', NEWPW); pgR.fill('#rp-pass2', NEWPW); pgR.click('#rp-submit')
        try: pgR.wait_for_function(f"() => myId === '{PID}'", timeout=20000)
        except Exception: pass
        pgR.wait_for_timeout(800)
        check('אחרי הסיסמה החדשה: נכנס לאותו פרופיל', pgR.evaluate("() => myId") == PID, pgR.evaluate("() => myId"))
        check('הסיסמה החדשה עובדת והישנה לא', token_login(NEWPW) == 200 and token_login(PW) == 400, [token_login(NEWPW), token_login(PW)])
        cR.close()
        cN, pgN = new_page(br)
        r4 = login(pgN, NEWPW)
        check('התחברות ממכשיר נוסף עם הסיסמה החדשה: אותו פרופיל, הנתונים נשמרו', r4['myId'] == PID and sql(f"select (data->>'currentName') || '|' || (data->>'location') from public.docs where collection='profiles' and id={lit(PID)}") == 'נגה ברק|נתניה', r4)
        cN.close()
        check('סיסמה שגויה נדחית', token_login('Wrong-password-123') == 400)


        check('אין שגיאות JavaScript בדף', not errors, errors[:3])
        check('הדף פנה רק ל-Staging (לא לפרויקט הפעיל)', not any('qtspzigjlbtckqfyaubp' in h for h in seen_hosts), sorted(seen_hosts))
        br.close()
    exit_code = 0 if results and all(results) else 1
except Exception as e:
    print('FAIL שגיאה בבדיקה: ' + str(e)[:400], flush=True); exit_code = 1
finally:
    left = cleanup()
    print(f'ניקוי: נשארו {left} רשומות בדיקה', flush=True)
    if left != '0': exit_code = 1
    srv.shutdown()
print(f'SUMMARY {sum(results)}/{len(results)} passed', flush=True)
sys.exit(exit_code)
