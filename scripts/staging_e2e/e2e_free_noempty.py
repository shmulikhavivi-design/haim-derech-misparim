# =====================================================================
# חיים דרך מספרים — בדיקת דפדפן מול Staging בלבד: מסלול חינם בלי מסך ריק (רמת התאמה בלבד) + בדיקת כל המסלולים. Staging בלבד.
# משתמשי בדיקה נוצרים ישירות במסד (מאומתים, בלי שליחת מיילים), נמחקים בסוף ובכל כישלון. בלי חיובים.
# =====================================================================
import base64, json, os, random, string, subprocess, sys, http.server, threading, functools
from playwright.sync_api import sync_playwright

DB = os.environ['STAGING_DB_URL']; KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', ''); PAGE = os.environ['PAGE_NEW']
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'ne{RUN}_'; MAIL = f'hdm-noempty-{RUN}-'; DOM = 'example.invalid'
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




LABELS = ['❤️ התאמה גבוהה מאוד', '🩷 התאמה טובה', '💔 התאמה מאתגרת']
def st(pg):
    try: pg.wait_for_function("() => typeof hdmEnt !== 'undefined' && hdmEnt && hdmEnt.forId === myId && !hdmEnt.error", timeout=15000)
    except Exception: pass
    for _ in range(10):
        ok = pg.evaluate("() => !!(currentMatchId && document.getElementById('match-pct').textContent.trim()) || (matchQueue && matchQueue.length === 0)")
        if ok: break
        pg.wait_for_timeout(1000)
    pg.wait_for_timeout(1500)
    return pg.evaluate("""() => ({ id: currentMatchId || null, n: (matchQueue||[]).length, relaxed: !!matchQueueRelaxed, ids: (matchQueue||[]).map(e => e.id),
        name: document.getElementById('match-name').textContent.trim(), age: document.getElementById('match-age').textContent.trim(),
        pct: document.getElementById('match-pct').textContent.trim(),
        whyShown: getComputedStyle(document.getElementById('match-why')).display !== 'none' && !!document.getElementById('match-why').textContent.trim(),
        why: document.getElementById('match-why').textContent.trim(), plan: hdmPlanId(),
        marked: document.getElementById('target-btn') ? document.getElementById('target-btn').classList.contains('is-targeted') : null })""")
def interests_from(a): return sql(f"select count(*) from public.docs where collection='interests' and data->>'from'='{a}'")

print(f'ריצה {RUN}', flush=True)
code = 1
try:
    own, ownm = make_user('owner', 'גבר', 'נשים', '1954-02-02', 'שמואל', 'ח', age=73, amin=70, amax=76)
    m2, _ = make_user('m2', 'גבר', 'נשים', '1976-07-07', 'דוד', 'מ', age=50, amin=40, amax=80)
    w1, w1m = make_user('w1', 'אישה', 'גברים', '1953-05-05', 'נועה', 'כ', age=73, amin=70, amax=72)
    b1, b1m = make_user('b1', 'אישה', 'גברים', '1953-06-06', 'רות', 'ל', age=73, amin=70, amax=72)
    p1, p1m = make_user('p1', 'אישה', 'גברים', '1953-08-08', 'מיכל', 'ש', age=73, amin=70, amax=72)
    v1, v1m = make_user('v1', 'אישה', 'גברים', '1953-09-09', 'אורית', 'ב', age=73, amin=70, amax=72)
    for pid, pl in [(own, 'basic'), (m2, 'basic'), (b1, 'basic'), (p1, 'plus'), (v1, 'vip')]: sql(f"select public.hdm_admin_set_plan('{pid}', '{pl}')")
    sql(f"insert into public.hdm_hidden_profiles (profile_id) values ('{own}') on conflict do nothing")
    APP = serve(PAGE)
    with sync_playwright() as pw_:
        br = pw_.chromium.launch()
        # ---- חינם: אין אף פרופיל בטווח הגילאים (כמו ב-Production) ----
        c, pg = newpage(br); login(pg, APP, w1m); s = st(pg)
        check('חינם: לא מוצג מסך ריק — מוצג כרטיס', bool(s['id']) and s['n'] > 0, s)
        check('חינם: התור הורחב לפי מגדר בלבד', s['relaxed'], s)
        check('חינם: רמת התאמה מוצגת (❤️/🩷/💔)', s['pct'] in LABELS, s['pct'])
        check('חינם: בלי ניתוח/פירוט', not s['whyShown'], s['why'])
        check('חינם: מסומן "מחוץ לטווח הגילאים שבחרת" כשרלוונטי', ('מחוץ לטווח' in s['age']) == True or s['id'] != m2, s['age'])
        check('חינם: הבעלים המוסתר לא בתור', own not in s['ids'])
        check('חינם: רק גברים שמחפשים נשים בתור', sql("select count(*) from public.docs where collection='profiles' and id = any(array[" + ",".join("'" + i + "'" for i in s['ids']) + "]::text[]) and not (data->>'gender' like 'גבר%' and data->>'lookingFor' like 'נש%')") == '0' if s['ids'] else False)
        pg.click('#target-btn', force=True); pg.wait_for_timeout(1500)
        check('חינם: 🎯 חסום (נפתח מסך מנויים, לא נשמר)', pg.evaluate("() => document.getElementById('hdm-plans-screen').classList.contains('open')") and interests_from(w1) == '0', interests_from(w1))
        r = pg.evaluate("async () => { const r = await window.__sb.rpc('hdm_send_target', { p_target: '" + m2 + "' }); return r.error ? r.error.message : 'ok'; }")
        check('חינם: השרת חוסם 🎯', 'HDM_PLAN_REQUIRED' in r, r)
        pg.reload(wait_until='networkidle'); pg.wait_for_timeout(2500); s = st(pg)
        check('חינם: אחרי רענון — עדיין כרטיס עם רמת התאמה', bool(s['id']) and s['pct'] in LABELS, s)
        c.close()
        # ---- בסיסי / פלוס / VIP: אותו מצב, בלי הרחבה (הרשאות ללא שינוי) ----
        for tag, mail, pid in [('בסיסי', b1m, b1), ('פלוס', p1m, p1), ('VIP', v1m, v1)]:
            c, pg = newpage(br); login(pg, APP, mail); s = st(pg)
            check(f'{tag}: בלי הרחבת טווח (רק חינם מורחב)', not s['relaxed'] and s['n'] == 0, s)
            check(f'{tag}: הודעה ברורה במקום מסך ריק', 'עדיין אין פרופילים שמתאימים' in s['why'], s['why'])
            c.close()
        # ---- בסיסי עם התאמה: 🎯 נשמר ונשאר מסומן גם אחרי רענון ----
        sql(f"update public.docs set data = data || jsonb_build_object('ageMin', 40, 'ageMax', 80) where collection='profiles' and id='{b1}'")
        c, pg = newpage(br); login(pg, APP, b1m); s = st(pg)
        found = False
        for _ in range(60):
            if pg.evaluate("() => currentMatchId") == m2: found = True; break
            pg.evaluate("() => { try{ navCard(1); }catch(e){} }"); pg.wait_for_timeout(500)
        check('בסיסי: כרטיס M2 בתור', found)
        pg.click('#target-btn'); pg.wait_for_timeout(2000)
        check('בסיסי: 🎯 מסומן ונשמר במסד', pg.evaluate("() => document.getElementById('target-btn').classList.contains('is-targeted')") and sql(f"select count(*) from public.docs where collection='interests' and id='{b1}__{m2}'") == '1')
        pg.reload(wait_until='networkidle'); pg.wait_for_timeout(2500)
        for _ in range(60):
            if pg.evaluate("() => currentMatchId") == m2: break
            pg.evaluate("() => { try{ navCard(1); }catch(e){} }"); pg.wait_for_timeout(500)
        pg.wait_for_timeout(2500)
        check('בסיסי: אחרי רענון — 🎯 עדיין מסומן', pg.evaluate("() => currentMatchId") == m2 and pg.evaluate("() => document.getElementById('target-btn').classList.contains('is-targeted')"))
        check('בסיסי: אין צ\'אט בלי הדדיות', sql(f"select count(*) from public.docs where collection='chats' and data->'participants' ? '{b1}'") == '0')
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
