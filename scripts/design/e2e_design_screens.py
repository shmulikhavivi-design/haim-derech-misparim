# =====================================================================
# חיים דרך מספרים — צילומי מסך של העיצוב החדש + בדיקות שלא נשבר כלום. Staging בלבד.
# iPhone 13 (WebKit, מגע). משתמשי בדיקה: hdm-dsg-<ריצה>-*@example.invalid, תמונות = איורים (לא אנשים). הכול נמחק בסוף.
# משתני סביבה: STAGING_DB_URL (סוד), STAGING_PUBLISHABLE_KEY, PAGE (הדף החדש), MAIN_PAGE (הדף של main להשוואת מסך הפתיחה)
# =====================================================================
import base64, json, os, random, string, subprocess, sys, http.server, threading, functools
from playwright.sync_api import sync_playwright

DB = os.environ['STAGING_DB_URL']
KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', '')
PAGE = os.environ.get('PAGE', 'staging.html')
MAIN_PAGE = os.environ.get('MAIN_PAGE', '')
SHOTS = os.environ.get('HDM_SHOTS', '/tmp/hdm-shots'); os.makedirs(SHOTS, exist_ok=True)
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX, MAIL = f'dsg{RUN}_', f'hdm-dsg-{RUN}-'
PW = 'Dsg-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(20))
if not KEY.startswith('sb_publishable_'): print('⛔ חסר מפתח ציבורי'); sys.exit(2)

def sql(q):
    r = subprocess.run(['psql', DB, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q], capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError('sql: ' + r.stderr.strip()[:200])
    return r.stdout.strip()

results = []
def check(name, ok, got=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {str(got)[:200]}'), flush=True)

def avatar(c1, c2):   # איור מופשט ב-PNG (לא תמונה של אדם)
    from PIL import Image, ImageDraw
    import io
    w, h = 300, 400
    im = Image.new('RGB', (w, h)); d = ImageDraw.Draw(im)
    a, b = tuple(int(c1[i:i+2], 16) for i in (1, 3, 5)), tuple(int(c2[i:i+2], 16) for i in (1, 3, 5))
    for y in range(h):
        t = y / (h - 1); d.line([(0, y), (w, y)], fill=tuple(int(a[k] + (b[k] - a[k]) * t) for k in range(3)))
    d.ellipse([88, 88, 212, 212], fill=(214, 196, 166)); d.ellipse([40, 255, 260, 520], fill=(214, 196, 166))
    buf = io.BytesIO(); im.save(buf, 'PNG', optimize=True)
    return 'data:image/png;base64,' + base64.b64encode(buf.getvalue()).decode()

PEOPLE = {   # מפתח: (שם, לידה, שם לידה, משפחה, מגדר, מחפש, עיר, תמונה)
    'me':   ('נועה לוי',  '1992-03-14', 'נועה', 'לוי',  'אישה', 'גברים', 'תל אביב', avatar('#3A2C6B', '#C9973F')),
    'dan':  ('דניאל כהן', '1990-07-22', 'דניאל', 'כהן', 'גבר', 'נשים', 'חיפה',    avatar('#1D3B6B', '#B9853A')),
    'omer': ('עומר בר',   '1988-11-05', 'עומר', 'בר',   'גבר', 'נשים', 'ירושלים', avatar('#4A2450', '#D9AE5F')),
}
IDS = {k: PFX + k for k in PEOPLE}
IDS_SQL = "array[" + ",".join(f"'{v}'" for v in IDS.values()) + "]"
CRYPT = 'extensions.crypt' if sql("select count(*) from pg_proc where proname='crypt' and pronamespace='extensions'::regnamespace") != '0' else 'crypt'
SALT = CRYPT.replace('crypt', 'gen_salt')

def cleanup():
    sql(f"""begin;
      delete from public.docs where (collection='profiles' and id = any({IDS_SQL}))
         or exists (select 1 from unnest({IDS_SQL}) p where public.hdm_pair_has(docs.id, p) or public.hdm_pair_has(split_part(docs.id,'___',2), p) or docs.id like 'chats/%' || p || '%');
      delete from public.hdm_profile_private where profile_id = any({IDS_SQL});
      delete from public.hdm_chat_openings where profile_id = any({IDS_SQL});
      delete from public.hdm_subscription_events where profile_id = any({IDS_SQL});
      delete from public.hdm_subscriptions where profile_id = any({IDS_SQL});
      delete from public.hdm_consents where profile_id = any({IDS_SQL});
      delete from public.hdm_accounts where profile_id = any({IDS_SQL});
      delete from auth.users where email like '{MAIL}%@example.invalid';
      commit;""")
    return sql(f"""select (select count(*) from auth.users where email like '{MAIL}%') + (select count(*) from public.hdm_accounts where profile_id like '{PFX}%')
                 + (select count(*) from public.docs where id like '%{PFX}%')""")

def create_people():
    consent = sql("select public.hdm_required_terms_version()")
    for k, (name, birth, first, last, gender, looking, city, photo) in PEOPLE.items():
        pid, email = IDS[k], f'{MAIL}{k}@example.invalid'
        profile = json.dumps({'currentName': name, 'birthdate': birth, 'birthFirstName': first, 'birthLastName': last, 'gender': gender,
                              'lookingFor': looking, 'location': city, 'occupation': 'מעצב/ת', 'interests': 'מוזיקה, טיולים',
                              'photoUrl': photo, 'createdAt': 0}, ensure_ascii=False)
        sql(f"""begin;
          with u as (
            insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                                    created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
            values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', '{email}', {CRYPT}('{PW}', {SALT}('bf')),
                    now(), '{{"provider":"email","providers":["email"]}}', '{{}}', now(), now(), '', '', '', '') returning id)
          , i as (insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
                  select gen_random_uuid(), u.id::text, u.id, jsonb_build_object('sub', u.id::text, 'email', '{email}', 'email_verified', true), 'email', now(), now(), now() from u)
          , a as (insert into public.hdm_accounts (auth_user_id, profile_id) select id, '{pid}' from u)
          insert into public.hdm_consents (user_id, profile_id, version, source) select id, '{pid}', '{consent}', 'signup' from u;
          insert into public.docs (collection, id, data) values ('profiles', '{pid}', $j${profile}$j$::jsonb);
          commit;""")
        sql(f"select public.hdm_admin_set_plan('{pid}', 'plus', null, 'e2e design')")

def serve(path):
    d = os.path.dirname(os.path.abspath(path))
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=d))
    srv.RequestHandlerClass.log_message = lambda *a: None
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f'http://127.0.0.1:{srv.server_address[1]}/{os.path.basename(path)}'

errors = []
def shot(pg, name):
    pg.wait_for_timeout(500); pg.screenshot(path=os.path.join(SHOTS, name + '.png')); print(f'SHOT {name}', flush=True)

def login(pg, k):
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i){ i.classList.add('intro-hide'); i.style.display='none'; } openLogin(); }catch(e){} }")
    pg.fill('#li-email', f'{MAIL}{k}@example.invalid'); pg.fill('#li-pass', PW); pg.click('#li-submit')
    try: pg.wait_for_function("() => myId && (document.querySelector('.screen.active')||{}).id === 'screen-match'", timeout=30000)
    except Exception: pass
    pg.wait_for_timeout(1500)
    return pg.evaluate("() => myId")

def show_card(pg, other):
    pg.evaluate(f"""async () => {{ const s = await dbCap.collection('profiles').get(); const x = s.docs.find(d => d.id === '{other}');
        if(!x) return; currentMatchId = '{other}'; currentMatchData = x.data(); go('screen-match'); renderMatchCard(x.data()); }}""")
    pg.wait_for_timeout(900)

print(f'ריצה {RUN}', flush=True)
exit_code = 1
srv = srv_main = None
try:
    create_people()
    srv, APP = serve(PAGE)
    with sync_playwright() as pw:
        br = pw.webkit.launch()
        dev = dict(pw.devices['iPhone 13'])
        def ctx_new():
            c = br.new_context(**dev); c.add_init_script(f"try{{ localStorage.setItem('hdm_staging_publishable_key', {json.dumps(KEY)}); }}catch(e){{}}"); return c

        # --- מסך הפתיחה: זהה לחלוטין ל-main (השוואת פיקסלים, אנימציות כבויות בשני הצדדים) ---
        if MAIN_PAGE:
            srv_main, APP_MAIN = serve(MAIN_PAGE)
            imgs = {}
            for tag, url in (('main', APP_MAIN), ('new', APP)):
                c = ctx_new(); pg = c.new_page(); pg.goto(url); pg.wait_for_timeout(2500)
                pg.add_style_tag(content='*,*::before,*::after{animation:none!important;transition:none!important;caret-color:transparent!important}')
                pg.wait_for_timeout(600)
                imgs[tag] = pg.screenshot(full_page=False)
                open(os.path.join(SHOTS, f'00_intro_{tag}.png'), 'wb').write(imgs[tag]); c.close()
            from PIL import Image, ImageChops
            import io
            a, b = Image.open(io.BytesIO(imgs['main'])).convert('RGB'), Image.open(io.BytesIO(imgs['new'])).convert('RGB')
            diff = ImageChops.difference(a, b).getbbox() if a.size == b.size else 'size'
            check('מסך הפתיחה: זהה פיקסל־לפיקסל ל-main', diff is None, diff)

        # --- נועה: התחברות, כרטיס פרופיל ---
        c = ctx_new(); pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)))
        pg.goto(APP); pg.wait_for_timeout(2500)
        check('התחברות (נועה)', login(pg, 'me') == IDS['me'])
        show_card(pg, IDS['dan'])
        pct = pg.inner_text('#match-pct')
        check('רמת התאמה — אחת משלוש הרמות הקיימות', pct.strip() in ('❤️ התאמה גבוהה מאוד', '🩷 התאמה טובה', '💔 התאמה מאתגרת'), pct)
        check('בכרטיס: ❌ ו-🎯 (המטרה לא הוחלפה בלב)', pg.inner_text('#skip-btn') == '❌' and pg.inner_text('.target-btn') == '🎯')
        shot(pg, '01_profile_card')
        # ❌ = מעבר לפרופיל הבא בלבד (בלי שום כתיבה לשרת)
        writes = []
        pg.on('request', lambda r: writes.append(r.url) if r.method in ('POST', 'PATCH', 'DELETE') and '/rest/v1/' in r.url and 'rpc/hdm_billing_status' not in r.url and 'rpc/hdm_my_' not in r.url else None)
        pg.evaluate("() => { matchQueue = matchQueue && matchQueue.length ? matchQueue : []; }")
        before = pg.evaluate("() => ({ idx: matchQueueIndex, n: (matchQueue||[]).length, id: currentMatchId })")
        pg.locator('#skip-btn').tap(); pg.wait_for_timeout(900)
        after = pg.evaluate("() => ({ idx: matchQueueIndex, id: currentMatchId })")
        moved = (before['n'] < 2 and after['idx'] == before['idx']) or after['idx'] == before['idx'] + 1
        check('❌ עובר לפרופיל הבא (או נשאר באחרון)', moved, [before, after])
        check('❌ לא שולח שום שינוי לשרת', not writes, writes[:3])
        # 🎯 חד־צדדי: אין צ׳אט
        show_card(pg, IDS['dan'])
        pg.evaluate("async () => { await onTargetClick(); }"); pg.wait_for_timeout(1500)
        pair = '__'.join(sorted([IDS['me'], IDS['dan']]))
        check('🎯 חד־צדדי: לא נפתח צ׳אט', sql(f"select count(*) from docs where collection='chats' and id='{pair}'") == '0')
        shot(pg, '02_after_target_one_side')
        # תפריט / הגדרות, פרופיל, מנוי
        pg.evaluate("() => openSettings()"); pg.wait_for_timeout(900); shot(pg, '05_settings_menu')
        pg.evaluate("() => openMyProfile()"); pg.wait_for_timeout(1500); shot(pg, '06_my_profile')
        pg.evaluate("() => { go('screen-match'); hdmOpenPlans(); }"); pg.wait_for_timeout(2000); shot(pg, '07_plans')
        pg.evaluate("() => hdmCloseLayer('hdm-plans-screen')")
        c.close()

        # --- דניאל: 🎯 הדדי → מסך ההתאמה וצ׳אט ---
        c = ctx_new(); pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)))
        pg.goto(APP); pg.wait_for_timeout(2500)
        check('התחברות (דניאל)', login(pg, 'dan') == IDS['dan'])
        show_card(pg, IDS['me'])
        pg.evaluate("async () => { await onTargetClick(); }"); pg.wait_for_timeout(700)
        if pg.evaluate("() => document.getElementById('screen-connect').classList.contains('active')"): shot(pg, '03_match_connect')
        for _ in range(16):
            if sql(f"select count(*) from docs where collection='chats' and id='{pair}'") == '1': break
            pg.wait_for_timeout(500)
        check('🎯 הדדי: השרת פתח שיחה (המנגנון הקיים)', sql(f"select count(*) from docs where collection='chats' and id='{pair}'") == '1')
        if not pg.evaluate("() => document.getElementById('screen-chat').classList.contains('active')"):
            try: pg.click('#open-chat-btn', timeout=5000)
            except Exception: pass
        pg.wait_for_timeout(1200)
        pg.fill('#chat-input', 'היי נועה! ראיתי שיש לנו התאמה גבוהה 🙂'); pg.click('#send-chat-btn'); pg.wait_for_timeout(1500)
        last = ''
        for _ in range(16):
            last = sql(f"select coalesce(data->'messages'->-1->>'text','') from docs where collection='chats' and id='{pair}'")
            if 'היי נועה' in last: break
            pg.wait_for_timeout(500)
        check('הודעה בצ׳אט נשמרת בשרת', 'היי נועה' in last, last)
        c.close()

        # --- נועה עונה: צ׳אט ורשימת שיחות ---
        c = ctx_new(); pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)))
        pg.goto(APP); pg.wait_for_timeout(2500)
        login(pg, 'me')
        pg.evaluate("() => { var l = document.getElementById('my-chats-link'); if(l) l.click(); }"); pg.wait_for_timeout(2500)
        shot(pg, '08_chats_list')
        opened = pg.evaluate("() => { var r = document.querySelector('.chat-row'); if(r){ r.click(); return true; } return false; }")
        pg.wait_for_timeout(2500)
        if opened:
            pg.fill('#chat-input', 'היי דניאל 😊 שמחה שהתאמנו'); pg.click('#send-chat-btn'); pg.wait_for_timeout(2000)
        check('הצ׳אט נפתח לנועה', pg.evaluate("() => document.getElementById('screen-chat').classList.contains('active')"))
        shot(pg, '04_chat')
        c.close()

        # --- מסך ההתחברות (כבר כהה) ---
        c = ctx_new(); pg = c.new_page(); pg.goto(APP); pg.wait_for_timeout(2000)
        pg.evaluate("() => { var i=document.getElementById('intro-screen'); if(i){ i.classList.add('intro-hide'); i.style.display='none'; } }"); pg.wait_for_timeout(500)
        shot(pg, '09_auth_choice')
        c.close()

        check('אין שגיאות JavaScript', not errors, errors[:3])
        br.close()
    exit_code = 0 if results and all(results) else 1
except Exception as e:
    print('FAIL שגיאה בבדיקה: ' + str(e)[:300], flush=True); exit_code = 1
finally:
    left = cleanup()
    print(f'ניקוי: נשארו {left} רשומות בדיקה', flush=True)
    if left != '0': exit_code = 1
    for s_ in (srv, srv_main):
        if s_: s_.shutdown()
print(f'SUMMARY {sum(results)}/{len(results)} passed', flush=True)
sys.exit(exit_code)
