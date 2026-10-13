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
IDS = {k: PFX + k for k in PEOPLE}

def cleanup():
    ids = "array[" + ",".join(f"'{v}'" for v in IDS.values()) + "]"
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
    for k, (name, birth, first, last, gender, looking, plan) in PEOPLE.items():
        pid, email = IDS[k], f'{MAIL}{k}@example.invalid'
        profile = json.dumps({'currentName': name, 'birthdate': birth, 'birthFirstName': first, 'birthLastName': last,
                              'gender': gender, 'lookingFor': looking, 'location': 'תל אביב', 'occupation': 'בדיקה',
                              'interests': 'מוזיקה', 'photoUrl': 'data:image/png;base64,iVBORw0KGgo=', 'createdAt': 0}, ensure_ascii=False)
        sql(f"""begin;
          with u as (
            insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                                    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                                    confirmation_token, recovery_token, email_change_token_new, email_change)
            values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', '{email}',
                    {CRYPT}('{PW}', {SALT}('bf')), now(), '{{"provider":"email","providers":["email"]}}', '{{}}', now(), now(), '', '', '', '')
            returning id)
          , i as (insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
                  select gen_random_uuid(), u.id::text, u.id, jsonb_build_object('sub', u.id::text, 'email', '{email}', 'email_verified', true), 'email', now(), now(), now() from u)
          insert into public.hdm_accounts (auth_user_id, profile_id) select id, '{pid}' from u;
          insert into public.docs (collection, id, data) values ('profiles', '{pid}', $j${profile}$j$::jsonb);
          commit;""")
        if plan: sql(f"select public.hdm_admin_set_plan('{pid}', '{plan}', 30, 'e2e')")

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
        pg.fill('#chat-input', 'שלום מבדיקת e2e'); pg.click('#send-chat-btn'); pg.wait_for_timeout(2000)
        check('הודעה נשמרת בשרת', 'שלום מבדיקת e2e' in sql(f"select data->'messages'->-1->>'text' from docs where collection='chats' and id='{pair}'"))
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
