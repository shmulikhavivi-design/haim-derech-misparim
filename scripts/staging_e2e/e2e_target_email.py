# =====================================================================
# חיים דרך מספרים — בדיקה מול Staging בלבד: התראת מייל על חץ 🎯.
# דפדפן (staging.html) + פונקציית השליחה hdm-target-mailer שפרוסה ב-Staging עם מפתח Brevo לא תקף בכוונה —
# כך שום מייל לא יוצא (Brevo דוחה), וגם כתובות הבדיקה הן @example.invalid. משתמשי הבדיקה נמחקים בסוף ובכל כישלון.
# =====================================================================
import json, os, random, string, subprocess, sys, http.server, threading, functools, urllib.request, urllib.error
from playwright.sync_api import sync_playwright

DB = os.environ['STAGING_DB_URL']; KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', ''); PAGE = os.environ['PAGE_NEW']
FN = 'https://ousepgdvzammgkxkweze.supabase.co/functions/v1/hdm-target-mailer'; CRON = os.environ.get('HDM_CRON_SECRET', '')
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'tx{RUN}_'; MAIL = f'hdm-targetemail-{RUN}-'; DOM = 'example.invalid'
PW = 'Fl-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(18)) + '1!'
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
    return sql(f"""select (select count(*) from auth.users where email like '{MAIL}%') + (select count(*) from public.docs where id like '{PFX}%')
                 + (select count(*) from public.hdm_target_email_log where sender_profile like '{PFX}%' or recipient_profile like '{PFX}%')""")

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

def login(pg, app, email, hash_=''):
    pg.goto(app + hash_, wait_until='networkidle'); pg.wait_for_timeout(1200)
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
    pg.fill('#li-email', email); pg.fill('#li-pass', PW); pg.click('#li-submit')
    try: pg.wait_for_function("() => myId", timeout=20000)
    except Exception: pass
    pg.wait_for_timeout(1500)

def open_card(pg, pid):
    pg.evaluate("""async (id) => { const s = await dbCap.doc('profiles/' + id).get(); const p = s.data();
        currentMatchId = id; currentMatchData = p; renderMatchCard(p); go('screen-match'); }""", pid)
    pg.wait_for_timeout(300)
def outbox(uemail): return sql(f"select count(*) from public.hdm_target_email_outbox o join auth.users u on u.id = o.user_id where u.email = '{uemail}'")
def interests(a, b): return sql(f"select count(*) from public.docs where collection='interests' and id='{a}__{b}'")
def call_worker(secret):
    req = urllib.request.Request(FN, data=b'{}', method='POST', headers={'content-type': 'application/json', **({'x-hdm-cron': secret} if secret else {})})
    try:
        with urllib.request.urlopen(req, timeout=90) as r: return r.status, r.read().decode()[:300]
    except urllib.error.HTTPError as e: return e.code, e.read().decode()[:300]
    except Exception as e: return 0, str(e)[:200]
def setting_state(pg):
    return pg.evaluate("() => ({ st: document.getElementById('set-target-emails-state').textContent.trim(), aria: document.getElementById('set-target-emails').getAttribute('aria-checked'), shown: getComputedStyle(document.getElementById('screen-settings')).display !== 'none' })")

print(f'ריצה {RUN}', flush=True)
code = 1
try:
    s, sm = make_user('sender', 'אישה', 'גברים', '1986-04-12', 'אבי', 'שלום')
    s2, s2m = make_user('sender2', 'אישה', 'גברים', '1979-08-29', 'רונית', 'אור')
    r, rm = make_user('recipient', 'גבר', 'נשים', '1988-09-21', 'עמית', 'רז')
    sql(f"select public.hdm_admin_set_plan('{s}', 'basic')"); sql(f"select public.hdm_admin_set_plan('{s2}', 'vip')"); sql(f"select public.hdm_admin_set_plan('{r}', 'plus')")
    check('הכנה: התור ריק למקבל', outbox(rm) == '0', outbox(rm))
    APP = serve(PAGE)
    with sync_playwright() as pw_:
        br = pw_.chromium.launch()
        # ---- שולח (בסיסי) לוחץ 🎯 באפליקציה ----
        c, pg = newpage(br); login(pg, APP, sm)
        check('שולח: נכנס', pg.evaluate("() => myId") == s)
        open_card(pg, r); pg.click('#target-btn', force=True); pg.wait_for_timeout(2500)
        check('🎯 נשמר בשרת', interests(s, r) == '1', interests(s, r))
        check('נוצרה התראת מייל אחת למקבל', outbox(rm) == '1', outbox(rm))
        check('לא נוצרה התראה לשולח', outbox(sm) == '0', outbox(sm))
        for _ in range(3):
            pg.evaluate(f"() => window.__hdmRpc('hdm_remove_target', {{ p_target: '{r}' }})"); pg.wait_for_timeout(300)
            pg.evaluate(f"() => window.__hdmRpc('hdm_send_target', {{ p_target: '{r}' }})"); pg.wait_for_timeout(300)
        check('ביטול ושליחה ×3 — עדיין התראה אחת', outbox(rm) == '1', outbox(rm))
        pg.evaluate(f"() => Promise.all([0,1,2].map(() => window.__hdmRpc('hdm_send_target', {{ p_target: '{r}' }})))"); pg.wait_for_timeout(800)
        check('3 שליחות במקביל — עדיין התראה אחת', outbox(rm) == '1', outbox(rm))
        c.close()
        # ---- פונקציית השליחה ב-Staging (מפתח Brevo לא תקף בכוונה — שום מייל לא יוצא) ----
        st, body = call_worker('')
        check('פונקציית השליחה: בלי הסוד — 401', st == 401, (st, body))
        st, body = call_worker(CRON)
        check('פונקציית השליחה: עם הסוד — 200', st == 200, (st, body))
        row = sql(f"select o.attempts || '|' || coalesce(o.last_error,'') || '|' || (o.sent_at is null) from public.hdm_target_email_outbox o join auth.users u on u.id=o.user_id where u.email='{rm}'")
        check('כשל שליחה (Brevo דחה) — המייל נשאר בתור לניסיון חוזר, לא סומן כנשלח', row in ('1|brevo 401|true', '1|brevo 403|true'), row)
        check('כשל שליחה — החץ לא בוטל', interests(s, r) == '1', interests(s, r))
        # ---- מקבל: הגדרות ← התראות מייל ----
        c, pg = newpage(br); login(pg, APP, rm, '#notify'); pg.wait_for_timeout(2500)
        stt = setting_state(pg)
        check('קישור מהמייל (#notify) פותח את ההגדרות', stt['shown'], stt)
        check('ברירת מחדל: התראות פעילות', stt['st'].startswith('פעיל') and stt['aria'] == 'true', stt)
        pg.click('#set-target-emails'); pg.wait_for_timeout(1500)
        stt = setting_state(pg)
        check('לחיצה: התראות כבויות', stt['st'] == 'כבוי' and stt['aria'] == 'false', stt)
        check('הכיבוי נשמר בשרת', sql(f"select p.target_emails from public.hdm_target_email_prefs p join auth.users u on u.id=p.user_id where u.email='{rm}'") == 'f')
        # המייל שהיה בתור — לא יישלח אחרי כיבוי
        call_worker(CRON)
        row = sql(f"select coalesce(o.skipped,'') || '|' || (o.sent_at is null) from public.hdm_target_email_outbox o join auth.users u on u.id=o.user_id where u.email='{rm}'")
        check('אחרי כיבוי — המייל שבתור לא נשלח (דילוג)', row.startswith('opted_out') and row.endswith('|true'), row)
        c.close()
        c, pg = newpage(br); login(pg, APP, rm); pg.evaluate("() => openSettings()"); pg.wait_for_timeout(2000)
        stt = setting_state(pg)
        check('אחרי כניסה מחדש — עדיין כבוי', stt['st'] == 'כבוי', stt)
        c.close()
        # ---- שולח נוסף (VIP) כשההתראות כבויות ----
        c, pg = newpage(br); login(pg, APP, s2m); open_card(pg, r); pg.click('#target-btn', force=True); pg.wait_for_timeout(2500)
        check('VIP: 🎯 נשמר גם כשהמקבל כיבה התראות', interests(s2, r) == '1', interests(s2, r))
        check('VIP: לא נוצרה התראה חדשה', outbox(rm) == '1', outbox(rm))
        c.close()
        # ---- הדלקה מחדש ----
        c, pg = newpage(br); login(pg, APP, rm); pg.evaluate("() => openSettings()"); pg.wait_for_timeout(2000)
        pg.click('#set-target-emails'); pg.wait_for_timeout(1500)
        check('הדלקה מחדש', setting_state(pg)['st'].startswith('פעיל'), setting_state(pg))
        # ---- "מי סימן אותי" לפי המסלול — ללא שינוי (פלוס רואה) ----
        who = pg.evaluate("() => window.__hdmRpc('hdm_who_targeted_me').then(r => r.map(x => x.id).sort().join(','), e => 'err:' + (e.message||e))")
        check('פלוס (מקבל): "מי סימן אותי" באפליקציה — כמו קודם', who == ','.join(sorted([s, s2])), who)
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
