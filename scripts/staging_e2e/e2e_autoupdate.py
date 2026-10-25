# =====================================================================
# חיים דרך מספרים — בדיקת דפדפן מול Staging בלבד: עדכון גרסה אוטומטי: אפליקציה פתוחה עוברת לגרסה החדשה אחרי פרסום (בלי לולאת רענון, בלי לאבד התחברות).
# משתמשי בדיקה נוצרים ישירות במסד (מאומתים, בלי שליחת מיילים), נמחקים בסוף ובכל כישלון. בלי חיובים.
# =====================================================================
import base64, json, os, random, string, subprocess, sys, http.server, threading, functools
from playwright.sync_api import sync_playwright

DB = os.environ['STAGING_DB_URL']; KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', ''); PAGE = os.environ['PAGE_NEW']
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'au{RUN}_'; MAIL = f'hdm-autoupd-{RUN}-'; DOM = 'example.invalid'
PW = 'Fl-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(18)) + '1!'
LABELS = ['❤️ התאמה גבוהה מאוד', '🩷 התאמה טובה', '💔 התאמה מאתגרת']
if not KEY.startswith('sb_publishable_'): print('⛔ no publishable key'); sys.exit(2)

def sql(q):
    r = subprocess.run(['psql', DB, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q], capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError('sql: ' + r.stderr.strip()[:200])
    return r.stdout.strip()
results = []
def check(name, ok, got=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {str(got)[:260]}'), flush=True)

CRYPT = 'extensions.crypt' if sql("select count(*) from pg_proc where proname='crypt' and pronamespace='extensions'::regnamespace") != '0' else 'crypt'
SALT = CRYPT.replace('crypt', 'gen_salt')
REQ = sql("select public.hdm_required_terms_version()")

def make_user(tag, gender, looking, birth, first, last, age=72, amin=70, amax=76):
    pid, email = PFX + tag, f'{MAIL}{tag}@{DOM}'
    profile = json.dumps({'currentName': 'בדיקה ' + tag, 'birthdate': birth, 'birthFirstName': first, 'birthLastName': last, 'gender': gender,
                          'lookingFor': looking, 'age': age, 'ageMin': amin, 'ageMax': amax, 'location': 'חיפה', 'photoUrl': 'data:image/png;base64,iVBORw0KGgo=', 'createdAt': 0}, ensure_ascii=False)
    sql(f"""begin;
      with u as (
        insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                                created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
        values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', '{email}', {CRYPT}('{PW}', {SALT}('bf')), now(),
                '{{"provider":"email","providers":["email"]}}', '{{}}', now(), now(), '', '', '', '') returning id)
      , i as (insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
              select gen_random_uuid(), u.id::text, u.id, jsonb_build_object('sub', u.id::text, 'email', '{email}', 'email_verified', true), 'email', now(), now(), now() from u)
      , a as (insert into public.hdm_accounts (auth_user_id, profile_id) select id, '{pid}' from u)
      insert into public.hdm_consents (user_id, profile_id, version, source) select id, '{pid}', '{REQ}', 'signup' from u;
      insert into public.docs (collection, id, data) values ('profiles', '{pid}', $j${profile}$j$::jsonb);
      commit;""")
    return pid, email

def cleanup():
    sql(f"""begin;
      do $d$ declare t text; begin
        foreach t in array array['hdm_subscription_events','hdm_chat_openings','hdm_subscriptions','hdm_hidden_profiles'] loop
          if to_regclass('public.' || t) is not null and exists (select 1 from information_schema.columns where table_schema='public' and table_name=t and column_name='profile_id') then
            execute format('delete from public.%I where profile_id like %L', t, '{PFX}%');
          end if; end loop; end $d$;
      delete from public.docs where id like '{PFX}%' or data::text like '%{PFX}%';
      delete from public.hdm_consents where user_id in (select id from auth.users where email like '{MAIL}%');
      delete from public.hdm_accounts where auth_user_id in (select id from auth.users where email like '{MAIL}%');
      delete from auth.users where email like '{MAIL}%'; commit;""")
    return sql(f"select (select count(*) from auth.users where email like '{MAIL}%') + (select count(*) from public.docs where id like '{PFX}%')")

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

def login(pg, app, email):
    pg.goto(app, wait_until='networkidle'); pg.wait_for_timeout(1200)
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
    pg.fill('#li-email', email); pg.fill('#li-pass', PW); pg.click('#li-submit')
    try: pg.wait_for_function("() => myId", timeout=20000)
    except Exception: pass
    try: pg.wait_for_function("() => hdmEnt && hdmEnt.forId === myId && !hdmEnt.error", timeout=15000)
    except Exception: pass
    pg.wait_for_timeout(1500)

def card_state(pg):
    for _ in range(8):
        try: pg.wait_for_function("() => currentMatchId && document.getElementById('match-pct').textContent.trim()", timeout=8000); break
        except Exception: pg.evaluate("() => { try{ navCard(1); }catch(e){} }"); pg.wait_for_timeout(1200)
    return pg.evaluate("""() => ({ id: (typeof currentMatchId!=='undefined' && currentMatchId) || null,
        pct: document.getElementById('match-pct').textContent.trim(),
        pctShown: getComputedStyle(document.getElementById('match-pct')).display !== 'none',
        whyShown: getComputedStyle(document.getElementById('match-why')).display !== 'none' && document.getElementById('match-why').textContent.trim() !== '',
        box: document.getElementById('hdm-card-plan').textContent.trim(), plan: hdmPlanId() })""")




import shutil, urllib.request, hashlib
print(f'ריצה {RUN}', flush=True)
code = 1
try:
    # האתר החי מחזיר תוכן זהה בכל בקשה (אחרת הבדיקה הייתה מרעננת סתם)
    ua = {'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1'}
    h = [hashlib.md5(urllib.request.urlopen(urllib.request.Request(f'https://haimderechmisparim.com/?hdmv={i}', headers=ua), timeout=30).read()).hexdigest() for i in range(3)]
    check('האתר החי: אותו תוכן ב-3 בקשות (אין הזרקה משתנה)', len(set(h)) == 1, h)
    d = '/tmp/autoupd'; shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    shutil.copy(PAGE, d + '/index.html')
    u, um = make_user('u', 'אישה', 'גברים', '1953-05-05', 'נועה', 'כ', age=73)
    APP = serve(d + '/index.html')
    with sync_playwright() as pw_:
        br = pw_.chromium.launch()
        c, pg = newpage(br); login(pg, APP, um)
        check('נכנסה', pg.evaluate("() => myId") == u)
        pg.wait_for_timeout(1500)
        pg.evaluate("() => { window.__hdmMarker = 'old'; }")
        pg.evaluate("() => window.__hdmCheckUpdate()"); pg.wait_for_timeout(2500)
        check('בלי פרסום חדש — אין רענון', pg.evaluate("() => window.__hdmMarker") == 'old')
        with open(d + '/index.html', 'a', encoding='utf-8') as f: f.write('\n<!-- deploy ' + RUN + ' -->\n')   # "פרסום" גרסה חדשה
        pg.evaluate("() => window.__hdmCheckUpdate()")
        try: pg.wait_for_function("() => window.__hdmMarker !== 'old'", timeout=15000)
        except Exception: pass
        pg.wait_for_timeout(3000)
        check('אחרי פרסום — האפליקציה עברה לגרסה החדשה', pg.evaluate("() => window.__hdmMarker") is None)
        check('הגרסה החדשה נטענה', ('deploy ' + RUN) in pg.content())
        try: pg.wait_for_function("() => myId", timeout=15000)
        except Exception: pass
        check('אחרי הרענון — עדיין מחוברת', pg.evaluate("() => myId") == u)
        pg.evaluate("() => { window.__hdmMarker = 'v2'; }")
        with open(d + '/index.html', 'a', encoding='utf-8') as f: f.write('\n<!-- deploy2 ' + RUN + ' -->\n')
        pg.wait_for_timeout(1500); pg.evaluate("() => window.__hdmCheckUpdate()"); pg.wait_for_timeout(3000)
        check('פרסום נוסף מיד אחרי — אין רענון שני בתוך 5 דקות (אין לולאה)', pg.evaluate("() => window.__hdmMarker") == 'v2')
        pg.evaluate("() => { try{ sessionStorage.setItem('hdm_updated_at', '0'); }catch(e){}; window.__hdmMarker = 'v3'; }")
        pg.evaluate("() => { const t = document.getElementById('li-email') || document.querySelector('textarea'); }")
        # בזמן הקלדה לא מרעננים
        pg.evaluate("""() => { const t = document.createElement('textarea'); t.id = 'tmp-typing'; document.body.appendChild(t); t.value = 'שלום'; t.focus(); }""")
        pg.evaluate("() => window.__hdmCheckUpdate()"); pg.wait_for_timeout(3000)
        check('בזמן הקלדה — לא מרעננים', pg.evaluate("() => window.__hdmMarker") == 'v3')
        c.close(); br.close()
    check('אין שגיאות JavaScript בדף', not errors, errors[:3])
    code = 0 if all(results) else 1
except Exception as e:
    print('ERROR', str(e)[:300], flush=True); code = 1
finally:
    try: left = cleanup(); print(f'ניקוי: נשארו {left} רשומות בדיקה', flush=True); code = code if left == '0' else 1
    except Exception as e: print('ניקוי נכשל', str(e)[:200], flush=True); code = 1
print(f'SUMMARY עברו {sum(results)} מתוך {len(results)}', flush=True)
sys.exit(code)
