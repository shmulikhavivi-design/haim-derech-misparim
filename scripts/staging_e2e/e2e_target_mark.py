# =====================================================================
# חיים דרך מספרים — בדיקת דפדפן מול Staging בלבד: 🎯 נשאר מסומן (גם אחרי רענון), בלי כפילויות, צ'אט רק בהדדיות.
# משתמשי בדיקה נוצרים ישירות במסד (מאומתים, בלי שליחת מיילים), נמחקים בסוף ובכל כישלון. בלי חיובים.
# =====================================================================
import base64, json, os, random, string, subprocess, sys, http.server, threading, functools
from playwright.sync_api import sync_playwright

DB = os.environ['STAGING_DB_URL']; KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', ''); PAGE = os.environ['PAGE_NEW']
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'tm{RUN}_'; MAIL = f'hdm-targetmark-{RUN}-'; DOM = 'example.invalid'
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

def make_user(tag, gender, looking, birth, first, last):
    pid, email = PFX + tag, f'{MAIL}{tag}@{DOM}'
    profile = json.dumps({'currentName': 'בדיקה ' + tag, 'birthdate': birth, 'birthFirstName': first, 'birthLastName': last, 'gender': gender,
                          'lookingFor': looking, 'location': 'חיפה', 'photoUrl': 'data:image/png;base64,iVBORw0KGgo=', 'createdAt': 0}, ensure_ascii=False)
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


def open_card(pg, pid):
    pg.evaluate("""async (id) => { const s = await dbCap.doc('profiles/' + id).get(); const p = s.data();
        currentMatchId = id; currentMatchData = p; renderMatchCard(p); go('screen-match'); }""", pid)
    pg.wait_for_timeout(300)
def marked(pg, expect, wait=6000):
    js = "() => document.getElementById('target-btn').classList.contains('is-targeted')"
    if expect:
        try: pg.wait_for_function(js, timeout=wait)
        except Exception: pass
    else: pg.wait_for_timeout(2500)
    return bool(pg.evaluate(js))
def press(pg):
    pg.click('#target-btn', force=True); pg.wait_for_timeout(2500)
def interests(a, b): return sql(f"select count(*) from public.docs where collection='interests' and id='{a}__{b}'")
def chats_of(a): return sql(f"select count(*) from public.docs where collection='chats' and data->'participants' ? '{a}'")

print(f'ריצה {RUN}', flush=True)
code = 1
try:
    a, am = make_user('basic', 'אישה', 'גברים', '1986-04-12', 'אבי', 'שלום')
    p_, pm = make_user('plus', 'אישה', 'גברים', '1993-03-08', 'גיל', 'שקד')
    v, vm = make_user('vip', 'אישה', 'גברים', '1979-08-29', 'רונית', 'אור')
    f, fm = make_user('free', 'אישה', 'גברים', '1990-07-03', 'דנה', 'כהן')
    t1, t1m = make_user('t1', 'גבר', 'נשים', '1988-09-21', 'עמית', 'רז')
    t2, _ = make_user('t2', 'גבר', 'נשים', '1985-01-11', 'יוסי', 'לוי')
    t3, _ = make_user('t3', 'גבר', 'נשים', '1987-02-12', 'דני', 'כץ')
    for pid, pl in [(a, 'basic'), (p_, 'plus'), (v, 'vip'), (t1, 'plus')]: sql(f"select public.hdm_admin_set_plan('{pid}', '{pl}')")
    APP = serve(PAGE)
    with sync_playwright() as pw_:
        br = pw_.chromium.launch()
        # ---- בסיסי ----
        c, pg = newpage(br); login(pg, APP, am)
        check('בסיסי: נכנס', pg.evaluate("() => myId") == a)
        open_card(pg, t1)
        check('בסיסי: לפני לחיצה — 🎯 לא מסומן', not marked(pg, False))
        press(pg)
        check('בסיסי: אחרי לחיצה — 🎯 מסומן', marked(pg, True))
        check('בסיסי: העניין נשמר בשרת (רשומה אחת)', interests(a, t1) == '1', interests(a, t1))
        check('בסיסי: אין צ\'אט בלי הדדיות', chats_of(a) == '0', chats_of(a))
        press(pg)
        check('בסיסי: לחיצה שנייה — עדיין מסומן', marked(pg, True))
        check('בסיסי: לחיצה שנייה — אין סימון כפול', interests(a, t1) == '1', interests(a, t1))
        pg.evaluate("() => Promise.all([0,1,2].map(() => window.__hdmRpc('hdm_send_target', { p_target: '" + t1 + "' })))"); pg.wait_for_timeout(800)
        check('בסיסי: 3 שליחות במקביל לשרת — עדיין רשומה אחת', interests(a, t1) == '1', interests(a, t1))
        open_card(pg, t2)
        check('בסיסי: פרופיל אחר — לא מסומן', not marked(pg, False))
        # כשל בשרת (מדומה בדפדפן בלבד): הודעת שגיאה, בלי אישור ובלי סימון
        pg.evaluate("""() => { window.__origRpc = window.__hdmRpc; window.__hdmRpc = function(n, a){ return n === 'hdm_send_target' ? Promise.reject(new Error('network down')) : window.__origRpc(n, a); }; }""")
        pg.click('#target-btn', force=True); pg.wait_for_timeout(700)
        hint = pg.inner_text('#match-hint')
        check('כשל רשת: מוצגת הודעת "לא נשמר" (לא אישור)', 'לא נשמר' in hint and 'נשמר —' not in hint.replace('לא נשמר —', ''), hint)
        check('כשל רשת: 🎯 לא מסומן', not marked(pg, False))
        check('כשל רשת: לא נשמר בשרת', interests(a, t2) == '0', interests(a, t2))
        pg.evaluate("""() => { window.__hdmRpc = function(n, a){ return n === 'hdm_send_target' ? Promise.resolve({}) : window.__origRpc(n, a); }; }""")
        pg.click('#target-btn', force=True); pg.wait_for_timeout(700)
        hint = pg.inner_text('#match-hint')
        check('תשובה לא מאושרת מהשרת: הודעת "לא נשמר", בלי סימון', 'לא נשמר' in hint and not marked(pg, False), hint)
        pg.evaluate("() => { window.__hdmRpc = window.__origRpc; }")
        open_card(pg, t1)
        check('אחרי כשל בפרופיל אחר — הפרופיל שסומן עדיין מסומן', marked(pg, True))
        c.close()
        c, pg = newpage(br); login(pg, APP, am); open_card(pg, t1)
        check('בסיסי: אחרי רענון וכניסה מחדש — 🎯 עדיין מסומן', marked(pg, True))
        c.close()
        # ---- הדדיות: T1 (פלוס) מסמן חזרה ----
        c, pg = newpage(br); login(pg, APP, t1m); open_card(pg, a)
        check('הדדי: לפני ש-T1 לחץ — אצלו לא מסומן', not marked(pg, False))
        press(pg)
        check('הדדי: אחרי 🎯 הדדי — נפתח צ\'אט אחד', chats_of(a) == '1', chats_of(a))
        check('הדדי: אצל T1 — 🎯 מסומן', marked(pg, True))
        c.close()
        # ---- פלוס ----
        c, pg = newpage(br); login(pg, APP, pm); open_card(pg, t2); press(pg)
        check('פלוס: אחרי לחיצה — 🎯 מסומן', marked(pg, True))
        check('פלוס: רשומה אחת, אין צ\'אט', interests(p_, t2) == '1' and chats_of(p_) == '0', [interests(p_, t2), chats_of(p_)])
        c.close()
        c, pg = newpage(br); login(pg, APP, pm); open_card(pg, t2)
        check('פלוס: אחרי כניסה מחדש — עדיין מסומן', marked(pg, True)); c.close()
        # ---- VIP ----
        c, pg = newpage(br); login(pg, APP, vm); open_card(pg, t3); press(pg)
        check('VIP: אחרי לחיצה — 🎯 מסומן', marked(pg, True))
        check('VIP: רשומה אחת, אין צ\'אט', interests(v, t3) == '1' and chats_of(v) == '0', [interests(v, t3), chats_of(v)])
        c.close()
        c, pg = newpage(br); login(pg, APP, vm); open_card(pg, t3)
        check('VIP: אחרי כניסה מחדש — עדיין מסומן', marked(pg, True)); c.close()
        # ---- חינם (ללא שינוי: חסום) ----
        c, pg = newpage(br); login(pg, APP, fm); open_card(pg, t1); press(pg)
        check('חינם: 🎯 חסום — לא מסומן ולא נשמר', not marked(pg, False) and interests(f, t1) == '0', interests(f, t1))
        c.close()
        br.close()
    check('אין שגיאות JavaScript בדף', not errors, errors[:3])
    code = 0 if all(results) else 1
except Exception as e:
    print('ERROR', str(e)[:300], flush=True); code = 1
finally:
    try: left = cleanup(); print(f'ניקוי: נשארו {left} רשומות בדיקה', flush=True); code = code if left == '0' else 1
    except Exception as e: print('ניקוי נכשל', str(e)[:200], flush=True); code = 1
print(f'SUMMARY עברו {sum(results)} מתוך {len(results)}', flush=True)
sys.exit(code)
