# =====================================================================
# חיים דרך מספרים — בדיקת דפדפן: הרשמה ואישור מייל במכשיר אחר, והשלמת פרופיל לחשבון קיים. Staging בלבד.
#
# תרחיש 1 — הרשמה במכשיר A (כל שלבי הטופס), אישור המייל והתחברות במכשיר B (דפדפן נקי, בלי שום נתון מקומי).
#   * בקשת ההרשמה ל-Supabase Auth נתפסת ולא נשלחת (בלי מיילים). המשתמש נוצר במסד בדיוק עם מה שהדף שלח
#     (אימייל, סיסמה, metadata), ומסומן כמאומת — כמו אחרי לחיצה על קישור האישור.
# תרחיש 2 — חשבון קיים שאין לו פרופיל (כמו המשתמשים שנתקעו): התחברות → מסך "השלמת הפרופיל" → כניסה לאפליקציה,
#   בלי חשבון חדש ובלי למחוק כלום.
# תרחיש 3 — אותו מכשיר (רגרסיה): הרשמה והתחברות באותו דפדפן.
# משתמשי בדיקה: hdm-sud-<ריצה>-*@gmail.com — נמחקים בסוף ובכל כישלון.
# משתני סביבה: STAGING_DB_URL (סוד), STAGING_PUBLISHABLE_KEY, PAGE
# =====================================================================
import base64, json, os, random, string, subprocess, sys, http.server, threading, functools, uuid
from playwright.sync_api import sync_playwright

DB = os.environ['STAGING_DB_URL']
KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', '')
PAGE = os.environ.get('PAGE', 'staging.html')
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
MAIL = f'life.through.numbers333+hdm-sud-{RUN}-'
PW = 'Sud-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(20))
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
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {str(got)[:240]}'), flush=True)

CRYPT = 'extensions.crypt' if sql("select count(*) from pg_proc where proname='crypt' and pronamespace='extensions'::regnamespace") != '0' else 'crypt'
SALT = CRYPT.replace('crypt', 'gen_salt')
CONSENT = sql("select public.hdm_required_terms_version()")

def create_auth_user(email, password, meta):
    sql(f"""begin;
      with u as (
        insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                                raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                                confirmation_token, recovery_token, email_change_token_new, email_change)
        values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', {lit(email)},
                {CRYPT}({lit(password)}, {SALT}('bf')), now(), '{{"provider":"email","providers":["email"]}}', {lit(json.dumps(meta, ensure_ascii=False))}::jsonb, now(), now(), '', '', '', '')
        returning id)
      insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
      select gen_random_uuid(), u.id::text, u.id, jsonb_build_object('sub', u.id::text, 'email', {lit(email)}, 'email_verified', true), 'email', now(), now(), now() from u;
      commit;""")

def acct(email):   # מזהה הפרופיל המקושר + האם יש פרופיל + האם נשארו פרטים ממתינים בחשבון
    return sql(f"""select coalesce(a.profile_id,'') || '|' ||
                     (select count(*) from public.docs d where d.collection='profiles' and d.id = a.profile_id) || '|' ||
                     coalesce((u.raw_user_meta_data ? 'hdm_pending_profile' and u.raw_user_meta_data->'hdm_pending_profile' <> 'null'::jsonb)::text, 'false')
                   from auth.users u left join public.hdm_accounts a on a.auth_user_id = u.id where u.email = {lit(email)}""")

def cleanup():
    sql(f"""begin;
      delete from public.docs d using public.hdm_accounts a, auth.users u
       where u.email like '{MAIL}%@gmail.com' and a.auth_user_id = u.id and d.collection = 'profiles' and d.id = a.profile_id;
      delete from public.hdm_profile_private p using public.hdm_accounts a, auth.users u
       where u.email like '{MAIL}%@gmail.com' and a.auth_user_id = u.id and p.profile_id = a.profile_id;
      delete from public.hdm_consents where user_id in (select id from auth.users where email like '{MAIL}%@gmail.com');
      delete from public.hdm_accounts where auth_user_id in (select id from auth.users where email like '{MAIL}%@gmail.com');
      delete from auth.users where email like '{MAIL}%@gmail.com';
      commit;""")
    return sql(f"select count(*) from auth.users where email like '{MAIL}%'")

html_dir = os.path.dirname(os.path.abspath(PAGE))
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=html_dir))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()
APP = f'http://127.0.0.1:{srv.server_address[1]}/{os.path.basename(PAGE)}'
errors, seen_hosts = [], set()

def new_page(br):
    c = br.new_context()
    c.add_init_script(f"try{{ localStorage.setItem('hdm_staging_publishable_key', {json.dumps(KEY)}); }}catch(e){{}}")
    pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e))); pg.on('request', lambda r: seen_hosts.add(r.url.split('/')[2]))
    pg.goto(APP); pg.wait_for_timeout(2500)
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; }catch(e){} }")
    return c, pg

def fill_profile(pg, name, birth, gender, city, email=None, pw=None):
    """שלבים 1–3 של הטופס. email/pw = None במצב השלמת פרופיל."""
    pg.fill('#su-name', name); pg.fill('#su-birth', birth); pg.select_option('#su-gender', gender); pg.fill('#su-city', city)
    if email is not None:
        pg.fill('#su-email', email); pg.fill('#su-pass', pw); pg.check('#su-consent')
    pg.click('#signup-screen .su-submit'); pg.wait_for_timeout(400)
    pg.set_input_files('#su2-photo-input', files=[{'name': 'p.png', 'mimeType': 'image/png', 'buffer': PNG}]); pg.wait_for_timeout(300)
    pg.select_option('#su2-looking', 'גברים'); pg.select_option('#su2-marital', 'רווק/ה')
    pg.select_option('#su2-children', 'לא'); pg.select_option('#su2-smoking', 'לא')
    pg.fill('#su2-agemin', '30'); pg.fill('#su2-agemax', '50')
    pg.click('#signup-step2 .su-submit'); pg.wait_for_timeout(400)
    pg.fill('#su3-first', name.split()[0]); pg.fill('#su3-last', name.split()[-1])
    pg.locator('#su3-chips .su-chip').first.click()
    pg.click('#signup-step3 .su-submit')

def login(pg, email, pw):
    pg.evaluate("() => openLogin()")
    pg.fill('#li-email', email); pg.fill('#li-pass', pw); pg.click('#li-submit')
    try: pg.wait_for_function("() => myId || document.getElementById('li-status').textContent.trim() || window.__hdmComplete", timeout=20000)
    except Exception: pass
    pg.wait_for_timeout(800)
    return pg.evaluate("() => ({ myId: myId, status: document.getElementById('li-status').textContent, complete: !!window.__hdmComplete, screen: (document.querySelector('.screen.active')||{}).id })")

def wait_entered(pg):
    try: pg.wait_for_function("() => myId && (document.querySelector('.screen.active')||{}).id === 'screen-match'", timeout=20000)
    except Exception: pass
    pg.wait_for_timeout(500)
    return pg.evaluate("() => ({ myId: myId, screen: (document.querySelector('.screen.active')||{}).id, s3: document.getElementById('su3-status').textContent })")

print(f'ריצה {RUN}', flush=True)
exit_code = 1
try:
    with sync_playwright() as p:
        br = p.chromium.launch()

        # ---------- תרחיש 1: הרשמה במכשיר A, התחברות במכשיר B ----------
        emA = f'{MAIL}cross@gmail.com'
        cA, pgA = new_page(br)
        captured = []
        def on_signup(route):
            body = json.loads(route.request.post_data or '{}'); captured.append(body)
            fake = {'id': str(uuid.uuid4()), 'aud': 'authenticated', 'role': 'authenticated', 'email': body.get('email'),
                    'user_metadata': body.get('data') or {}, 'app_metadata': {'provider': 'email'},
                    'identities': [{'id': 'x', 'provider': 'email'}], 'created_at': '2026-10-17T00:00:00Z'}
            route.fulfill(status=200, content_type='application/json', body=json.dumps(fake))   # כמו Supabase כשנדרש אישור מייל: בלי session
        pgA.route('**/auth/v1/signup**', on_signup)
        pgA.evaluate("() => chooseAuth('signup')")
        fill_profile(pgA, 'דנה כהן', '1992-04-12', 'אישה', 'חיפה', emA, PW)
        try: pgA.wait_for_function("() => /שלחנו אליך מייל/.test(document.getElementById('su3-status').textContent)", timeout=20000)
        except Exception: pass
        check('מכשיר A: אחרי ההרשמה — "שלחנו אליך מייל לאישור"', 'שלחנו אליך מייל' in pgA.inner_text('#su3-status'), pgA.inner_text('#su3-status'))
        meta = (captured[-1].get('data') or {}) if captured else {}
        pp = meta.get('hdm_pending_profile') or {}
        check('ההרשמה שולחת את הפרופיל לחשבון (לא רק למכשיר)', pp.get('birthdate') == '1992-04-12' and pp.get('currentName') == 'דנה כהן' and meta.get('hdm_terms') == CONSENT, list(meta.keys()))
        check('בהרשמה לא נוצר פרופיל במסד', sql("select count(*) from public.docs where collection='profiles' and data->>'currentName' = 'דנה כהן' and data->>'location' = 'חיפה'") == '0')
        # אישור המייל (כמו לחיצה על הקישור): המשתמש נוצר עם מה שהדף שלח, ומסומן מאומת
        create_auth_user(emA, captured[-1]['password'], meta)
        cA.close()

        cB, pgB = new_page(br)   # מכשיר אחר: אין שום נתון מקומי
        check('מכשיר B: אין נתוני הרשמה במכשיר', pgB.evaluate("() => Object.keys(localStorage).filter(k => k.indexOf('hdm_stg_pending_') === 0).length") == 0)
        r = login(pgB, emA, PW)
        e = wait_entered(pgB)
        check('מכשיר B: ההתחברות נכנסת ישר לאפליקציה (בלי "אין פרופיל")', e['screen'] == 'screen-match' and e['myId'] and 'אין פרופיל' not in r['status'], [r, e])
        a = acct(emA).split('|')
        check('במסד: החשבון מקושר לפרופיל, והפרופיל נשמר', len(a) == 3 and a[0] == e['myId'] and a[1] == '1', a)
        check('במסד: הפרטים הממתינים נמחקו מהחשבון', len(a) == 3 and a[2] == 'false', a)
        row = sql(f"select (data->>'currentName') || '|' || (data->>'location') || '|' || coalesce(data->>'lookingFor','') from public.docs where collection='profiles' and id={lit(e['myId'])}")
        check('הפרופיל זהה למה שמולא במכשיר A', row == 'דנה כהן|חיפה|גברים', row)
        check('תאריך הלידה נשמר בטבלה הפרטית (לא בפרופיל הגלוי)', sql(f"select (select birthdate::text from public.hdm_profile_private where profile_id={lit(e['myId'])}) || '|' || (select (data ? 'birthdate')::text from public.docs where collection='profiles' and id={lit(e['myId'])})") == '1992-04-12|false')
        check('האישור לתנאים נרשם (מתיבת הסימון בהרשמה)', sql(f"select count(*) from public.hdm_consents c join auth.users u on u.id=c.user_id where u.email={lit(emA)} and c.source='signup'") == '1')
        cB.close()

        # ---------- תרחיש 2: חשבון קיים בלי פרופיל (כמו המשתמשים שנתקעו) ----------
        emS = f'{MAIL}stuck@gmail.com'
        create_auth_user(emS, PW, {'hdm_terms': CONSENT})
        cS, pgS = new_page(br)
        r = login(pgS, emS, PW)   # התחברות ראשונה: החשבון מקושר, אין פרופיל
        a0 = acct(emS).split('|')
        check('חשבון תקוע: נפתח מסך "השלמת הפרופיל" (לא הודעת שגיאה)', r['complete'] and 'אין פרופיל' not in r['status'] and pgS.inner_text('#signup-screen .signup-title') == 'השלמת הפרופיל', r)
        st = pgS.evaluate("() => ({ email: document.getElementById('su-email').value, ro: document.getElementById('su-email').readOnly, pass: getComputedStyle(document.getElementById('su-f-pass')).display, consent: getComputedStyle(document.getElementById('su-f-consent')).display })")
        check('השלמה: האימייל של החשבון, בלי סיסמה ובלי הרשמה מחדש', st['email'] == emS and st['ro'] and st['pass'] == 'none' and st['consent'] == 'none', st)
        fill_profile(pgS, 'רון לוי', '1985-08-20', 'גבר', 'תל אביב')
        e = wait_entered(pgS)
        a = acct(emS).split('|')
        check('השלמה: נכנס לאפליקציה', e['screen'] == 'screen-match' and e['myId'] == a0[0], [e, a0])
        check('השלמה: אותו חשבון ואותו מזהה פרופיל — הפרופיל נשמר', a[0] == a0[0] and a[1] == '1', [a0, a])
        check('השלמה: לא נוצר חשבון נוסף', sql(f"select count(*) from auth.users where email={lit(emS)}") == '1' and sql(f"select count(*) from public.hdm_accounts a join auth.users u on u.id=a.auth_user_id where u.email={lit(emS)}") == '1')
        cS.close()
        cS2, pgS2 = new_page(br)   # התחברות חוזרת ממכשיר נוסף
        r = login(pgS2, emS, PW); e = wait_entered(pgS2)
        check('השלמה: התחברות ממכשיר נוסף — ישר לאפליקציה', e['screen'] == 'screen-match' and e['myId'] == a0[0], [r, e])
        cS2.close()

        # יציאה מההשלמה לא מוחקת כלום
        emX = f'{MAIL}leave@gmail.com'
        create_auth_user(emX, PW, {'hdm_terms': CONSENT})
        cX, pgX = new_page(br)
        r = login(pgX, emX, PW)
        pgX.evaluate("() => closeSignup()"); pgX.wait_for_timeout(500)
        check('יציאה מהשלמה: מתנתק, החשבון נשאר', not pgX.evaluate("() => window.__hdmComplete") and sql(f"select count(*) from auth.users where email={lit(emX)}") == '1')
        cX.close()

        # ---------- תרחיש 3: אותו מכשיר (רגרסיה) ----------
        emD = f'{MAIL}same@gmail.com'
        cD, pgD = new_page(br)
        capD = []
        def on_signup_d(route):
            body = json.loads(route.request.post_data or '{}'); capD.append(body)
            route.fulfill(status=200, content_type='application/json', body=json.dumps({'id': str(uuid.uuid4()), 'aud': 'authenticated', 'email': body.get('email'),
                          'user_metadata': body.get('data') or {}, 'identities': [{'id': 'x', 'provider': 'email'}]}))
        pgD.route('**/auth/v1/signup**', on_signup_d)
        pgD.evaluate("() => chooseAuth('signup')")
        fill_profile(pgD, 'מיכל אור', '1990-01-30', 'אישה', 'רעננה', emD, PW)
        pgD.wait_for_timeout(1500)
        create_auth_user(emD, capD[-1]['password'], {'hdm_terms': CONSENT})   # בלי metadata: נבדק שהגיבוי במכשיר עדיין עובד
        r = login(pgD, emD, PW); e = wait_entered(pgD)
        a = acct(emD).split('|')
        check('אותו מכשיר: נכנס לאפליקציה עם הפרופיל שמולא', e['screen'] == 'screen-match' and a[1] == '1' and sql(f"select data->>'location' from public.docs where collection='profiles' and id={lit(a[0])}") == 'רעננה', [r, e, a])
        cD.close()

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
