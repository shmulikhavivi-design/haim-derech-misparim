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
_extra = [('איתי שמש', '1987-01-09', 'איתי', 'שמש'), ('יואב גל', '1991-02-17', 'יואב', 'גל'), ('אורי נחום', '1989-04-26', 'אורי', 'נחום'),
          ('רועי אדם', '1993-05-03', 'רועי', 'אדם'), ('גיא פרץ', '1986-08-11', 'גיא', 'פרץ'), ('נדב טל', '1990-09-29', 'נדב', 'טל'),
          ('אלון רז', '1985-10-16', 'אלון', 'רז'), ('תומר שגיא', '1992-12-08', 'תומר', 'שגיא')]
_cols = [('#2B3A6E', '#C59A4E'), ('#3B2658', '#B88A45'), ('#1F3350', '#D2A85C'), ('#432C5E', '#C79B52')]
for i, (n, b, f, l) in enumerate(_extra):
    PEOPLE[f'x{i}'] = (n, b, f, l, 'גבר', 'נשים', 'באר שבע', avatar(*_cols[i % 4]))
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
def settle(pg):   # מחכים שכל הבקשות לשרת יסתיימו לפני סגירת הדפדפן (אחרת WebKit רושם בקשה שנקטעה כשגיאה)
    try: pg.wait_for_load_state('networkidle', timeout=10000)
    except Exception: pass
    pg.wait_for_timeout(400)

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
            if a.size != b.size: check('מסך הפתיחה: זהה ל-main', False, 'size')
            else:
                d = ImageChops.difference(a, b)
                mx = max(hi for lo, hi in d.getextrema())
                # רעש עיבוד של הדפדפן (פענוח JPEG/החלקה) מגיע לכל היותר ל-3–4 רמות; כל שינוי נראה לעין גדול בהרבה
                strict = d.point(lambda v: 255 if v > 4 else 0).getbbox()
                print(f'INFO מסך הפתיחה: הפרש מרבי {mx}/255 לערוץ', flush=True)
                check('מסך הפתיחה: זהה ל-main (בלי הבדל נראה לעין, סף 4/255)', strict is None, (mx, strict))

        # --- עומר מסמן 🎯 את נועה (כדי שיופיע אצלה ב"מי סימן אותי") ---
        c = ctx_new(); pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)))
        pg.goto(APP); pg.wait_for_timeout(2500)
        check('התחברות (עומר)', login(pg, 'omer') == IDS['omer'])
        show_card(pg, IDS['me']); pg.evaluate("async () => { await onTargetClick(); }")
        try: pg.wait_for_function("() => /העניין נשמר/.test(document.getElementById('match-hint').textContent)", timeout=15000)
        except Exception: pass
        check('🎯 של עומר נשמר (חד־צדדי)', 'העניין נשמר' in pg.inner_text('#match-hint'), pg.inner_text('#match-hint'))
        settle(pg); c.close()

        # --- נועה: התאמות בשלוש הרמות, ❌, 🎯 חד־צדדי ---
        c = ctx_new(); pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)))
        pg.goto(APP); pg.wait_for_timeout(2500)
        check('התחברות (נועה)', login(pg, 'me') == IDS['me'])
        cand = [IDS['dan']] + [IDS[f'x{i}'] for i in range(len(_extra))]
        labels = pg.evaluate(f"""async () => {{ const s = await dbCap.collection('profiles').get(); const out = {{}};
            for (const d of s.docs) if ({json.dumps(cand)}.includes(d.id)) out[d.id] = matchCategoryLabel(overallCompatibility(myProfile, d.data()));
            return out; }}""")
        LEVELS = [('❤️ התאמה גבוהה מאוד', 'high'), ('🩷 התאמה טובה', 'good'), ('💔 התאמה מאתגרת', 'challenging')]
        print('INFO רמות: ' + json.dumps(labels, ensure_ascii=False), flush=True)
        for lab, tag in LEVELS:
            who = next((k for k, v in labels.items() if v == lab), None)
            if not who:
                print(f'INFO אין מועמד ברמה {lab}', flush=True); continue
            show_card(pg, who)
            try: pg.wait_for_function("() => document.getElementById('match-pct').textContent.trim()", timeout=10000)
            except Exception: pass
            pct = pg.inner_text('#match-pct').strip()
            check(f'כרטיס ברמה "{lab}": הרמה מוצגת כמו שהיא', pct == lab, pct)
            check(f'כרטיס ברמה "{lab}": ❌ ו-🎯 (המטרה לא הוחלפה בלב)', pg.inner_text('#skip-btn') == '❌' and pg.inner_text('.target-btn') == '🎯')
            shot(pg, f'01_card_{tag}')
            pg.evaluate("() => { var i = document.querySelector('#match-card .info'); if(i) i.scrollTop = i.scrollHeight; }"); pg.wait_for_timeout(300)
            shot(pg, f'01_card_{tag}_analysis')
            pg.evaluate("() => { var i = document.querySelector('#match-card .info'); if(i) i.scrollTop = 0; }")
        check('הוצגו כל שלוש רמות ההתאמה', all(any(v == lab for v in labels.values()) for lab, _ in LEVELS), labels)
        # ❌ = מעבר לפרופיל הבא בלבד (בלי שום כתיבה לשרת)
        writes = []
        on_req = lambda r: writes.append(r.url) if r.method in ('POST', 'PATCH', 'DELETE') and '/rest/v1/' in r.url and '/rpc/' not in r.url else None
        pg.on('request', on_req)
        before = pg.evaluate("() => ({ idx: matchQueueIndex, n: (matchQueue||[]).length })")
        pg.locator('#skip-btn').tap(); pg.wait_for_timeout(900)
        after = pg.evaluate("() => ({ idx: matchQueueIndex })")
        check('❌ עובר לפרופיל הבא (או נשאר באחרון)', (before['n'] < 2 and after['idx'] == before['idx']) or after['idx'] == before['idx'] + 1, [before, after])
        check('❌ לא שולח שום שינוי לשרת', not writes, writes[:3])
        pg.remove_listener('request', on_req)
        # 🎯 חד־צדדי: אין צ׳אט
        show_card(pg, IDS['dan'])
        pg.evaluate("() => onTargetClick()"); pg.wait_for_timeout(2200)
        pair = '__'.join(sorted([IDS['me'], IDS['dan']]))
        check('🎯 חד־צדדי: לא נפתח צ׳אט', sql(f"select count(*) from docs where collection='chats' and id='{pair}'") == '0')
        shot(pg, '02_target_one_side_hint')
        # ⋯ חסימה / דיווח
        pg.evaluate("() => openUserActions('card')"); pg.wait_for_timeout(700); shot(pg, '10_block_report_sheet')
        pg.evaluate("() => { try{ closeSheet(); }catch(e){} }"); pg.wait_for_timeout(300)
        # מי סימן אותי (פלוס)
        pg.evaluate("() => hdmOpenLikedMe()"); pg.wait_for_timeout(2500)
        check('"מי סימן אותי" מציג את עומר', 'עומר' in pg.inner_text('#hdm-liked-body'), pg.inner_text('#hdm-liked-body')[:200])
        shot(pg, '11_liked_me')
        pg.evaluate("() => hdmCloseLayer('hdm-liked-screen')"); pg.wait_for_timeout(300)
        # תפריט / הגדרות (למעלה + למטה)
        pg.evaluate("() => openSettings()"); pg.wait_for_timeout(900); shot(pg, '05_settings_menu_top')
        pg.evaluate("() => { var s = document.getElementById('screen-settings'); s.scrollTop = s.scrollHeight; }"); pg.wait_for_timeout(400); shot(pg, '05_settings_menu_bottom')
        # הפרופיל שלי (למעלה + אזור החשבון והמנוי עם "ביטול מנוי")
        pg.evaluate("() => openMyProfile()"); pg.wait_for_timeout(1500); shot(pg, '06_my_profile_top')
        pg.evaluate("() => document.getElementById('profile-account-box').scrollIntoView({ block: 'center' })"); pg.wait_for_timeout(400); shot(pg, '06_my_profile_account')
        # מנויים: ניהול מנוי + מסלולים + שלב הביטול (בלי לבצע ביטול)
        pg.evaluate("() => { go('screen-match'); hdmOpenPlans(); }"); pg.wait_for_timeout(2200); shot(pg, '07_plans_top')
        pg.evaluate("() => { var l = document.getElementById('hdm-plans-screen'); var p = document.querySelectorAll('.hdm-plan'); if(p.length > 2) p[2].scrollIntoView({ block: 'center' }); }"); pg.wait_for_timeout(400); shot(pg, '07_plans_tiers')
        pg.evaluate("() => { var p = document.querySelectorAll('.hdm-plan'); if(p.length) p[p.length-1].scrollIntoView({ block: 'center' }); }"); pg.wait_for_timeout(400); shot(pg, '07_plans_vip')
        subs_before = sql(f"select count(*) || '|' || coalesce(max(updated_at)::text,'') from public.hdm_subscriptions")
        pg.evaluate("() => { document.getElementById('hdm-plans-screen').scrollTop = 0; hdmOpenCancelInfo(); }"); pg.wait_for_timeout(600); shot(pg, '07_cancel_step')
        check('שלב הביטול מוצג כמו קודם (אין מנוי בתשלום, אישור הביטול)', pg.locator('#hdm-cancel-info').count() == 1 and pg.locator('#hdm-cancel-confirm').count() == 1)
        check('שום מנוי לא השתנה', sql(f"select count(*) || '|' || coalesce(max(updated_at)::text,'') from public.hdm_subscriptions") == subs_before)
        pg.evaluate("() => { hdmCloseCancelInfo(); hdmCloseLayer('hdm-plans-screen'); }")
        # מסמך: מדיניות ביטול מנוי
        pg.evaluate("() => openLegal('cancel')"); pg.wait_for_timeout(600); shot(pg, '12_cancel_policy_doc')
        pg.evaluate("() => closeLegal()")
        settle(pg); c.close()

        # --- דניאל: 🎯 הדדי ---
        c = ctx_new(); pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)))
        pg.goto(APP); pg.wait_for_timeout(2500)
        check('התחברות (דניאל)', login(pg, 'dan') == IDS['dan'])
        show_card(pg, IDS['me'])
        shot(pg, '03a_before_mutual_target')
        pg.evaluate("() => onTargetClick()")
        for _ in range(24):
            if pg.evaluate("() => document.getElementById('screen-chat').classList.contains('active')"): break
            pg.wait_for_timeout(250)
        on_chat = pg.evaluate("() => document.getElementById('screen-chat').classList.contains('active')")
        check('🎯 הדדי: הצ׳אט נפתח מיד (ההתנהגות הקיימת, ללא שינוי)', on_chat)
        shot(pg, '03b_after_mutual_target_chat_opens')
        for _ in range(16):
            if sql(f"select count(*) from docs where collection='chats' and id='{pair}'") == '1': break
            pg.wait_for_timeout(500)
        check('🎯 הדדי: השרת פתח שיחה (המנגנון הקיים)', sql(f"select count(*) from docs where collection='chats' and id='{pair}'") == '1')
        # מסך "יש התאמה" — קיים בקוד אבל האפליקציה לא מגיעה אליו כרגע. מוצג כאן ישירות רק כדי לראות את העיצוב שלו
        pg.evaluate("() => go('screen-connect')"); pg.wait_for_timeout(700); shot(pg, '03c_match_screen_design_only')
        pg.evaluate("() => openChat()"); pg.wait_for_timeout(1200)
        pg.fill('#chat-input', 'היי נועה! ראיתי שיש לנו התאמה 🙂'); pg.click('#send-chat-btn'); pg.wait_for_timeout(1500)
        last = ''
        for _ in range(16):
            last = sql(f"select coalesce(data->'messages'->-1->>'text','') from docs where collection='chats' and id='{pair}'")
            if 'היי נועה' in last: break
            pg.wait_for_timeout(500)
        check('הודעה בצ׳אט נשמרת בשרת', 'היי נועה' in last, last)
        settle(pg); c.close()

        # --- נועה עונה: רשימת שיחות וצ׳אט ---
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
        settle(pg); c.close()

        # --- מסך ההתחברות (כבר כהה) ---
        c = ctx_new(); pg = c.new_page(); pg.goto(APP); pg.wait_for_timeout(2000)
        pg.evaluate("() => { var i=document.getElementById('intro-screen'); if(i){ i.classList.add('intro-hide'); i.style.display='none'; } }"); pg.wait_for_timeout(500)
        shot(pg, '09_auth_choice')
        settle(pg); c.close()

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
