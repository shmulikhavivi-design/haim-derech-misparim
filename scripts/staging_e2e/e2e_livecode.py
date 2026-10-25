# =====================================================================
# חיים דרך מספרים — בדיקת דפדפן מול Staging בלבד: הקוד שפורסם בפועל (index.html מהאתר החי) מול Staging: זרימה טבעית, טעינה מחדש.
# משתמשי בדיקה נוצרים ישירות במסד (מאומתים, בלי שליחת מיילים), נמחקים בסוף ובכל כישלון. בלי חיובים.
# =====================================================================
import base64, json, os, random, string, subprocess, sys, http.server, threading, functools
from playwright.sync_api import sync_playwright

DB = os.environ['STAGING_DB_URL']; KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', ''); PAGE = os.environ['PAGE_NEW']
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'lv{RUN}_'; MAIL = f'hdm-livecode-{RUN}-'; DOM = 'example.invalid'
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



def card_id(pg):
    try: pg.wait_for_function("() => typeof currentMatchId !== 'undefined' && currentMatchId", timeout=15000)
    except Exception: pass
    return pg.evaluate("() => (typeof currentMatchId !== 'undefined' && currentMatchId) || null")
def goto_card(pg, pid, tries=12):
    for _ in range(tries):
        if card_id(pg) == pid: return True
        pg.evaluate("() => { try{ navCard(1); }catch(e){} }"); pg.wait_for_timeout(900)
    return card_id(pg) == pid
def marked(pg): return bool(pg.evaluate("() => { const b = document.getElementById('target-btn'); return !!(b && b.classList.contains('is-targeted')); }"))
def interests(a, b): return sql(f"select count(*) from public.docs where collection='interests' and id='{a}__{b}'")
def pct(pg):
    try: pg.wait_for_function("() => document.getElementById('match-pct').textContent.trim()", timeout=10000)
    except Exception: pass
    return pg.evaluate("() => document.getElementById('match-pct').textContent.trim()")

print(f'ריצה {RUN}', flush=True)
code = 1
try:
    import urllib.request
    live = urllib.request.urlopen('https://haimderechmisparim.com/?v=' + RUN, timeout=30).read().decode('utf-8')
    STG_URL = 'https://ousepgdvzammgkxkweze.supabase.co'
    n1 = live.count("'https://qtspzigjlbtckqfyaubp.supabase.co'")
    live = live.replace("'https://qtspzigjlbtckqfyaubp.supabase.co'", "'" + STG_URL + "'")
    live = __import__('re').sub(r"var STAGING_PUBLISHABLE_KEY = 'sb_publishable_[A-Za-z0-9_-]+'", "var STAGING_PUBLISHABLE_KEY = '" + KEY + "'", live)
    check('הקוד החי נטען מ-haimderechmisparim.com והופנה ל-Staging', n1 == 1 and 'hdmSetTargetMark' in live and '🔒 🎯 ושיחות' in live and 'qtspzigjlbtckqfyaubp' not in live.split('SUPABASE_URL')[1][:200], n1)
    os.makedirs('/tmp/livecode', exist_ok=True); open('/tmp/livecode/index.html', 'w', encoding='utf-8').write(live)
    # כמו ב-Production: הבעלים (בסיסי) מוסתר; לקוחה חינם; גבר בסיסי גלוי; כולם בגילאים ייחודיים כדי שרק הם יופיעו בתור
    own, ownm = make_user('owner', 'גבר', 'נשים', '1954-02-02', 'שמואל', 'ח')
    w1, w1m = make_user('w1', 'אישה', 'גברים', '1953-05-05', 'נועה', 'כ', age=73)
    w2, _ = make_user('w2', 'אישה', 'גברים', '1952-06-06', 'רות', 'ל', age=74)
    m1, _ = make_user('m1', 'גבר', 'נשים', '1953-07-07', 'דוד', 'מ', age=73)
    sql(f"select public.hdm_admin_set_plan('{own}', 'basic')"); sql(f"select public.hdm_admin_set_plan('{m1}', 'basic')")
    sql(f"insert into public.hdm_hidden_profiles (profile_id) values ('{own}') on conflict do nothing")
    APP = serve('/tmp/livecode/index.html')
    with sync_playwright() as pw_:
        br = pw_.chromium.launch()
        # ---- 1. בעלים בסיסי ומוסתר: 🎯 בזרימה הטבעית ----
        c, pg = newpage(br); login(pg, APP, ownm)
        check('1. הבעלים (בסיסי, מוסתר) נכנס', pg.evaluate("() => myId") == own)
        check('1. כרטיס W1 מופיע בתור', goto_card(pg, w1), card_id(pg))
        check('1. לפני לחיצה — לא מסומן', not marked(pg))
        pg.click('#target-btn'); pg.wait_for_timeout(1500)
        h = pg.inner_text('#match-hint')
        check('1. אחרי לחיצה — מסומן, והודעת אישור', marked(pg) and 'נשמר' in h and 'לא נשמר' not in h, [marked(pg), h])
        check('1. נשמר במסד (רשומה אחת)', interests(own, w1) == '1', interests(own, w1))
        pg.wait_for_timeout(6000)
        check('1. 6 שניות אחרי — עדיין מסומן (לא נעלם)', marked(pg))
        pg.reload(wait_until='networkidle'); pg.wait_for_timeout(2500)
        check('1. רענון הדף (F5) — נשאר מחובר', pg.evaluate("() => myId") == own)
        check('1. אחרי רענון — חזרה לכרטיס W1 והוא מסומן', goto_card(pg, w1) and (pg.wait_for_timeout(2500) or marked(pg)), [card_id(pg), marked(pg)])
        check('1. W2 (לא סומן) — לא מסומן', goto_card(pg, w2) and (pg.wait_for_timeout(2500) or not marked(pg)), [card_id(pg), marked(pg)])
        c.close()
        c, pg = newpage(br); login(pg, APP, ownm)
        check('1. כניסה מחדש (דפדפן חדש) — W1 מסומן', goto_card(pg, w1) and (pg.wait_for_timeout(2500) or marked(pg)), [card_id(pg), marked(pg)])
        check('1. אין סימון כפול', interests(own, w1) == '1', interests(own, w1))
        c.close()
        # ---- 2. לקוחה חינם ----
        c, pg = newpage(br); login(pg, APP, w1m)
        check('2. W1 (חינם) נכנסה', pg.evaluate("() => myId") == w1)
        cid = card_id(pg)
        check('2. הבעלים המוסתר לא מוצג לה', cid != own, cid)
        check('2. מוצג לה הגבר הגלוי M1', goto_card(pg, m1), card_id(pg))
        p1 = pct(pg)
        check('2. רמת התאמה מוצגת (❤️/🩷/💔)', p1 in ['❤️ התאמה גבוהה מאוד', '🩷 התאמה טובה', '💔 התאמה מאתגרת'], p1)
        pg.reload(wait_until='networkidle'); pg.wait_for_timeout(2500)
        check('2. אחרי רענון — רמת התאמה עדיין מוצגת', goto_card(pg, m1) and pct(pg) in ['❤️ התאמה גבוהה מאוד', '🩷 התאמה טובה', '💔 התאמה מאתגרת'], pct(pg))
        c.close()
        # ---- 3. אותה לקוחה כשאין אף פרופיל מתאים (כמו ב-Production כרגע) ----
        sql(f"update public.docs set data = jsonb_set(data, '{{ageMin}}', '18') || jsonb_build_object('ageMax', 19) where collection='profiles' and id='{w1}'")
        c, pg = newpage(br); login(pg, APP, w1m); pg.wait_for_timeout(3000)
        empty = pg.evaluate("() => !currentMatchId")
        check('3. בלי פרופילים מתאימים — אין כרטיס ולכן גם אין רמת התאמה (משחזר את Production)', empty, card_id(pg))
        c.close()
        br.close()
    check('אין שגיאות JavaScript בדף', not errors, errors[:3])
    code = 0 if all(results) else 1
except Exception as e:
    print('ERROR', str(e)[:300], flush=True); code = 1
finally:
    try:
        sql(f"delete from public.hdm_hidden_profiles where profile_id like '{PFX}%'")
        left = cleanup(); print(f'ניקוי: נשארו {left} רשומות בדיקה', flush=True); code = code if left == '0' else 1
    except Exception as e: print('ניקוי נכשל', str(e)[:200], flush=True); code = 1
print(f'SUMMARY עברו {sum(results)} מתוך {len(results)}', flush=True)
sys.exit(code)
