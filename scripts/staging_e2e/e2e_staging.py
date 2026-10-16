# =====================================================================
# חיים דרך מספרים — בדיקת דפדפן מלאה של staging.html מול פרויקט Staging
#
# * משתמשי בדיקה נוצרים ישירות במסד (בלי הרשמה ובלי מיילים), עם אימייל ‎hdm-e2e-<ריצה>-*@example.invalid
#   ומזהי פרופיל e2e<ריצה>_*. בסוף — ובכל מקרה של כישלון — כולם נמחקים, ובודקים שלא נשאר כלום.
# * הדפדפן משתמש בספריית supabase-js האמיתית ובשרת ה-Auth האמיתי של Staging.
# * לא נוגע בשום משתמש אחר: כל פעולה במסד מוגבלת למזהים של הריצה הזו.
#
# משתני סביבה: STAGING_DB_URL (סוד), STAGING_PUBLISHABLE_KEY (מפתח ציבורי), PAGE (נתיב ל-staging.html)
# לבדיקה מקומית: E2E_LOCAL=1 (מנתב את כתובת Staging לשרתים מקומיים).
# =====================================================================
import base64, hashlib, hmac, json, os, random, string, subprocess, sys, time, http.server, threading, functools
from playwright.sync_api import sync_playwright

STG = 'https://ousepgdvzammgkxkweze.supabase.co'
DB = os.environ['STAGING_DB_URL']
KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', '')
PAGE = os.environ.get('PAGE', 'staging.html')
LOCAL = os.environ.get('E2E_LOCAL') == '1'
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'e2e{RUN}_'
MAIL = f'hdm-e2e-{RUN}-'
PW = 'E2e-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(20))

if not KEY.startswith('sb_publishable_'):
    print('⛔ STAGING_PUBLISHABLE_KEY חסר או לא ציבורי'); sys.exit(2)

def sql(q):
    r = subprocess.run(['psql', DB, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q], capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError('SQL נכשל: ' + r.stderr.strip().splitlines()[-1][:200] if r.stderr.strip() else 'SQL נכשל')
    return r.stdout.strip()

results = []
def check(name, ok, got=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  -> {str(got)[:160]}'), flush=True)

# ---------------- הכנה: משתמשים ופרופילים (רק עם הקידומת של הריצה) ----------------
CRYPT = 'extensions.crypt' if sql("select count(*) from pg_proc where proname='crypt' and pronamespace='extensions'::regnamespace") != '0' else 'crypt'
SALT = CRYPT.replace('crypt', 'gen_salt')
PEOPLE = {   # key: (שם, תאריך לידה, שם פרטי מלידה, משפחה, מגדר, מחפש, מסלול)
    'basic': ('בני בסיסי', '1988-02-14', 'בני', 'לוי', 'גבר', 'נשים', 'basic'),
    'plus':  ('פנינה פלוס', '1990-07-03', 'פנינה', 'כהן', 'אישה', 'גברים', 'plus'),
    'free':  ('פזית חינם', '1991-03-08', 'פזית', 'שקד', 'אישה', 'גברים', None),
    'vip':   ('ורד VIP', '1985-09-19', 'ורד', 'אור', 'אישה', 'גברים', 'vip'),
}
for i in range(6): PEOPLE[f'q{i}'] = (f'שותפה {i}', f'198{i}-0{i+1}-1{i}', 'יעל', 'בר', 'אישה', 'גברים', 'plus')
# אישור תנאים (14): 'gate' — משתמש קיים שעוד לא אישר; 'meta' — סימן את התיבה בהרשמה אבל עוד לא נכנס
PEOPLE['gate'] = ('גל מסך-אישור', '1987-04-04', 'גל', 'שמש', 'אישה', 'גברים', 'plus')
PEOPLE['meta'] = ('מאיר הרשמה', '1989-05-05', 'מאיר', 'טל', 'גבר', 'נשים', 'plus')
IDS = {k: PFX + k for k in PEOPLE}
CONSENT = None   # הגרסה הנדרשת, אם מנגנון האישור מותקן
RECONSENT_V = '2099-12-31'

def cleanup():
    ids = "array[" + ",".join(f"'{v}'" for v in IDS.values()) + "]"
    if sql("select to_regclass('public.hdm_consents') is not null") == 't':   # גרסת הבדיקה של "אישור מחדש" — לעולם לא נשארת
        sql(f"""begin; delete from public.hdm_consents where version = '{RECONSENT_V}' or user_id in (select id from auth.users where email like '{MAIL}%@example.invalid');
                 delete from public.hdm_terms_versions where version = '{RECONSENT_V}'; commit;""")
    sql(f"""begin;
      delete from public.docs where (collection='profiles' and id = any({ids}))
         or exists (select 1 from unnest({ids}) p where public.hdm_pair_has(docs.id, p) or public.hdm_pair_has(split_part(docs.id,'___',2), p) or docs.id like 'chats/%' || p || '%');
      delete from public.hdm_profile_private where profile_id = any({ids});
      delete from public.hdm_chat_openings where profile_id = any({ids});
      delete from public.hdm_subscription_events where profile_id = any({ids});
      delete from public.hdm_subscriptions where profile_id = any({ids});
      delete from public.hdm_accounts where profile_id = any({ids});
      delete from auth.users where email like '{MAIL}%@example.invalid';
      commit;""")
    left = sql(f"""select (select count(*) from auth.users where email like '{MAIL}%')
                    + (select count(*) from public.hdm_accounts where profile_id like '{PFX}%')
                    + (select count(*) from public.docs where id like '%{PFX}%')
                    + (select count(*) from public.hdm_profile_private where profile_id like '{PFX}%')""")
    return left

def create_people():
    global CONSENT
    if sql("select to_regclass('public.hdm_consents') is not null") == 't':
        CONSENT = sql("select public.hdm_required_terms_version()")
    for k, (name, birth, first, last, gender, looking, plan) in PEOPLE.items():
        if k in ('gate', 'meta') and not CONSENT: continue
        pid, email = IDS[k], f'{MAIL}{k}@example.invalid'
        meta = json.dumps({'hdm_terms': CONSENT}) if (k == 'meta' and CONSENT) else '{}'
        profile = json.dumps({'currentName': name, 'birthdate': birth, 'birthFirstName': first, 'birthLastName': last,
                              'gender': gender, 'lookingFor': looking, 'location': 'תל אביב', 'occupation': 'בדיקה',
                              'interests': 'מוזיקה', 'photoUrl': 'data:image/png;base64,iVBORw0KGgo=', 'createdAt': 0}, ensure_ascii=False)
        sql(f"""begin;
          with u as (
            insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                                    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                                    confirmation_token, recovery_token, email_change_token_new, email_change)
            values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', '{email}',
                    {CRYPT}('{PW}', {SALT}('bf')), now(), '{{"provider":"email","providers":["email"]}}', '{meta}', now(), now(), '', '', '', '')
            returning id)
          , i as (insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
                  select gen_random_uuid(), u.id::text, u.id, jsonb_build_object('sub', u.id::text, 'email', '{email}', 'email_verified', true), 'email', now(), now(), now() from u)
          insert into public.hdm_accounts (auth_user_id, profile_id) select id, '{pid}' from u;
          insert into public.docs (collection, id, data) values ('profiles', '{pid}', $j${profile}$j$::jsonb);
          commit;""")
        if plan: sql(f"select public.hdm_admin_set_plan('{pid}', '{plan}', 30, 'e2e')")
        if CONSENT and k not in ('gate', 'meta'):   # שאר משתמשי הבדיקה אישרו כבר (כמו בהרשמה)
            sql(f"insert into public.hdm_consents (user_id, profile_id, version, source) select id, '{pid}', '{CONSENT}', 'signup' from auth.users where email = '{email}'")

# ---------------- הדפדפן ----------------
html_dir = os.path.dirname(os.path.abspath(PAGE))
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=html_dir))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()
APP = f'http://127.0.0.1:{srv.server_address[1]}/{os.path.basename(PAGE)}'
seen_hosts, errors = set(), []

def route_local(route):   # רק בבדיקה מקומית: מנתב לשרתים המקומיים ולתחליף של supabase-js
    url = route.request.url
    if 'supabase-js' in url:
        return route.fulfill(status=200, content_type='application/javascript', body=open(os.environ['E2E_FAKE_SDK']).read())
    if url.startswith(STG):
        path = url[len(STG):]
        tgt = ('http://127.0.0.1:3000' + path[8:]) if path.startswith('/rest/v1') else ('http://127.0.0.1:9999' + path[8:])
        h = dict(route.request.headers)
        if h.get('authorization', '').startswith('Bearer sb_'): h['authorization'] = 'Bearer ' + os.environ['E2E_ANON_JWT']
        return route.fulfill(response=route.fetch(url=tgt, headers=h))
    return route.continue_()

def track(req):
    seen_hosts.add(req.url.split('/')[2])

def login(pg, k, pw=None):
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
    pg.fill('#li-email', f'{MAIL}{k}@example.invalid'); pg.fill('#li-pass', pw or PW)
    pg.click('#li-submit')
    # מחכים לסוף ההתחברות (מעבר מסך או הודעת שגיאה) ולא לזמן קבוע — מול השרת האמיתי טעינת ההתאמה הראשונה לוקחת יותר
    try:
        pg.wait_for_function("() => (myId && (document.querySelector('.screen.active')||{}).id === 'screen-match') || document.getElementById('li-status').textContent.trim()", timeout=15000)
    except Exception:
        pass
    pg.wait_for_timeout(300)
    return pg.evaluate("() => ({ myId: myId, status: document.getElementById('li-status').textContent, screen: (document.querySelector('.screen.active')||{}).id })")

def logout(pg):
    pg.evaluate("() => { ['hdm-plans-screen','hdm-analysis-screen','hdm-liked-screen'].forEach(function(l){ try{ hdmCloseLayer(l); }catch(e){} }); go('screen-match'); logoutToAuthChoice(); }")
    pg.wait_for_timeout(500)

def card(pg, other):
    return pg.evaluate(f"""async () => {{
      const s = await dbCap.collection('profiles').get();
      const x = s.docs.find(d => d.id === '{other}'); if(!x) return null;
      const d = x.data(); currentMatchId = '{other}'; currentMatchData = d; go('screen-match'); renderMatchCard(d);
      await new Promise(r => setTimeout(r, 400));
      return {{ rating: d.__rating || null, pct: document.getElementById('match-pct').textContent,
               pctShown: getComputedStyle(document.getElementById('match-pct')).display,
               why: getComputedStyle(document.getElementById('match-why')).display, n: s.docs.length,
               leak: ['birthdate','birthFirstName','birthLastName','vowelNumber','expressionNumber','birthdayNumber','consonantsNumber'].filter(k => k in d) }}; }}""")

def target(pg):
    return pg.evaluate("async () => { await onTargetClick(); await new Promise(r=>setTimeout(r,600)); return document.getElementById('match-hint').textContent; }")

print(f'ריצה {RUN}', flush=True)
exit_code = 1
try:
    create_people()
    B, P, F, V = IDS['basic'], IDS['plus'], IDS['free'], IDS['vip']
    hardened = sql("select exists (select 1 from public.hdm_staging_marker where version='staging_secure_v1_fixes3')") == 't'
    with sync_playwright() as pw:
        br = pw.chromium.launch(); ctx = br.new_context()
        if LOCAL: ctx.route('**/*', route_local)
        ctx.add_init_script(f"try{{ localStorage.setItem('hdm_staging_publishable_key', {json.dumps(KEY)}); }}catch(e){{}}")
        pg = ctx.new_page(); pg.on('pageerror', lambda e: errors.append(str(e))); pg.on('request', track)
        pg.goto(APP); pg.wait_for_timeout(2500)
        check('הדף נטען מול Staging עם supabase-js ' + ('(תחליף מקומי)' if LOCAL else 'האמיתית'), pg.evaluate("() => !!(window.supabase && window.__sb)"))

        if CONSENT:
            # --- הרשמה: בלי סימון אין הרשמה ---
            signups = []
            pg.route('**/auth/v1/signup**', lambda r: (signups.append(r.request.post_data or ''), r.abort()))
            pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; }catch(e){} chooseAuth('signup'); }")
            pg.fill('#su-name', 'בדיקת הרשמה'); pg.fill('#su-birth', '1990-01-01'); pg.select_option('#su-gender', 'אישה')
            pg.fill('#su-city', 'חיפה'); pg.fill('#su-email', f'{MAIL}signup@example.invalid'); pg.fill('#su-pass', 'Abcdef123!')
            cb0 = pg.evaluate("() => document.getElementById('su-consent').checked")
            check('הרשמה: תיבת האישור לא מסומנת מראש', cb0 is False, cb0)
            txt = pg.inner_text('#su-f-consent label')
            check('הרשמה: נוסח התיבה', 'קראתי ואני מסכים/ה לתנאי השימוש, למדיניות הפרטיות ולכללי ההתנהגות של חיים דרך מספרים' in ' '.join(txt.split()), txt)
            pg.click('#signup-screen .su-submit'); pg.wait_for_timeout(400)
            st2 = pg.evaluate("() => ({ step2: document.getElementById('signup-step2').classList.contains('open'), err: document.querySelector('#su-f-consent .su-err').textContent })")
            check('הרשמה בלי סימון: נעצרת עם הודעה, לא עוברים לשלב הבא', not st2['step2'] and 'יש לאשר' in st2['err'], st2)
            # הקישורים נפתחים לקריאה ולא מסמנים את התיבה
            pg.click('#su-f-consent a:nth-of-type(3)'); pg.wait_for_timeout(300)
            lg = pg.evaluate("() => ({ open: document.getElementById('legal-screen').classList.contains('open'), title: document.getElementById('legal-title').textContent, cb: document.getElementById('su-consent').checked })")
            check('הרשמה: "כללי ההתנהגות" נפתח לקריאה, בלי לסמן את התיבה', lg['open'] and lg['title'] == 'כללי התנהגות' and lg['cb'] is False, lg)
            pg.evaluate("() => closeLegal()")
            nreq = pg.evaluate("async () => { try{ await window.hdmStagingSignUp('x@example.invalid','Abcdef123!', null, {}); return 'sent'; }catch(e){ return String(e.message||e); } }")
            check('עקיפה: בלי סימון לא נשלחת בקשת הרשמה לשרת', 'HDM_TERMS_REQUIRED' in nreq and not signups, [nreq, len(signups)])
            pg.check('#su-consent'); pg.click('#signup-screen .su-submit'); pg.wait_for_timeout(400)
            check('הרשמה עם סימון: ממשיכים לשלב הבא', pg.evaluate("() => document.getElementById('signup-step2').classList.contains('open')"))
            pg.evaluate("async () => { try{ await window.hdmStagingSignUp('" + MAIL + "signup@example.invalid','Abcdef123!', null, {}); }catch(e){} }")
            body = json.loads(signups[-1]) if signups else {}
            check('הרשמה עם סימון: האישור והגרסה נשלחים עם ההרשמה', (body.get('data') or {}).get('hdm_terms') == CONSENT and (body.get('data') or {}).get('hdm_terms_at'), body.get('data'))
            pg.unroute('**/auth/v1/signup**')
            pg.goto(APP); pg.wait_for_timeout(2500)

            # --- נרשם עם סימון ונכנס בפעם הראשונה: האישור נרשם אוטומטית, בלי מסך נוסף ---
            mt = login(pg, 'meta')
            check('אחרי הרשמה עם סימון: נכנסים בלי מסך אישור', mt['myId'] == IDS['meta'] and not pg.evaluate("() => document.getElementById('terms-gate').classList.contains('open')"), mt)
            row = sql(f"select source || '|' || version || '|' || coalesce(profile_id,'') from public.hdm_consents c join auth.users u on u.id = c.user_id where u.email = '{MAIL}meta@example.invalid'")
            check('תיעוד: מקור "הרשמה", גרסה ומזהה פרופיל', row == f"signup|{CONSENT}|{IDS['meta']}", row)
            logout(pg)

            # --- משתמש קיים שלא אישר: מסך אישור, ושום נתון עד האישור ---
            pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
            pg.fill('#li-email', f'{MAIL}gate@example.invalid'); pg.fill('#li-pass', PW); pg.click('#li-submit')
            try: pg.wait_for_function("() => document.getElementById('terms-gate').classList.contains('open')", timeout=15000)
            except Exception: pass
            gs = pg.evaluate("() => ({ gate: document.getElementById('terms-gate').classList.contains('open'), myId: myId, title: document.getElementById('tg-title').textContent, cb: document.getElementById('tg-consent').checked })")
            check('משתמש קיים בלי אישור: מוצג מסך אישור, לא נכנסים לאפליקציה', gs['gate'] and not gs['myId'] and gs['title'] == 'לפני שממשיכים' and gs['cb'] is False, gs)
            leak = pg.evaluate("async () => { const r = await window.__sb.from('docs').select('id').eq('collection','profiles'); return r.error ? 'blocked' : (r.data||[]).length; }")
            check('בצד השרת: לפני האישור לא מתקבל אף פרופיל', leak in ('blocked', 0), leak)
            tg = pg.evaluate(f"async () => {{ const r = await window.__sb.rpc('hdm_send_target', {{ p_target: '{IDS['plus']}' }}); return r.error ? r.error.message : 'ok'; }}")
            check('בצד השרת: לפני האישור 🎯 נחסם', 'HDM_TERMS_REQUIRED' in tg, tg)
            sf = pg.evaluate("async () => { const r = await window.__sb.rpc('hdm_accept_terms', { p_version: '" + CONSENT + "', p_source: 'signup' }); return r.error ? r.error.message : 'ok'; }")
            check('עקיפה: אי אפשר לטעון "אישור בהרשמה" בלי שסומן בהרשמה', 'HDM_TERMS_SIGNUP' in sf, sf)
            pg.click('.tg-doc >> nth=2'); pg.wait_for_timeout(300)
            check('מסך האישור: אפשר לפתוח ולקרוא את המסמכים', pg.evaluate("() => document.getElementById('legal-screen').classList.contains('open') && document.getElementById('legal-title').textContent === 'כללי התנהגות'"))
            pg.evaluate("() => closeLegal()")
            pg.click('#tg-accept'); pg.wait_for_timeout(400)
            check('מסך האישור: בלי סימון אי אפשר להמשיך', pg.evaluate("() => document.getElementById('terms-gate').classList.contains('open') && !myId") and sql(f"select count(*) from public.hdm_consents c join auth.users u on u.id=c.user_id where u.email='{MAIL}gate@example.invalid'") == '0')
            pg.check('#tg-consent'); pg.click('#tg-accept')
            try: pg.wait_for_function(f"() => myId === '{IDS['gate']}'", timeout=15000)
            except Exception: pass
            pg.wait_for_timeout(500)
            ga = pg.evaluate("() => ({ gate: document.getElementById('terms-gate').classList.contains('open'), myId: myId })")
            check('אחרי אישור: המסך נסגר ונכנסים לפרופיל הקיים', not ga['gate'] and ga['myId'] == IDS['gate'], ga)
            row = sql(f"select source || '|' || version || '|' || coalesce(profile_id,'') || '|' || (accepted_at > now() - interval '5 minutes')::text from public.hdm_consents c join auth.users u on u.id = c.user_id where u.email = '{MAIL}gate@example.invalid'")
            check('תיעוד: מזהה משתמש, פרופיל, גרסה, מקור ושעה', row == f"gate|{CONSENT}|{IDS['gate']}|true", row)
            check('הפרופיל הקיים לא השתנה', sql(f"select data->>'currentName' from docs where collection='profiles' and id='{IDS['gate']}'") == PEOPLE['gate'][0])
            pg.reload(); pg.wait_for_timeout(5000)
            check('אחרי רענון: לא מבקשים לאשר שוב', pg.evaluate("() => myId") == IDS['gate'] and not pg.evaluate("() => document.getElementById('terms-gate').classList.contains('open')"))
            logout(pg)

        # התחברות
        bad = login(pg, 'basic', 'wrong-password-123')
        check('התחברות: סיסמה שגויה נדחית', not bad['myId'] and 'שגויים' in bad['status'], bad)
        ok = login(pg, 'basic')
        check('התחברות: נכנסים לפרופיל הנכון (Auth אמיתי)', ok['myId'] == B and ok['screen'] == 'screen-match', ok)
        ent = pg.evaluate("async () => await hdmRefreshPlan(true)")
        check('המסלול מהשרת: בסיסי, 5 שיחות, ₪29.90', ent.get('plan') == 'basic' and ent.get('chatsLimit') == 5 and ent.get('priceAgorot') == 2990, ent)
        check('הפרופיל שלי כולל את תאריך הלידה (מהשרת)', pg.evaluate("() => myProfile && myProfile.birthdate") == PEOPLE['basic'][1])
        pg.reload(); pg.wait_for_timeout(5000)
        check('אחרי רענון: נשאר מחובר', pg.evaluate("() => myId") == B, pg.evaluate("() => myId"))

        # דירוג, פרטיות, 🎯
        c = card(pg, P)
        check('בסיסי: דירוג מהשרת בלי פירוט', c and c['pct'] in ('התאמה מצוינת', 'התאמה טובה', 'התאמה חלשה') and c['why'] == 'none' and 'categories' not in (c['rating'] or {}), c)
        check('פרופיל של אחר: בלי תאריך לידה, שם מלידה ומספרים', c and c['leak'] == [], c)
        h = target(pg)
        check('🎯 חד-צדדי: נשמר בשרת, בלי צ׳אט', 'נשמר' in h and sql(f"select count(*) from docs where collection='interests' and id='{B}__{P}'") == '1'
              and sql(f"select count(*) from docs where collection='chats' and id like '%{B}%'") == '0', h)
        d1 = pg.evaluate(f"""async () => {{ const r = await window.__sb.from('docs').upsert({{collection:'interests', id:'{B}__{F}', data:{{from:'{B}',to:'{F}'}}}}); return r.error ? 'blocked' : 'ok'; }}""")
        check('עקיפה: כתיבת 🎯 ישירות לטבלה נחסמת', d1 == 'blocked', d1)
        d2 = pg.evaluate(f"""async () => {{ const r = await window.__sb.rpc('hdm_claim_profile', {{p_proposed:'{P}'}}); return r.data; }}""")
        check('עקיפה: אי אפשר להשתלט על פרופיל של אחר', d2 == B, d2)
        d3 = pg.evaluate("""async () => { const r = await window.__sb.from('hdm_subscriptions').select('*'); return r.error ? 'blocked' : (r.data||[]).length; }""")
        check('עקיפה: אין קריאה של טבלת המנויים', d3 in ('blocked', 0), d3)
        d4 = pg.evaluate(f"""async () => {{ const r = await window.__sb.rpc('hdm_admin_set_plan', {{p_profile:'{B}', p_plan:'vip'}}); return r.error ? 'blocked' : 'ok'; }}""")
        check('עקיפה: אי אפשר להפעיל פונקציית מנהל (שדרוג עצמי)', d4 == 'blocked', d4)
        d5 = pg.evaluate("""async () => { const r = await window.__sb.from('hdm_profile_private').select('*'); return r.error ? 'blocked' : (r.data||[]).length; }""")
        check('עקיפה: אין קריאה של פרטי לידה (טבלה סגורה)', d5 in ('blocked', 0), d5)
        if hardened:
            pg.evaluate(f"async () => {{ await dbCap.doc('profiles/{B}').update({{ plan: 'vip', isVerified: true }}); }}")
            check('שדות זרים בפרופיל לא נשמרים (05)', sql(f"select (data ?| array['plan','isVerified'])::text from docs where collection='profiles' and id='{B}'") == 'false')
        logout(pg)

        # פלוס: מי סימן, הדדיות → צ׳אט, הודעה, ניתוח
        login(pg, 'plus')
        cp = card(pg, B)
        check('פלוס: דירוג עם פירוט קטגוריות', cp and len((cp['rating'] or {}).get('categories', [])) > 0, cp)
        who = pg.evaluate("async () => { await hdmOpenLikedMe(); await new Promise(r => setTimeout(r, 2000)); return document.getElementById('hdm-liked-body').innerText; }")
        check('פלוס: "מי סימן אותי" מציג את מי שסימן', 'בני' in who, who)
        pg.evaluate("() => { try{ hdmCloseLayer('hdm-liked-screen'); }catch(e){} }")
        card(pg, B); target(pg); pg.wait_for_timeout(1500)
        pair = '__'.join(sorted([B, P]))
        check('🎯 הדדי: השרת פתח שיחה והצ׳אט נפתח', sql(f"select count(*) from docs where collection='chats' and id='{pair}'") == '1'
              and pg.evaluate("() => document.getElementById('screen-chat').classList.contains('active')"))
        pg.fill('#chat-input', 'שלום מבדיקת e2e'); pg.click('#send-chat-btn')
        last = ''
        for _ in range(20):  # עד 10 שניות — שמירה בשרת יכולה להתעכב ברשת של GitHub
            pg.wait_for_timeout(500)
            last = sql(f"select coalesce(data->'messages'->-1->>'text','') from docs where collection='chats' and id='{pair}'")
            if 'שלום מבדיקת e2e' in last: break
        check('הודעה נשמרת בשרת', 'שלום מבדיקת e2e' in last, last)
        an = pg.evaluate("async () => { await hdmOpenAnalysis(); await new Promise(r=>setTimeout(r,1200)); return document.getElementById('hdm-analysis-body').innerText; }")
        check('פלוס: ניתוח מורחב אחרי הדדיות', '+' in an and 'דרך חיים' in an, an[:100])
        logout(pg)

        # חינם
        login(pg, 'free'); pg.evaluate("async () => { await hdmRefreshPlan(true); }")
        cf = card(pg, B)
        check('חינם: רואים פרופילים, בלי דירוג', cf and cf['n'] >= 2 and cf['rating'] is None and cf['pctShown'] == 'none', cf)
        target(pg)
        check('חינם: 🎯 פותח מסך מסלולים ולא נשמר', pg.evaluate("() => hdmLayerOpen('hdm-plans-screen')")
              and sql(f"select count(*) from docs where collection='interests' and id like '{F}\\_\\_%'") == '0')
        plans = pg.inner_text('#hdm-plans-body')
        check('מסך המסלולים: ₪0 / ₪29.90 / ₪48.90 / ₪79.90', all(x in plans for x in ['₪0', '₪29.90', '₪48.90', '₪79.90']), plans[:150])
        peek = pg.evaluate("async () => { const r = await window.__sb.from('docs').select('id').eq('collection','chats'); return (r.data||[]).length; }")
        check('חינם: לא רואה שיחות של אחרים', peek == 0, peek)
        logout(pg)

        # VIP
        login(pg, 'vip'); pg.evaluate("async () => { await hdmRefreshPlan(true); }")
        card(pg, B); target(pg)
        av = pg.evaluate("async () => { await hdmOpenAnalysis(); await new Promise(r=>setTimeout(r,1200)); return document.getElementById('hdm-analysis-body').innerText; }")
        check('VIP: ניתוח מורחב מיד אחרי 🎯, עם הנחת 30%', '30%' in av and '+' in av, av[-120:])
        check('VIP: בלי הדדיות אין צ׳אט', sql(f"select count(*) from docs where collection='chats' and id like '%{V}%'") == '0')
        logout(pg)

        # מכסת בסיסי: 6 שותפות סימנו את בני; השיחה השישית חסומה (1 כבר נפתחה עם פנינה)
        for i in range(6):
            q = IDS[f'q{i}']
            sql(f"insert into docs(collection,id,data) values ('interests','{q}__{B}', jsonb_build_object('from','{q}','to','{B}','ts',0))")
        login(pg, 'basic'); hints = []
        for i in range(6):
            card(pg, IDS[f'q{i}']); hints.append(target(pg)); pg.evaluate("() => go('screen-match')"); pg.wait_for_timeout(300)
        opened = sql(f"select count(*) from hdm_chat_openings where profile_id='{B}'")
        check('בסיסי: בדיוק 5 שיחות חדשות בחודש', opened == '5', opened)
        check('בסיסי: השיחה השישית חסומה עם הודעת מכסה', any('נוצלו' in x for x in hints[4:]), hints[-2:])
        check('מסך המנוי: נותרו 0 מתוך 5', pg.evaluate("async () => (await hdmRefreshPlan(true)).chatsLeft") == 0)

        # מנוי שפג
        sql(f"select public.hdm_admin_expire('{B}')")
        pg.evaluate(f"""async () => {{ await hdmRefreshPlan(true); const s = await dbCap.doc('profiles/{P}').get(); currentMatchId='{P}'; currentMatchData=s.data(); openChat(); }}""")
        pg.wait_for_timeout(2500)
        check('מנוי שפג: ההודעות מוצגות, הכתיבה נעולה', 'שלום מבדיקת e2e' in pg.inner_text('#chat-msgs')
              and pg.evaluate("() => document.querySelector('.phone').classList.contains('hdm-chat-locked')"))
        logout(pg)
        check('התנתקות: אין session', pg.evaluate("async () => !myId && !(await window.__sbAuth.auth.getSession()).data.session"))
        pg.reload(); pg.wait_for_timeout(4000)
        check('אחרי התנתקות ורענון: לא נכנסים אוטומטית', not pg.evaluate("() => myId"))

        # מחיקת חשבון (של משתמשת הבדיקה "חינם")
        login(pg, 'free')
        pg.evaluate("() => openDeleteAccount()")
        gone = pg.evaluate("async () => { document.getElementById('hdm-del-confirm').value = 'מחיקה'; await hdmDeleteAccount(); await new Promise(r=>setTimeout(r,1200)); return !myId; }")
        check('מחיקת חשבון: הפרופיל והנתונים נמחקו והמשתמש נותק', gone and sql(f"select count(*) from docs where collection='profiles' and id='{F}'") == '0'
              and sql(f"select count(*) from hdm_accounts where profile_id='{F}'") == '0')
        if hardened:
            check('מחיקת חשבון: גם משתמש ההתחברות נמחק (05)', sql(f"select count(*) from auth.users where email='{MAIL}free@example.invalid'") == '0')

        if CONSENT:
            # --- שינוי מהותי במסמכים: כל משתמש מאשר מחדש (גרסת בדיקה שנמחקת בסוף בכל מקרה) ---
            try:
                sql(f"select public.hdm_admin_publish_terms('{RECONSENT_V}', true, 'e2e: אישור מחדש')")
                login(pg, 'gate')
                rg = pg.evaluate("() => ({ gate: document.getElementById('terms-gate').classList.contains('open'), title: document.getElementById('tg-title').textContent, myId: myId })")
                check('שינוי מהותי: מי שאישר קודם מתבקש לאשר מחדש', rg['gate'] and rg['title'] == 'עדכנו את המסמכים' and not rg['myId'], rg)
                pg.click('#tg-logout'); pg.wait_for_timeout(3000)
                check('"לא עכשיו": מתנתקים, בלי session', pg.evaluate("async () => !myId && !(await window.__sbAuth.auth.getSession()).data.session"))
                login(pg, 'gate')
                pg.check('#tg-consent'); pg.click('#tg-accept')
                try: pg.wait_for_function(f"() => myId === '{IDS['gate']}'", timeout=15000)
                except Exception: pass
                hist = sql(f"select string_agg(version, ',' order by accepted_at) from public.hdm_consents c join auth.users u on u.id = c.user_id where u.email = '{MAIL}gate@example.invalid'")
                check('אישור מחדש: נכנסים, וההיסטוריה שומרת את שתי הגרסאות', pg.evaluate("() => myId") == IDS['gate'] and hist == f"{CONSENT},{RECONSENT_V}", hist)
                logout(pg)
            finally:
                sql(f"begin; delete from public.hdm_consents where version = '{RECONSENT_V}'; delete from public.hdm_terms_versions where version = '{RECONSENT_V}'; commit;")
            check('גרסת הבדיקה נמחקה: הגרסה הנדרשת חזרה', sql("select public.hdm_required_terms_version()") == CONSENT)

        check('אין שגיאות JavaScript בדף', not errors, errors[:2])
        check('הדף פנה רק ל-Staging (לא לפרויקט הפעיל)', not any('qtspzigjlbtckqfyaubp' in h for h in seen_hosts), sorted(seen_hosts))
        br.close()
    exit_code = 0 if all(results) else 1
except Exception as e:
    print('FAIL שגיאה בבדיקה: ' + str(e)[:300], flush=True); exit_code = 1
finally:
    left = cleanup()
    print(f'ניקוי: נשארו {left} רשומות בדיקה', flush=True)
    if left != '0': exit_code = 1
    srv.shutdown()
print(f'SUMMARY {sum(results)}/{len(results)} passed', flush=True)
sys.exit(exit_code)
