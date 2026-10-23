# =====================================================================
# חיים דרך מספרים — בדיקת השקה (שלב ב׳) מול Staging בלבד. בלי חיוב ובלי מעבר לתשלום.
# בודקת שמשתמשים קיימים וחדשים נכנסים בלי תקלה בכל רגע של ההשקה:
#   1. לפני התקנון החדש: משתמש קיים נכנס עם גרסת ההשקה.
#   2. אחרי פרסום תקנון 2026-10-21 (זמני, נמחק בסוף):
#      א. משתמש קיים עם האתר הישן (הדקות שבין התקנת התקנון לעדכון האתר) — מסך "עדכנו את המסמכים" → אישור → בפנים.
#      ב. משתמש קיים עם גרסת ההשקה — אותו דבר, הפרופיל לא השתנה, וכניסה שנייה בלי מסך אישור.
#      ג. משתמש חדש: הרשמה בדפדפן א׳, אישור מייל, כניסה מדפדפן ב׳ → בפנים עם הפרופיל, בלי אישור כפול.
#      ד. סיסמה שגויה → נדחה בהודעה ברורה.
#      ה. מסך המנויים: בסיסי ₪29.90 ופלוס ₪48.90 עם כפתור הצטרפות; VIP "בקרוב" בלי אפשרות רכישה (גם לא בפנייה ישירה לשרת).
# משתמשי הבדיקה, האישורים וגרסת התנאים הזמנית נמחקים בסוף ובכל כישלון.
# =====================================================================
import base64, json, os, random, string, subprocess, sys, http.server, threading, functools
from playwright.sync_api import sync_playwright

DB = os.environ['STAGING_DB_URL']; KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', '')
PAGE_NEW, PAGE_OLD = os.environ['PAGE_NEW'], os.environ['PAGE_OLD']
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'gl{RUN}_'; MAIL = f'hdm-golive-{RUN}-'
PW = 'Glv-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(18)) + '1!'
NEWV = '2026-10-21'
if not KEY.startswith('sb_publishable_'): print('⛔ no publishable key'); sys.exit(2)
open('/tmp/p.png', 'wb').write(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAVklEQVR4nO3PQQ0AIBDAsIN/z2CCB0nZrSs0M2tm1nIu8MAAAAAAAAAAAAD/AwAAAAAAAPg3AAAAAAAAAH4FAAAAAAAAAB4AAAAAAAAAAAAAAAD8C4w/ASBzA3EPAAAAAElFTkSuQmCC'))

def sql(q):
    r = subprocess.run(['psql', DB, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q], capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError('sql: ' + r.stderr.strip()[:200])
    return r.stdout.strip()
results = []
def check(name, ok, got=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {str(got)[:260]}'), flush=True)

CRYPT = 'extensions.crypt' if sql("select count(*) from pg_proc where proname='crypt' and pronamespace='extensions'::regnamespace") != '0' else 'crypt'
SALT = CRYPT.replace('crypt', 'gen_salt')
inserted_version = [False]

def make_user(tag, version):
    pid, email = PFX + tag, f'{MAIL}{tag}@example.invalid'
    profile = json.dumps({'currentName': 'קיים ' + tag, 'birthdate': '1988-03-12', 'birthFirstName': 'א', 'birthLastName': 'ב', 'gender': 'גבר',
                          'lookingFor': 'נשים', 'location': 'חיפה', 'photoUrl': 'data:image/png;base64,iVBORw0KGgo=', 'createdAt': 0}, ensure_ascii=False)
    sql(f"""begin;
      with u as (
        insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                                created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
        values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', '{email}', {CRYPT}('{PW}', {SALT}('bf')), now(),
                '{{"provider":"email","providers":["email"]}}', '{{}}', now(), now(), '', '', '', '') returning id)
      , i as (insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
              select gen_random_uuid(), u.id::text, u.id, jsonb_build_object('sub', u.id::text, 'email', '{email}', 'email_verified', true), 'email', now(), now(), now() from u)
      , a as (insert into public.hdm_accounts (auth_user_id, profile_id) select id, '{pid}' from u)
      insert into public.hdm_consents (user_id, profile_id, version, source) select id, '{pid}', '{version}', 'signup' from u;
      insert into public.docs (collection, id, data) values ('profiles', '{pid}', $j${profile}$j$::jsonb);
      commit;""")
    return pid, email

def prof_sig(pid):
    return sql(f"select md5(concat_ws('|', data->>'currentName', data->>'birthdate', data->>'gender', data->>'location', data->>'photoUrl', data->>'lookingFor')) from public.docs where collection='profiles' and id='{pid}'")

def cleanup():
    sql(f"""begin;
      delete from public.hdm_checkouts where profile_id in (select profile_id from public.hdm_accounts a join auth.users u on u.id=a.auth_user_id where u.email like '{MAIL}%');
      delete from public.docs where collection = 'profiles' and (id like '{PFX}%' or id in (select a.profile_id from public.hdm_accounts a join auth.users u on u.id = a.auth_user_id where u.email like '{MAIL}%'));
      delete from public.hdm_consents where user_id in (select id from auth.users where email like '{MAIL}%');
      delete from public.hdm_accounts where auth_user_id in (select id from auth.users where email like '{MAIL}%');
      delete from auth.users where email like '{MAIL}%'; commit;""")
    if inserted_version[0]:
        others = sql(f"select count(*) from public.hdm_consents where version='{NEWV}'")
        if others == '0': sql(f"delete from public.hdm_terms_versions where version='{NEWV}'")
        else: print(f'אזהרה: נשארו {others} אישורים לגרסה {NEWV} — הגרסה לא נמחקה', flush=True)
    return sql(f"select (select count(*) from auth.users where email like '{MAIL}%') + (select count(*) from public.hdm_accounts where profile_id like '{PFX}%') + (select count(*) from public.hdm_terms_versions where version='{NEWV}' and {str(inserted_version[0]).lower()})")

def serve(page):
    d = os.path.dirname(os.path.abspath(page))
    s = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=d))
    s.RequestHandlerClass.log_message = lambda *a: None; threading.Thread(target=s.serve_forever, daemon=True).start()
    return f'http://127.0.0.1:{s.server_address[1]}/{os.path.basename(page)}'

errors = []
def newpage(br):
    c = br.new_context(viewport={'width': 390, 'height': 844})
    c.add_init_script(f"try{{ localStorage.setItem('hdm_staging_publishable_key', {json.dumps(KEY)}); }}catch(e){{}}")
    pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)[:200])); return c, pg

def login(pg, app, email, pw=None):
    pg.goto(app, wait_until='networkidle'); pg.wait_for_timeout(1200)
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
    pg.fill('#li-email', email); pg.fill('#li-pass', pw or PW); pg.click('#li-submit')
    try: pg.wait_for_function("() => myId || window.__hdmTermsGateOpen || document.getElementById('li-status').textContent.trim()", timeout=20000)
    except Exception: pass
    pg.wait_for_timeout(1500)

def gate_open(pg): return bool(pg.evaluate("() => !!window.__hdmTermsGateOpen"))
def accept_gate(pg):
    title = pg.inner_text('#tg-title')
    pg.check('#tg-consent', force=True); pg.click('#tg-accept', force=True)
    try: pg.wait_for_function("() => !window.__hdmTermsGateOpen", timeout=15000)
    except Exception: pass
    pg.wait_for_timeout(2500)
    return title
def my_id(pg): return pg.evaluate("() => (typeof myId !== 'undefined' && myId) || null")
def consent_of(email): return sql(f"select coalesce(string_agg(version, ',' order by version), '') from public.hdm_consents c join auth.users u on u.id=c.user_id where u.email='{email}'")

def signup(pg, app, email):
    pg.goto(app, wait_until='networkidle'); pg.wait_for_timeout(1200)
    pg.evaluate("() => { try { var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; } catch(e){}; openSignup(); }"); pg.wait_for_timeout(600)
    pg.fill('#su-name', 'בדיקת השקה')
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
    pg.fill('#su3-first', 'בדיקה'); pg.fill('#su3-last', 'השקה')
    if pg.locator('#su3-job').count(): pg.fill('#su3-job', 'בדיקות')
    pg.locator('#su3-chips .su-chip').first.click(); pg.evaluate('submitSignupStep3()'); pg.wait_for_timeout(7000)
    return pg.inner_text('#su3-status')

print(f'ריצה {RUN}', flush=True)
code = 1
try:
    R0 = sql("select public.hdm_required_terms_version()")
    print(f'גרסת התנאים הנדרשת ב-Staging לפני הבדיקה: {R0}', flush=True)
    if R0 == NEWV: raise RuntimeError(f'Staging כבר דורש {NEWV} — אי אפשר לדמות את המעבר')
    e1_pid, e1 = make_user('e1', R0)
    e2_pid, e2 = make_user('e2', R0)
    sig1 = prof_sig(e1_pid)
    NEW, OLD = serve(PAGE_NEW), serve(PAGE_OLD)
    with sync_playwright() as p:
        br = p.chromium.launch()
        # 1. לפני התקנון החדש — גרסת ההשקה
        c, pg = newpage(br); login(pg, NEW, e1)
        check('1. לפני התקנון החדש: משתמש קיים נכנס עם גרסת ההשקה, בלי מסך אישור', my_id(pg) == e1_pid and not gate_open(pg), [my_id(pg), gate_open(pg)])
        c.close()

        # 2. פרסום תקנון 2026-10-21 (כמו קובץ 09 ב-Production)
        if sql(f"select count(*) from public.hdm_terms_versions where version='{NEWV}'") == '0':
            sql(f"insert into public.hdm_terms_versions (version, requires_reconsent, note) values ('{NEWV}', true, 'e2e golive {RUN} — זמני')"); inserted_version[0] = True
        check('2. Staging דורש עכשיו את התקנון החדש', sql("select public.hdm_required_terms_version()") == NEWV)

        # 2א. האתר הישן (הפער בין התקנת התקנון לעדכון האתר)
        c, pg = newpage(br); login(pg, OLD, e2)
        g = gate_open(pg); t = accept_gate(pg) if g else ''
        check('2א. האתר הישן + תקנון חדש: מוצג "עדכנו את המסמכים"', g and 'עדכנו' in t, [g, t])
        check('2א. אחרי אישור — נכנס לאפליקציה', my_id(pg) == e2_pid and not gate_open(pg), my_id(pg))
        check('2א. האישור נשמר לגרסה החדשה (והישן נשמר)', consent_of(e2) == f'{R0},{NEWV}', consent_of(e2))
        c.close()

        # 2ב. גרסת ההשקה, משתמש קיים
        c, pg = newpage(br); login(pg, NEW, e1)
        g = gate_open(pg); t = accept_gate(pg) if g else ''
        check('2ב. גרסת ההשקה: משתמש קיים רואה "עדכנו את המסמכים"', g and 'עדכנו' in t, [g, t])
        check('2ב. אחרי אישור — נכנס לאפליקציה', my_id(pg) == e1_pid and not gate_open(pg), my_id(pg))
        check('2ב. האישור נשמר לגרסה החדשה', consent_of(e1) == f'{R0},{NEWV}', consent_of(e1))
        check('2ב. הפרופיל לא השתנה', prof_sig(e1_pid) == sig1)
        c.close()
        c, pg = newpage(br); login(pg, NEW, e1)
        check('2ב. כניסה נוספת (דפדפן אחר) — ישר לאפליקציה, בלי מסך אישור', my_id(pg) == e1_pid and not gate_open(pg), [my_id(pg), gate_open(pg)])

        # 2ה. מסך המנויים (אותו משתמש, גרסת ההשקה, בלי מצב תצוגה מקדימה)
        pg.evaluate("() => hdmOpenPlans()")
        try: pg.wait_for_function("() => hdmEnt && hdmEnt.forId === myId && !hdmEnt.error", timeout=15000)
        except Exception: pass
        pg.wait_for_timeout(800)
        txt = lambda sel: pg.inner_text(sel) if pg.locator(sel).count() else ''
        cb, cp, cv = txt('#hdm-plan-card-basic'), txt('#hdm-plan-card-plus'), txt('#hdm-plan-card-vip')
        check('2ה. בסיסי ₪29.90 עם כפתור הצטרפות', '29.90' in cb and pg.locator('#hdm-plan-buy-basic').count() == 1, cb[:160])
        check('2ה. פלוס ₪48.90 עם כפתור הצטרפות', '48.90' in cp and pg.locator('#hdm-plan-buy-plus').count() == 1, cp[:160])
        check('2ה. VIP "בקרוב" עם כפתור מושבת, בלי כפתור הצטרפות', 'בקרוב' in cv and pg.locator('#hdm-plan-soon-vip').is_disabled() and pg.locator('#hdm-plan-buy-vip').count() == 0, cv[:160])
        pg.locator('#hdm-plan-buy-plus').click(force=True); pg.wait_for_timeout(700)
        co = txt('#hdm-checkout-body')
        check('2ה. עמוד התשלום של פלוס: ₪48.90, חידוש אוטומטי, תיבת תקנון לא מסומנת, בלי לשונית VIP',
              '48.90' in co and 'חידוש' in co and not pg.locator('#hdm-co-accept').is_checked() and pg.locator('#hdm-co-tab-vip').count() == 0, co[:240])
        pg.evaluate("() => { try{ hdmCoSelect('vip'); }catch(e){} }"); pg.wait_for_timeout(200)
        check('2ה. אי אפשר לבחור VIP בעמוד התשלום', pg.evaluate("() => hdmCo.plan") != 'vip')
        res = pg.evaluate("""async () => { const t = await window.__sb.rpc('hdm_billing_status'); const bt = t && t.data && t.data.termsVersion;
            const r = await window.__sb.rpc('hdm_billing_start_checkout', { p_plan: 'vip', p_terms_version: bt || '', p_accept: true });
            return JSON.stringify({ err: r.error && (r.error.message + ' ' + (r.error.hint||'')), data: r.data }); }""")
        check('2ה. פנייה ישירה לשרת לרכישת VIP — נחסמת', 'HDM_BILLING_PLAN_SOON' in res or 'בקרוב' in res, res)
        check('2ה. לא נוצר שום ניסיון תשלום (לא נלחץ "לתשלום")', sql(f"select count(*) from public.hdm_checkouts where profile_id='{e1_pid}'") == '0')
        check('2ה. המסלול נשאר חינם', sql(f"select public.hdm_plan_of('{e1_pid}')") == 'free')
        c.close()

        # 2ג. משתמש חדש עם גרסת ההשקה: הרשמה בדפדפן א׳, אישור מייל, כניסה בדפדפן ב׳
        ne = f'{MAIL}new@example.invalid'
        c, pg = newpage(br); st = signup(pg, NEW, ne); c.close()
        check('2ג. הרשמה חדשה → "שלחנו מייל לאישור"', 'מייל' in st, st)
        sql(f"update auth.users set email_confirmed_at = now() where email = '{ne}' and email_confirmed_at is null")
        c, pg = newpage(br); login(pg, NEW, ne)
        g = gate_open(pg)
        prof = sql(f"select count(*) from public.docs d join public.hdm_accounts acc on acc.profile_id = d.id join auth.users u on u.id = acc.auth_user_id where d.collection='profiles' and u.email='{ne}'")
        check('2ג. כניסה מדפדפן אחר → בפנים עם הפרופיל, בלי לאשר שוב', bool(my_id(pg)) and prof == '1' and not g, [my_id(pg), prof, g])
        check('2ג. אישור התקנון של המשתמש החדש נשמר לגרסה החדשה', consent_of(ne) == NEWV, consent_of(ne))
        c.close()

        # 2ד. סיסמה שגויה
        c, pg = newpage(br); login(pg, NEW, e1, 'Wrong-' + PW)
        msg = pg.inner_text('#li-status')
        check('2ד. סיסמה שגויה → לא נכנס, הודעה ברורה', not my_id(pg) and len(msg.strip()) > 5, msg)
        c.close()
        check('אין שגיאות JavaScript', not errors, errors[:3])
        br.close()
    code = 0 if all(results) and results else 1
except Exception as e:
    print('ERROR', str(e)[:300], flush=True); code = 1
finally:
    try: left = cleanup()
    except Exception as e: left = 'שגיאה: ' + str(e)[:120]
    print(f'ניקוי: נשארו {left} רשומות בדיקה (כולל גרסת התנאים הזמנית)', flush=True)
    print(f'גרסת התנאים הנדרשת ב-Staging אחרי הבדיקה: {sql("select public.hdm_required_terms_version()")}', flush=True)
    print(f'SUMMARY {sum(results)}/{len(results)} עברו', flush=True)
sys.exit(code)
