# =====================================================================
# חיים דרך מספרים — בדיקת דפדפן מול Staging בלבד: מסלול חינם רואה רמת התאמה (❤️/🩷/💔) בלבד.
# משתמשי בדיקה נוצרים ישירות במסד (מאומתים, בלי שליחת מיילים), נמחקים בסוף ובכל כישלון. בלי חיובים.
# =====================================================================
import base64, json, os, random, string, subprocess, sys, http.server, threading, functools
from playwright.sync_api import sync_playwright

DB = os.environ['STAGING_DB_URL']; KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', ''); PAGE = os.environ['PAGE_NEW']
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'fl{RUN}_'; MAIL = f'hdm-freelevel-{RUN}-'; DOM = 'example.invalid'
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

print(f'ריצה {RUN}', flush=True)
code = 1
try:
    f_pid, f_mail = make_user('free', 'אישה', 'גברים', '1990-07-03', 'דנה', 'כהן')
    b_pid, b_mail = make_user('basic', 'אישה', 'גברים', '1986-04-12', 'אבי', 'שלום')
    t_pid, _ = make_user('t1', 'גבר', 'נשים', '1988-09-21', 'עמית', 'רז')
    sql(f"select public.hdm_admin_set_plan('{b_pid}', 'basic')")
    check('הכנה: חינם=free, בסיסי=basic', sql(f"select public.hdm_plan_of('{f_pid}') || ',' || public.hdm_plan_of('{b_pid}')") == 'free,basic')
    APP = serve(PAGE)
    with sync_playwright() as p:
        br = p.chromium.launch()
        # ---- חינם ----
        c, pg = newpage(br); login(pg, APP, f_mail)
        check('חינם: נכנס לאפליקציה (פרופיל קיים)', pg.evaluate("() => myId") == f_pid, pg.evaluate("() => myId"))
        st = card_state(pg)
        check('חינם: בכרטיס מוצגת רמת התאמה ❤️/🩷/💔', st['pctShown'] and st['pct'] in LABELS, st)
        check('חינם: אין ניתוח/הסבר בכרטיס', not st['whyShown'], st)
        check('חינם: הנעילה מציינת רק 🎯 ושיחות', '🎯 ושיחות' in st['box'] and 'דירוג' not in st['box'], st['box'])
        rt = pg.evaluate("() => JSON.stringify(currentMatchData && currentMatchData.__rating)")
        check('חינם: מהשרת מגיעים רק תווית וציון (בלי פירוט)', rt and 'categories' not in rt and 'goodCount' not in rt, rt)
        before = sql(f"select count(*) from public.docs where data::text like '%{f_pid}%' and collection <> 'profiles'")
        pg.click('.target-btn', force=True); pg.wait_for_timeout(1500)
        plans_open = pg.evaluate("() => document.getElementById('hdm-plans-screen').classList.contains('open')")
        check('חינם: לחיצה על 🎯 פותחת מסך מנויים', plans_open)
        after = sql(f"select count(*) from public.docs where data::text like '%{f_pid}%' and collection <> 'profiles'")
        check('חינם: 🎯 לא נשמר במסד', before == after, [before, after])
        srv = pg.evaluate(f"async () => {{ const r = await window.__sb.rpc('hdm_send_target', {{ p_target: '{st['id'] or t_pid}' }}); return r.error ? r.error.message : 'ok'; }}")
        check('חינם: השרת חוסם 🎯 גם בפנייה ישירה', 'HDM_PLAN_REQUIRED' in srv, srv)
        an = pg.evaluate(f"async () => {{ const r = await window.__sb.rpc('hdm_extended_analysis', {{ p_target: '{st['id'] or t_pid}' }}); return r.error ? r.error.message : 'ok'; }}")
        check('חינם: השרת חוסם ניתוח מורחב', an != 'ok', an)
        fc = pg.inner_text('#hdm-plan-card-free') if pg.locator('#hdm-plan-card-free').count() else ''
        check('חינם: במסך המנויים — "הצגת רמת התאמה"', 'רמת התאמה' in fc and 'ללא שליחת 🎯' in fc, fc[:200])
        c.close()
        # ---- בסיסי (לא השתנה) ----
        c, pg = newpage(br); login(pg, APP, b_mail)
        st = card_state(pg)
        check('בסיסי: רמת התאמה מוצגת כמו קודם', st['pctShown'] and st['pct'] in LABELS, st)
        check('בסיסי: בלי ניתוח', not st['whyShown'], st)
        check('בסיסי: נעילת ניתוח מקוצר/מורחב כמו קודם', 'ניתוח מקוצר' in st['box'], st['box'])
        pc = pg.inner_text('#hdm-plan-card-basic') if (pg.evaluate("() => hdmOpenPlans()") or True) and pg.wait_for_timeout(800) is None and pg.locator('#hdm-plan-card-basic').count() else ''
        check('בסיסי: מחיר ₪29.90 לא השתנה', '29.90' in pc, pc[:160])
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
