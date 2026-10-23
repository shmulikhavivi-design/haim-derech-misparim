#!/usr/bin/env python3
# =====================================================================
# livecheck — בדיקה חיה אחרי ההשקה, על האתר האמיתי ו-Production. בלי תשלום ובלי לחיצה על "לתשלום".
# משתמש בדיקה אחד עם כתובת האפליקציה עצמה (life.through.numbers333+…@gmail.com), לא כתובת פיקטיבית:
#   הרשמה דרך המסך → מייל אישור (Brevo) → פתיחת קישור האישור (אותה כתובת שבמייל) → כניסה מדפדפן נקי
#   → מסך המנויים ועמוד התשלום (בלי לשלם) → בדיקה שההגבלה הוסרה (מצב sync, בלי חיוב)
#   → שכחתי סיסמה → מייל איפוס (Brevo) → קישור האיפוס → סיסמה חדשה → כניסה עם הסיסמה החדשה
#   → מחיקת חשבון מתוך האפליקציה → וידוא שהכול נמחק (כולל פרטי ההתחברות).
# כתובות מייל לא מודפסות (הריפו ציבורי). אם שלב נכשל — עוצרים ולא מוחקים ידנית (הבעלים מחליט).
# =====================================================================
import base64, json, os, random, re, string, sys, time, urllib.parse, urllib.request, urllib.error
from playwright.sync_api import sync_playwright

REF = os.environ['PROD_REF']; TOK = os.environ['TOK']
SITE = os.environ.get('SITE', 'https://shmulikhavivi-design.github.io/haim-derech-misparim/')
SB = f'https://{REF}.supabase.co'
BREVO = re.sub(r'^(BREVO_API_KEY=|api-key:)', '', re.sub(r'[\s"\']', '', os.environ.get('BREVO_API_KEY', '')))
RUN = time.strftime('%m%d%H%M') + ''.join(random.choice(string.ascii_lowercase) for _ in range(3))
EMAIL = f'life.through.numbers333+golive-{RUN}@gmail.com'
PW1 = 'Live-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(18)) + '1!'
PW2 = 'Live2-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(18)) + '1!'
open('/tmp/p.png', 'wb').write(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAVklEQVR4nO3PQQ0AIBDAsIN/z2CCB0nZrSs0M2tm1nIu8MAAAAAAAAAAAAD/AwAAAAAAAPg3AAAAAAAAAH4FAAAAAAAAAB4AAAAAAAAAAAAAAAD8C4w/ASBzA3EPAAAAAElFTkSuQmCC'))
results = []
def check(name, ok, got=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {mask(str(got))[:260]}'), flush=True)
    if not ok: raise SystemExit('STOP')
def mask(s): return re.sub(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+', '<email>', re.sub(r'eyJ[A-Za-z0-9._-]+', '<jwt>', s))
def lit(s): return "'" + s.replace("'", "''") + "'"

def sql(q):
    rq = urllib.request.Request(f'https://api.supabase.com/v1/projects/{REF}/database/query/read-only', data=json.dumps({'query': q}).encode(),
                                headers={'Authorization': f'Bearer {TOK}', 'Content-Type': 'application/json'}, method='POST')
    r = json.loads(urllib.request.urlopen(rq, timeout=60).read())
    if isinstance(r, dict): raise RuntimeError('sql: ' + str(r)[:200])
    return r[0] if r else {}

def brevo_events(subject_part, since):
    if not BREVO: return []
    q = urllib.parse.urlencode({'email': EMAIL, 'limit': 50, 'days': 1, 'sort': 'desc'})
    rq = urllib.request.Request(f'https://api.brevo.com/v3/smtp/statistics/events?{q}', headers={'api-key': BREVO, 'accept': 'application/json'})
    try: ev = json.loads(urllib.request.urlopen(rq, timeout=30).read()).get('events', [])
    except Exception as e: return [f'error {e}']
    return [e.get('event') for e in ev if subject_part.lower() in (e.get('subject') or '').lower()]
def wait_brevo(subject_part, want=('delivered',), secs=150):
    since = time.time(); got = []
    while time.time() - since < secs:
        got = brevo_events(subject_part, since)
        if any(w in got for w in want): return got
        time.sleep(10)
    return got

def counts():
    return sql("select (select count(*) from public.hdm_payments) p, (select count(*) from public.hdm_checkouts) c, (select count(*) from public.hdm_renewal_charges) r, (select count(*) from public.hdm_subscriptions) s")

ANON = re.search(r"sb_publishable_[A-Za-z0-9_-]+|eyJ[A-Za-z0-9._-]{100,}", urllib.request.urlopen(SITE, timeout=30).read().decode()).group(0)
errors = []
def newpage(br):
    c = br.new_context(viewport={'width': 390, 'height': 844}, user_agent='Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1')
    pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)[:200])); return c, pg
def my_id(pg): return pg.evaluate("() => (typeof myId !== 'undefined' && myId) || null")
def login(pg, pw):
    pg.goto(SITE, wait_until='networkidle'); pg.wait_for_timeout(1500)
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
    pg.fill('#li-email', EMAIL); pg.fill('#li-pass', pw); pg.click('#li-submit')
    try: pg.wait_for_function("() => myId || window.__hdmTermsGateOpen || document.getElementById('li-status').textContent.trim()", timeout=25000)
    except Exception: pass
    pg.wait_for_timeout(2500)

print(f'ריצה {RUN} · אתר: {SITE}', flush=True)
before = counts()
code = 1
try:
    html = urllib.request.urlopen(SITE, timeout=30).read().decode()
    check('האתר החי בגרסת ההשקה (תקנון 2026-10-21, רכישה פתוחה, VIP בקרוב)',
          "HDM_TERMS_VERSION = '2026-10-21'" in html and 'var HDM_BILLING_LIVE = true' in html and 'HDM_PLAN_SOON = { vip: true }' in html)
    req = sql("select max(version) v from public.hdm_terms_versions where requires_reconsent")['v']
    check('השרת דורש את התקנון 2026-10-21', req == '2026-10-21', req)
    with sync_playwright() as p:
        br = p.chromium.launch()
        # 1. הרשמה
        c, pg = newpage(br)
        pg.goto(SITE, wait_until='networkidle'); pg.wait_for_timeout(1500)
        pg.evaluate("() => { try { var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; } catch(e){}; openSignup(); }"); pg.wait_for_timeout(700)
        pg.fill('#su-name', 'בדיקת השקה')
        pg.fill('#su-birth', '1990-05-17') if pg.get_attribute('#su-birth', 'type') == 'date' else pg.fill('#su-birth', '17/05/1990')
        pg.select_option('#su-gender', 'אישה'); pg.fill('#su-city', 'חיפה'); pg.fill('#su-email', EMAIL); pg.fill('#su-pass', PW1)
        pg.check('#su-consent', force=True); pg.evaluate('submitSignup()'); pg.wait_for_timeout(1000)
        pg.set_input_files('#su2-photo-input', '/tmp/p.png'); pg.wait_for_timeout(700)
        for sel in pg.evaluate("() => [...document.querySelectorAll('#signup-step2 select')].map(s => s.id)"):
            v = pg.evaluate("(id) => { const o = [...document.getElementById(id).options].find(o => o.value); return o ? o.value : '' }", sel)
            if v: pg.select_option('#' + sel, v)
        for iid, val in [('su2-height', '165'), ('su2-agemin', '30'), ('su2-agemax', '45'), ('su2-bio', 'בדיקה')]:
            try:
                if pg.locator('#' + iid).count() and pg.locator('#' + iid).is_visible() and pg.locator('#' + iid).evaluate('e => e.tagName') != 'SELECT': pg.fill('#' + iid, val)
            except Exception: pass
        pg.evaluate('submitSignupStep2()'); pg.wait_for_timeout(1000)
        pg.fill('#su3-first', 'בדיקה'); pg.fill('#su3-last', 'השקה')
        if pg.locator('#su3-job').count(): pg.fill('#su3-job', 'בדיקות')
        pg.locator('#su3-chips .su-chip').first.click(); pg.evaluate('submitSignupStep3()'); pg.wait_for_timeout(8000)
        st = pg.inner_text('#su3-status'); c.close()
        check('1. הרשמה דרך האתר → "שלחנו מייל לאישור"', 'מייל' in st, st)
        u = sql(f"select (email_confirmed_at is null) unconfirmed, coalesce(confirmation_token,'') tok, raw_user_meta_data->>'hdm_terms' terms from auth.users where email={lit(EMAIL)}")
        check('1. המשתמש נוצר, ממתין לאישור מייל, עם אישור תקנון 2026-10-21', u.get('unconfirmed') is True and len(u.get('tok', '')) > 10 and u.get('terms') == '2026-10-21', {k: (v if k != 'tok' else len(v)) for k, v in u.items()})
        ev = wait_brevo('Confirm')
        check('2. Brevo: מייל אישור ההרשמה נמסר', 'delivered' in ev, ev)
        # 2. קישור האישור — אותה כתובת שבמייל
        c, pg = newpage(br)
        pg.goto(f"{SB}/auth/v1/verify?token={u['tok']}&type=signup&redirect_to={urllib.parse.quote(SITE)}", wait_until='networkidle'); pg.wait_for_timeout(4000)
        conf = sql(f"select (email_confirmed_at is not null) ok from auth.users where email={lit(EMAIL)}")['ok']
        check('2. פתיחת קישור האישור → המייל אושר והאתר נפתח', conf is True and 'haim-derech-misparim' in pg.url, pg.url.split('#')[0])
        c.close()
        # 3. כניסה מדפדפן נקי
        c, pg = newpage(br); login(pg, PW1)
        gate = pg.evaluate("() => !!window.__hdmTermsGateOpen")
        prof = sql(f"select count(*) n from public.docs d join public.hdm_accounts a on a.profile_id=d.id join auth.users u on u.id=a.auth_user_id where d.collection='profiles' and u.email={lit(EMAIL)}")['n']
        check('3. כניסה מדפדפן אחר → בפנים עם הפרופיל, בלי מסך אישור נוסף', bool(my_id(pg)) and prof == 1 and not gate, [my_id(pg), prof, gate])
        cons = sql(f"select string_agg(version, ',') v from public.hdm_consents c join auth.users u on u.id=c.user_id where u.email={lit(EMAIL)}")['v']
        check('3. אישור התקנון נשמר בשרת לגרסה 2026-10-21', cons == '2026-10-21', cons)
        # 4. מסך המנויים ועמוד התשלום — בלי לשלם
        pg.evaluate("() => hdmOpenPlans()")
        try: pg.wait_for_function("() => hdmEnt && hdmEnt.forId === myId && !hdmEnt.error", timeout=20000)
        except Exception: pass
        pg.wait_for_timeout(1000)
        txt = lambda s: pg.inner_text(s) if pg.locator(s).count() else ''
        check('4. בסיסי ₪29.90 ופלוס ₪48.90 עם כפתור הצטרפות', '29.90' in txt('#hdm-plan-card-basic') and '48.90' in txt('#hdm-plan-card-plus') and pg.locator('#hdm-plan-buy-basic').count() == 1 and pg.locator('#hdm-plan-buy-plus').count() == 1)
        check('4. VIP "בקרוב" — כפתור מושבת, בלי הצטרפות', 'בקרוב' in txt('#hdm-plan-card-vip') and pg.locator('#hdm-plan-soon-vip').is_disabled() and pg.locator('#hdm-plan-buy-vip').count() == 0)
        pg.locator('#hdm-plan-buy-plus').click(force=True); pg.wait_for_timeout(800)
        co = txt('#hdm-checkout-body')
        check('4. עמוד התשלום של פלוס: ₪48.90, חידוש אוטומטי, תיבת תקנון לא מסומנת (לא נלחץ "לתשלום")', '48.90' in co and 'חידוש' in co and not pg.locator('#hdm-co-accept').is_checked(), co[:200])
        jwt = pg.evaluate("async () => { const r = await window.__sbAuth.auth.getSession(); return r.data.session.access_token; }")
        rq = urllib.request.Request(f'{SB}/functions/v1/morning-checkout', data=json.dumps({'step': 'sync'}).encode(),
                                    headers={'Authorization': f'Bearer {jwt}', 'apikey': ANON, 'Content-Type': 'application/json'}, method='POST')
        try: st_code, body = urllib.request.urlopen(rq, timeout=30).status, ''
        except urllib.error.HTTPError as e: st_code, body = e.code, e.read()[:120].decode(errors='ignore')
        check('4. הרכישה פתוחה לכל משתמש (השרת כבר לא עונה "עדיין לא פתוח"; בדיקה בלי חיוב)', st_code == 409 and 'no_paid_subscription' in body, [st_code, body])
        c.close()
        # 5. שכחתי סיסמה
        c, pg = newpage(br); pg.goto(SITE, wait_until='networkidle'); pg.wait_for_timeout(1500)
        pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
        pg.fill('#li-email', EMAIL); pg.evaluate("() => hdmOpenForgot()"); pg.wait_for_timeout(500)
        pg.fill('#fp-email', EMAIL); pg.evaluate("() => hdmSubmitForgot()"); pg.wait_for_timeout(5000)
        fs = pg.inner_text('#fp-status'); c.close()
        check('5. שכחתי סיסמה → "נשלח קישור לאיפוס"', 'קישור' in fs, fs)
        rt = sql(f"select coalesce(recovery_token,'') t from auth.users where email={lit(EMAIL)}")['t']
        check('5. נוצר קישור איפוס בשרת', len(rt) > 10)
        ev = wait_brevo('Reset')
        check('5. Brevo: מייל איפוס הסיסמה נמסר', 'delivered' in ev, ev)
        c, pg = newpage(br)
        pg.goto(f"{SB}/auth/v1/verify?token={rt}&type=recovery&redirect_to={urllib.parse.quote(SITE + '?hdm_reset=1')}", wait_until='networkidle'); pg.wait_for_timeout(5000)
        check('5. קישור האיפוס פותח את מסך הסיסמה החדשה', pg.locator('#rp-pass').is_visible(), pg.url.split('#')[0])
        pg.fill('#rp-pass', PW2); pg.fill('#rp-pass2', PW2); pg.evaluate("() => hdmSubmitReset()"); pg.wait_for_timeout(8000)
        c.close()
        c, pg = newpage(br); login(pg, PW1)
        check('5. הסיסמה הישנה כבר לא עובדת', not my_id(pg))
        c.close()
        c, pg = newpage(br); login(pg, PW2)
        check('5. כניסה עם הסיסמה החדשה', bool(my_id(pg)), pg.inner_text('#li-status'))
        # 6. מחיקת חשבון מתוך האפליקציה
        pg.evaluate("() => openDeleteAccount()"); pg.wait_for_timeout(500)
        pg.fill('#hdm-del-confirm', 'מחיקה'); pg.evaluate("() => hdmDeleteAccount()"); pg.wait_for_timeout(9000)
        left = sql(f"select (select count(*) from auth.users where email={lit(EMAIL)}) u, (select count(*) from public.docs where collection='profiles' and id in (select profile_id from public.hdm_accounts a join auth.users x on x.id=a.auth_user_id where x.email={lit(EMAIL)})) d")
        check('6. מחיקת חשבון מהאפליקציה → פרטי ההתחברות והפרופיל נמחקו', left == {'u': 0, 'd': 0}, left)
        c.close()
        check('אין שגיאות JavaScript', not errors, errors[:3])
        br.close()
    code = 0
except SystemExit:
    code = 1
except Exception as e:
    print('ERROR ' + mask(str(e))[:300], flush=True); code = 1
finally:
    after = counts()
    print(('PASS ' if after == before else 'FAIL ') + f'אין תשלום, ניסיון תשלום או חיוב חדש: לפני {before} | אחרי {after}', flush=True)
    if after != before: code = 1
    rem = sql(f"select count(*) n from auth.users where email={lit(EMAIL)}")['n']
    print(f'משתמש הבדיקה בסוף: {"נמחק" if rem == 0 else "עדיין קיים (לא נמחק ידנית — מחכה להחלטת הבעלים)"}', flush=True)
    print(f'SUMMARY {sum(results)}/{len(results)} עברו', flush=True)
sys.exit(code)
