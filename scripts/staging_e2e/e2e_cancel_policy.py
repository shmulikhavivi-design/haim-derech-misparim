# =====================================================================
# חיים דרך מספרים — בדיקת דפדפן: כפתור "ביטול מנוי" ומדיניות ביטול מנוי בגרסה שעולה לאוויר
# (staging.html שממנו נבנה index.html) מול Staging בלבד. בלי סליקה, בלי חיובים, בלי שינוי במסד מצד הדף.
# משתמשי בדיקה: hdm-cxl-<ריצה>-*@example.invalid, מזהי פרופיל cxl<ריצה>_*. בסוף — ובכל כישלון — הכול נמחק.
# משתני סביבה: STAGING_DB_URL (סוד), STAGING_PUBLISHABLE_KEY (מפתח ציבורי), PAGE (נתיב ל-staging.html)
# =====================================================================
import json, os, random, string, subprocess, sys, http.server, threading, functools
from playwright.sync_api import sync_playwright

DB = os.environ['STAGING_DB_URL']
KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', '')
PAGE = os.environ.get('PAGE', 'staging.html')
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'cxl{RUN}_'
MAIL = f'hdm-cxl-{RUN}-'
PW = 'Cxl-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(20))
if not KEY.startswith('sb_publishable_'):
    print('⛔ STAGING_PUBLISHABLE_KEY חסר או לא ציבורי'); sys.exit(2)

def sql(q):
    r = subprocess.run(['psql', DB, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q], capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError('sql: ' + r.stderr.strip()[:200])
    return r.stdout.strip()

results = []
def check(name, ok, got=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {str(got)[:200]}'), flush=True)

CRYPT = 'extensions.crypt' if sql("select count(*) from pg_proc where proname='crypt' and pronamespace='extensions'::regnamespace") != '0' else 'crypt'
SALT = CRYPT.replace('crypt', 'gen_salt')
PEOPLE = {'free': 'פנינה חינם', 'plus': 'פלורה ותיקה'}
IDS = {k: PFX + k for k in PEOPLE}
IDS_SQL = "array[" + ",".join(f"'{v}'" for v in IDS.values()) + "]"

def cleanup():
    sql(f"""begin;
      delete from public.hdm_subscription_events where profile_id = any({IDS_SQL});
      delete from public.hdm_subscriptions where profile_id = any({IDS_SQL});
      delete from public.docs where collection = 'profiles' and id = any({IDS_SQL});
      delete from public.hdm_accounts where profile_id = any({IDS_SQL});
      delete from auth.users where email like '{MAIL}%@example.invalid';
      commit;""")
    return sql(f"""select (select count(*) from auth.users where email like '{MAIL}%') + (select count(*) from public.hdm_accounts where profile_id like '{PFX}%')
                 + (select count(*) from public.hdm_subscriptions where profile_id like '{PFX}%')""")

def create_people():
    consent = sql("select public.hdm_required_terms_version()")
    for k, name in PEOPLE.items():
        pid, email = IDS[k], f'{MAIL}{k}@example.invalid'
        profile = json.dumps({'currentName': name, 'birthdate': '1990-01-01', 'birthFirstName': 'א', 'birthLastName': 'ב', 'gender': 'אישה',
                              'lookingFor': 'גברים', 'location': 'חיפה', 'photoUrl': 'data:image/png;base64,iVBORw0KGgo=', 'createdAt': 0}, ensure_ascii=False)
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
          , a as (insert into public.hdm_accounts (auth_user_id, profile_id) select id, '{pid}' from u)
          insert into public.hdm_consents (user_id, profile_id, version, source) select id, '{pid}', '{consent}', 'signup' from u;
          insert into public.docs (collection, id, data) values ('profiles', '{pid}', $j${profile}$j$::jsonb);
          commit;""")
    # ותיקה: פלוס ידני ללא הגבלת זמן וללא תשלום (כמו 4 החשבונות הקיימים)
    sql(f"select public.hdm_admin_set_plan('{IDS['plus']}', 'plus', null, 'e2e cancel policy')")

html_dir = os.path.dirname(os.path.abspath(PAGE))
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=html_dir))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()
APP = f'http://127.0.0.1:{srv.server_address[1]}/{os.path.basename(PAGE)}'
seen_hosts, errors, billing_calls = set(), [], []

def on_request(r):
    seen_hosts.add(r.url.split('/')[2])
    if 'hdm_billing' in r.url or 'hdm_checkout' in r.url: billing_calls.append(r.url)

def new_page(ctx, url):
    pg = ctx.new_page(); pg.on('pageerror', lambda e: errors.append(str(e))); pg.on('request', on_request)
    pg.goto(url); pg.wait_for_timeout(2500)
    return pg

def login(pg, k):
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
    pg.fill('#li-email', f'{MAIL}{k}@example.invalid'); pg.fill('#li-pass', PW); pg.click('#li-submit')
    try: pg.wait_for_function("() => myId || document.getElementById('li-status').textContent.trim()", timeout=15000)
    except Exception: pass
    pg.wait_for_timeout(500)
    return pg.evaluate("() => myId")

def wait_plan(pg):
    try: pg.wait_for_function("() => hdmEnt && hdmEnt.forId === myId && !hdmEnt.error", timeout=15000)
    except Exception: pass
    pg.wait_for_timeout(400)

TOUCH = [False]
NOT_DONE = ['המנוי בוטל', 'בקשת הביטול התקבלה ב', 'בוטל בהצלחה']

def tap(pg, sel):
    # באייפון (מסך מגע) — הקשה אמיתית; בדסקטופ — לחיצה
    loc = pg.locator(sel).first
    loc.wait_for(state='visible', timeout=15000)
    loc.scroll_into_view_if_needed()
    if TOUCH[0]: loc.tap()
    else: loc.click()
    pg.wait_for_timeout(350)

def touch_ok(pg, sel, label, min_h=44):
    # הכפתור קיים, גלוי, בגובה מגע של 44px לפחות, ונכנס ברוחב המסך (אין גלילה אופקית)
    loc = pg.locator(sel).first
    loc.wait_for(state='visible', timeout=15000)   # מסכים נטענים באסינכרוניות (בעיקר בספארי)
    loc.scroll_into_view_if_needed(); pg.wait_for_timeout(150)
    bb = loc.bounding_box() or {}
    vw = pg.evaluate("() => window.innerWidth")
    ok = loc.is_visible() and bb.get('height', 0) >= min_h and bb.get('x', -1) >= 0 and bb.get('x', 0) + bb.get('width', 0) <= vw + 1
    check(label + ': גלוי, גובה מגע ≥' + str(min_h) + 'px ובתוך רוחב המסך', ok, bb)

def legal_scrolls(pg, label):
    # המסמך נגלל בתוך המסך (חשוב בספארי באייפון), ואפשר להגיע לסופו
    pg.wait_for_timeout(200)
    info = pg.evaluate("""() => { var f = document.getElementById('legal-screen'); var a = f.scrollHeight > f.clientHeight + 50;
                                  f.scrollTop = f.scrollHeight; return { tall: a, moved: f.scrollTop > 0, open: f.classList.contains('open') }; }""")
    check(label + ': המסמך נפתח ונגלל עד סופו', info['open'] and info['tall'] and info['moved'], info)
    pg.evaluate("() => { document.getElementById('legal-screen').scrollTop = 0; }")

def run_browser(pw, name, launcher, ctx_opts):
    br = launcher.launch()
    TOUCH[0] = bool(ctx_opts.get('has_touch'))
    def ctx_new():
        c = br.new_context(**ctx_opts)
        c.add_init_script(f"try{{ localStorage.setItem('hdm_staging_publishable_key', {json.dumps(KEY)}); }}catch(e){{}}"); return c
    P = f'[{name}] '

    # --- לא מחובר: מסך הפתיחה ---
    c = ctx_new(); pg = new_page(c, APP)
    check(P + 'מסך הפתיחה: קישור "ביטול מנוי"', pg.locator('#auth-cancel-link').count() == 1)
    check(P + 'מסך הפתיחה: קישור "מדיניות ביטול מנוי"', pg.locator('#auth-cancel-policy').count() == 1)
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; }catch(e){} }")
    tap(pg, '#auth-cancel-link')
    lt = pg.inner_text('#legal-body')
    check(P + 'לא מחובר: "ביטול מנוי" פותח את מדיניות הביטול', pg.inner_text('#legal-title') == 'מדיניות ביטול מנוי' and 'איך מבטלים' in lt, lt[:200])
    need = ['מתחדש אוטומטית', 'איך מבטלים', 'ביטול מנוי', 'לא יתבצע שום חיוב נוסף', '3 ימי עסקים', 'סוף התקופה ששולמה',
            'ביטול בתוך 14 יום', 'לא ייגבו דמי ביטול', 'אינו מחיקת חשבון', 'תאריך סיום המנוי', 'אישור באימייל', 'חיוב שנכשל',
            'שינויים במחיר', 'עדיין לא פתוחים לרכישה', 'הפרופיל שלי', 'life.through.numbers333@gmail.com']
    miss = [w for w in need if w not in lt]
    check(P + 'תוכן המדיניות: כל הסעיפים הנדרשים', not miss, miss)
    legal_scrolls(pg, P + 'מדיניות ביטול מנוי')
    touch_ok(pg, '#legal-screen .signup-back', P + 'כפתור "חזרה" במסמך')
    tap(pg, '#legal-screen .signup-back')
    check(P + '"חזרה" סוגר את המסמך', not pg.evaluate("() => document.getElementById('legal-screen').classList.contains('open')"))
    check(P + 'מסך הפתיחה: "האפליקציה מיועדת לבני 18 ומעלה בלבד"', 'לבני 18 ומעלה' in pg.inner_text('#auth-age-note'))
    tap(pg, '#auth-business')
    bt = pg.inner_text('#legal-body')
    check(P + 'עמוד "מחירים, אספקת השירות ופרטי העסק"', pg.inner_text('#legal-title') == 'מחירים, אספקת השירות ופרטי העסק', pg.inner_text('#legal-title'))
    need = ['פרטי העסק', 'מספר עוסק', 'כתובת בית העסק', 'טלפון', 'life.through.numbers333@gmail.com', 'השירותים והמחירים',
            '₪29.90 לחודש', '₪48.90 לחודש', '₪79.90 לחודש', '₪0', 'אופן התשלום', 'תיבת אישור', 'קבלה', 'אספקת השירות', 'מיד לאחר אישור התשלום',
            'תוך 24 שעות', 'תוך 2 ימי עסקים', 'נחזיר את מלוא הסכום', 'ביטול עסקה ומנוי', '14 יום', '18 ומעלה', 'אחריות בית העסק',
            'נשיב תוך 3 ימי עסקים', 'שמוליק חביבי ולימור רון']
    miss = [w for w in need if w not in bt]
    check(P + 'תוכן: פרטי עסק, מחירים, תשלום, אספקה וזמני טיפול, החזר, ביטול, גיל, אחריות, יצירת קשר', not miss, miss)
    legal_scrolls(pg, P + 'מחירים ופרטי העסק')
    biz = pg.evaluate("() => HDM_BUSINESS")
    empty = [k for k in ('legalId', 'address', 'phone', 'vatNote') if not biz.get(k)]
    print(P + 'INFO פרטי עסק שעוד לא הוזנו: ' + (', '.join(empty) if empty else 'אין'), flush=True)
    pg.evaluate("() => openLegal('terms')")
    tt = pg.inner_text('#legal-body')
    check(P + 'תנאי השימוש: סעיף "מנויים, תשלום וביטול" עם הפניה למדיניות', 'מנויים, תשלום וביטול' in tt and 'מדיניות ביטול מנוי' in tt and 'מתחדש אוטומטית' in tt, tt[:200])
    pg.evaluate("() => closeLegal()")
    c.close()

    # --- קישורים ישירים למסמכים (לבודק של ספק הסליקה ולשיתוף עם לקוחות) ---
    for h, title in [('cancel-policy', 'מדיניות ביטול מנוי'), ('business', 'מחירים, אספקת השירות ופרטי העסק'), ('terms', 'תנאי שימוש'), ('cancel', 'מדיניות ביטול מנוי')]:
        c = ctx_new(); pg = new_page(c, APP + '#' + h)
        got = pg.evaluate("() => document.getElementById('legal-screen').classList.contains('open') ? document.getElementById('legal-title').textContent : ''")
        check(P + f'קישור ישיר ‎#{h}‎ פותח את "{title}"', got == title, got)
        c.close()

    # --- חינם ---
    c = ctx_new(); pg = new_page(c, APP)
    check(P + 'חינם: התחברות', login(pg, 'free') == IDS['free'])
    check(P + 'מסך ראשי: קישור "ניהול מנוי"', 'ניהול מנוי' in pg.inner_text('#hdm-plans-link'))
    # האזור האישי ("הפרופיל שלי"): כפתור "ביטול מנוי" בולט
    # כמו משתמש: מחכים שמסך ההתאמות סיים להיטען (אחרי התחברות האפליקציה עוברת אליו בעצמה), ואז מקישים "הפרופיל שלי"
    try: pg.wait_for_selector('#screen-match.active', timeout=20000)
    except Exception: pass
    pg.wait_for_timeout(2000)
    for _ in range(3):
        tap(pg, '#my-profile-link')
        try: pg.wait_for_selector('#screen-profile.active', timeout=10000)
        except Exception: pass
        pg.wait_for_timeout(1000)
        if pg.locator('#screen-profile.active').count() == 1: break
        pg.evaluate("() => go('screen-match')"); pg.wait_for_timeout(1500)
    check(P + 'הפרופיל שלי: יש "ניהול מנוי" ו"ביטול מנוי"', pg.locator('#profile-manage-sub').count() == 1 and pg.locator('#profile-cancel-sub').count() == 1)
    touch_ok(pg, '#profile-cancel-sub', P + 'כפתור "ביטול מנוי" בפרופיל', 48)
    tap(pg, '#profile-cancel-sub'); wait_plan(pg)
    check(P + 'הפרופיל: "ביטול מנוי" פותח ישר את שלב האישור', pg.locator('#hdm-cancel-info').count() == 1 and pg.locator('#hdm-cancel-confirm').is_visible())
    pg.evaluate("() => { hdmCloseLayer('hdm-plans-screen'); go('screen-match'); }")
    pg.evaluate("() => hdmOpenPlans()"); wait_plan(pg)
    t = pg.inner_text('#hdm-plans-body')
    check(P + 'כותרת: "ניהול מנוי"', pg.inner_text('#hdm-plans-screen .about-title').strip() == 'ניהול מנוי')
    check(P + 'יש כפתור "ביטול מנוי" בניהול המנוי', pg.locator('#hdm-bill-cancel').count() == 1)
    touch_ok(pg, '#hdm-bill-cancel', P + 'כפתור "ביטול מנוי" בניהול המנוי', 48)
    check(P + 'לפני רכישה: הסבר חידוש וביטול + קישור למדיניות', pg.locator('#hdm-plans-policy a').count() == 2 and 'מתחדשים אוטומטית' in t, t[-300:])
    check(P + 'אין אפשרות רכישה: כל כפתורי המסלולים כבויים', pg.locator('.hdm-plan-btn:not([disabled])').count() == 0 and 'בקרוב' in t)
    tap(pg, '#hdm-bill-cancel')
    t = pg.inner_text('#hdm-plans-body')
    check(P + 'שלב 1: מצב המנוי — אין מנוי בתשלום ולא בוצע חיוב', 'אין לך מנוי בתשלום' in t and 'לא בוצע שום חיוב' in t and 'חינם' in t, t[:400])
    check(P + 'שלב 1: מה קורה בביטול (חידוש נעצר, עד סוף התקופה, 14 יום, לא מוחק חשבון)',
          all(w in t for w in ['החידוש האוטומטי נעצר מיד', 'סוף התקופה ששולמה', '14 יום', 'לא מוחק את החשבון']), t[:600])
    check(P + 'שלב 1: לא מוצג ביטול שבוצע', not any(w in t for w in NOT_DONE), t[:400])
    touch_ok(pg, '#hdm-cancel-confirm', P + 'כפתור "אישור ביטול החידוש האוטומטי"')
    tap(pg, '#hdm-cancel-confirm')
    t = pg.inner_text('#hdm-plans-body')
    today = pg.evaluate("() => new Date().toLocaleDateString('he-IL')")
    check(P + 'שלב 2: אישור על בקשת הביטול עם מועד הבקשה', pg.locator('#hdm-cancel-done').count() == 1 and 'בקשת הביטול התקבלה' in t and today in pg.inner_text('#hdm-cancel-at'), t[:400])
    check(P + 'שלב 2: חידוש אוטומטי כבוי ולא יתבצע חיוב', pg.inner_text('#hdm-cancel-renew') == 'כבוי' and 'לא יתבצע שום חיוב' in t, t[:400])
    check(P + 'שלב 2: מועד סיום המנוי מוצג', 'מועד סיום המנוי' in t and 'אין מנוי בתשלום לסיים' in pg.inner_text('#hdm-cancel-end'), t[:500])
    check(P + 'שלב 2: אפשרות לבקשה באימייל', 'mailto:life.through.numbers333@gmail.com' in (pg.get_attribute('#hdm-cancel-mail', 'href') or ''))
    check(P + 'שלב 2: לא נכתב "המנוי בוטל"', not any(w in t for w in NOT_DONE), t[:400])
    pg.locator('#hdm-plans-policy a').first.click(); pg.wait_for_timeout(300)
    check(P + 'הקישור במסך המסלולים פותח את המדיניות', pg.inner_text('#legal-title') == 'מדיניות ביטול מנוי')
    pg.evaluate("() => closeLegal()")
    check(P + 'הגדרות: "ביטול מנוי", "מדיניות ביטול מנוי", "מחירים ופרטי העסק"', pg.locator('#set-cancel-sub').count() == 1 and pg.locator('#set-cancel-policy').count() == 1 and pg.locator('#set-business').count() == 1)
    pg.evaluate("() => { hdmCloseLayer('hdm-plans-screen'); hdmCancelEntry(); }"); wait_plan(pg)
    check(P + '"ביטול מנוי" בהגדרות: פותח ישר את שלב האישור', pg.locator('#hdm-cancel-info').count() == 1)
    check(P + 'חינם: נשארה במסלול החינמי', sql(f"select public.hdm_plan_of('{IDS['free']}')") == 'free')
    c.close()

    # --- פלוס ידני (ללא תשלום) ---
    c = ctx_new(); pg = new_page(c, APP)
    check(P + 'ותיקה: התחברות', login(pg, 'plus') == IDS['plus'])
    pg.evaluate("() => hdmCancelEntry()"); wait_plan(pg)
    t = pg.inner_text('#hdm-plans-body')
    check(P + 'ותיקה: "המסלול הוגדר ללא תשלום"', 'הוגדר לך ללא תשלום' in t and 'פלוס' in t, t[:400])
    tap(pg, '#hdm-cancel-confirm')
    t = pg.inner_text('#hdm-plans-body')
    check(P + 'ותיקה: אישור עם מועד סיום (פלוס ללא תשלום, לא מתחדש בתשלום)', 'פלוס' in pg.inner_text('#hdm-cancel-end') and 'ללא תשלום' in pg.inner_text('#hdm-cancel-end'), t[:400])
    check(P + 'ותיקה: לא מוצג ביטול שבוצע', not any(w in t for w in NOT_DONE), t[:400])
    check(P + 'ותיקה: נשארה בפלוס', sql(f"select public.hdm_plan_of('{IDS['plus']}')") == 'plus')
    c.close()
    br.close()

print(f'ריצה {RUN}', flush=True)
exit_code = 1
try:
    create_people()
    subs_before = sql("select count(*) || '|' || coalesce(max(updated_at)::text, '') from public.hdm_subscriptions")
    with sync_playwright() as pw:
        # דסקטופ (Chromium) + אייפון 13 בספארי (WebKit, מסך מגע, viewport ו-user agent של iPhone)
        run_browser(pw, 'Chrome', pw.chromium, {})
        run_browser(pw, 'iPhone Safari', pw.webkit, dict(pw.devices['iPhone 13']))
        check('הדף לא קרא לשום פונקציית חיוב/ביטול בשרת', not billing_calls, billing_calls[:2])
        check('לא השתנה שום מנוי במסד', sql("select count(*) || '|' || coalesce(max(updated_at)::text, '') from public.hdm_subscriptions") == subs_before)
        check('אין שגיאות JavaScript בדף', not errors, errors[:2])
        check('הדף פנה רק ל-Staging (לא לפרויקט הפעיל)', not any('qtspzigjlbtckqfyaubp' in h for h in seen_hosts), sorted(seen_hosts))
    exit_code = 0 if results and all(results) else 1
except Exception as e:
    print('FAIL שגיאה בבדיקה: ' + str(e)[:300], flush=True); exit_code = 1
finally:
    left = cleanup()
    print(f'ניקוי: נשארו {left} רשומות בדיקה', flush=True)
    if left != '0': exit_code = 1
    srv.shutdown()
print(f'SUMMARY {sum(results)}/{len(results)} passed', flush=True)
sys.exit(exit_code)
