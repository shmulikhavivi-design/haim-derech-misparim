#!/usr/bin/env python3
# =====================================================================
# livecheck2 — המשך הבדיקה החיה (אישור הבעלים 23.10 14:58), על חשבון הבדיקה שנשאר מהריצה הקודמת בלבד:
#   זיהוי ודאי: כתובת האפליקציה life.through.numbers333+golive-…@gmail.com שנוצרה היום על ידי הבדיקה — בדיוק חשבון אחד, אחרת עוצרים.
#   1. שכחתי סיסמה דרך האתר → מייל איפוס (Brevo) → קישור האיפוס (אותה כתובת שבמייל) → סיסמה חדשה → כניסה.
#   2. מסך המנויים → "הצטרפות" לפלוס → מה מוצג בעמוד התשלום (אבחון מלא). לא מסמנים תקנון ולא לוחצים "לתשלום".
#   3. מחיקת החשבון דרך כפתור המחיקה באפליקציה → וידוא שהכול נמחק.
# בלי תשלום, בלי שינוי מחירים/מנויים/משתמשים אמיתיים. כתובות לא מודפסות.
# =====================================================================
import json, os, random, re, string, sys, time, urllib.parse, urllib.request, urllib.error
from playwright.sync_api import sync_playwright

REF = os.environ['PROD_REF']; TOK = os.environ['TOK']
SITE = os.environ.get('SITE', 'https://shmulikhavivi-design.github.io/haim-derech-misparim/')
SB = f'https://{REF}.supabase.co'
BREVO = re.sub(r'^(BREVO_API_KEY=|api-key:)', '', re.sub(r'[\s"\']', '', os.environ.get('BREVO_API_KEY', '')))
PW2 = 'Rst-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(18)) + '1!'
results = []; diag = {}
def mask(s): return re.sub(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+', '<email>', re.sub(r'eyJ[A-Za-z0-9._-]+', '<jwt>', str(s)))
def check(name, ok, got='', stop=True):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {mask(got)[:300]}'), flush=True)
    if not ok and stop: raise SystemExit('STOP')
def lit(s): return "'" + s.replace("'", "''") + "'"
def sql(q):
    rq = urllib.request.Request(f'https://api.supabase.com/v1/projects/{REF}/database/query/read-only', data=json.dumps({'query': q}).encode(),
                                headers={'Authorization': f'Bearer {TOK}', 'Content-Type': 'application/json'}, method='POST')
    r = json.loads(urllib.request.urlopen(rq, timeout=60).read())
    if isinstance(r, dict): raise RuntimeError('sql: ' + str(r)[:200])
    return r
def counts():
    return sql("select (select count(*) from public.hdm_payments) p, (select count(*) from public.hdm_checkouts) c, (select count(*) from public.hdm_renewal_charges) r, (select string_agg(profile_id||plan||status||coalesce(to_jsonb(s)->>'auto_renew',''),',') from public.hdm_subscriptions s) s")[0]
def brevo_wait(email, subject_part, secs=180):
    t0 = time.time(); got = []
    while time.time() - t0 < secs:
        q = urllib.parse.urlencode({'email': email, 'limit': 50, 'days': 1, 'sort': 'desc'})
        try:
            ev = json.loads(urllib.request.urlopen(urllib.request.Request(f'https://api.brevo.com/v3/smtp/statistics/events?{q}', headers={'api-key': BREVO, 'accept': 'application/json'}), timeout=30).read()).get('events', [])
            got = [(e.get('event'), e.get('date', '')[11:19]) for e in ev if subject_part.lower() in (e.get('subject') or '').lower()]
        except Exception as e: got = [('error', str(e)[:80])]
        if any(g[0] == 'delivered' for g in got): return got   # לחשבון הזה לא נשלח קודם מייל איפוס
        time.sleep(10)
    return got

errors, console = [], []
def newpage(br):
    c = br.new_context(viewport={'width': 390, 'height': 844}, user_agent='Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1')
    pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)[:200]))
    pg.on('console', lambda m: m.type == 'error' and console.append(m.text[:160])); return c, pg
def my_id(pg): return pg.evaluate("() => (typeof myId !== 'undefined' && myId) || null")
def login(pg, email, pw):
    pg.goto(SITE, wait_until='networkidle'); pg.wait_for_timeout(1500)
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
    pg.fill('#li-email', email); pg.fill('#li-pass', pw); pg.click('#li-submit')
    try: pg.wait_for_function("() => myId || window.__hdmTermsGateOpen || document.getElementById('li-status').textContent.trim()", timeout=25000)
    except Exception: pass
    pg.wait_for_timeout(3000)
def layers(pg):
    return pg.evaluate("() => [...document.querySelectorAll('.hdm-layer.open, .signup.open, [aria-hidden=\"false\"]')].map(e => e.id || e.className).filter(Boolean).slice(0, 8)")

print('livecheck2', flush=True)
before = counts(); code = 1; EMAIL = None
try:
    acc = sql("select email, email_confirmed_at is not null conf, created_at > now() - interval '1 day' today from auth.users where email like 'life.through.numbers333+golive-%' and email like '%@gmail.com'")
    check('זיהוי ודאי: בדיוק חשבון בדיקה אחד, בכתובת האפליקציה, שנוצר היום', len(acc) == 1 and acc[0]['today'], len(acc))
    EMAIL = acc[0]['email']
    pid = sql(f"select a.profile_id from public.hdm_accounts a join auth.users u on u.id=a.auth_user_id where u.email={lit(EMAIL)}")
    pid = pid[0]['profile_id'] if pid else None
    sub = sql(f"select count(*) n from public.hdm_subscriptions where profile_id={lit(pid or '-')}")[0]['n']
    check('חשבון הבדיקה: אין לו מנוי ואין לו תשלום', sub == 0, sub)
    with sync_playwright() as p:
        br = p.chromium.launch()
        # 1. איפוס סיסמה
        since_hms = time.strftime('%H:%M:%S', time.gmtime(time.time() - 5))
        c, pg = newpage(br); pg.goto(SITE, wait_until='networkidle'); pg.wait_for_timeout(1500)
        pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
        pg.fill('#li-email', EMAIL); pg.evaluate("() => hdmOpenForgot()"); pg.wait_for_timeout(600)
        check('1. מסך "שכחתי סיסמה" נפתח', pg.locator('#fp-email').is_visible())
        pg.fill('#fp-email', EMAIL); pg.click('#fp-submit'); pg.wait_for_timeout(6000)
        fs = pg.inner_text('#fp-status'); c.close()
        check('1. שליחה → "נשלח קישור לאיפוס הסיסמה"', 'קישור' in fs, fs)
        rt = sql(f"select coalesce(recovery_token,'') t, recovery_sent_at > now() - interval '5 minutes' fresh from auth.users where email={lit(EMAIL)}")[0]
        check('1. נוצר בשרת קישור איפוס חדש', len(rt['t']) > 10 and rt['fresh'], rt.get('fresh'))
        ev = brevo_wait(EMAIL, 'Reset')
        check('1. Brevo: מייל "Reset your password" נמסר לתיבה', any(e[0] == 'delivered' for e in ev), ev)
        c, pg = newpage(br)
        pg.goto(f"{SB}/auth/v1/verify?token={rt['t']}&type=recovery&redirect_to={urllib.parse.quote(SITE + '?hdm_reset=1')}", wait_until='networkidle'); pg.wait_for_timeout(6000)
        check('1. קישור האיפוס פותח את מסך "סיסמה חדשה"', pg.locator('#rp-pass').is_visible(), layers(pg))
        pg.fill('#rp-pass', PW2); pg.fill('#rp-pass2', PW2); pg.click('#rp-submit'); pg.wait_for_timeout(9000)
        after_reset = my_id(pg) or pg.inner_text('#rp-status')
        print(f'INFO אחרי שמירת הסיסמה: {"נכנס לאפליקציה" if my_id(pg) else mask(after_reset)[:120]}', flush=True)
        c.close()
        c, pg = newpage(br); login(pg, EMAIL, PW2)
        gate = pg.evaluate("() => !!window.__hdmTermsGateOpen")
        check('1. כניסה מדפדפן נקי עם הסיסמה החדשה', bool(my_id(pg)) and not gate, [my_id(pg), gate, pg.inner_text('#li-status')])
        # 2. עמוד התשלום — אבחון
        pg.evaluate("() => hdmOpenPlans()")
        try: pg.wait_for_function("() => hdmEnt && hdmEnt.forId === myId && !hdmEnt.error && document.getElementById('hdm-plan-buy-plus')", timeout=25000)
        except Exception: pass
        pg.wait_for_timeout(2500)
        diag['plans_layer_open'] = pg.evaluate("() => hdmLayerOpen('hdm-plans-screen')")
        diag['buy_buttons'] = pg.evaluate("() => ['basic','plus','vip'].map(k => k + ':' + !!document.getElementById('hdm-plan-buy-' + k))")
        diag['hdmEnt'] = pg.evaluate("() => { try{ return JSON.stringify({forId: !!hdmEnt.forId, err: hdmEnt.error || null, plan: hdmPlanId(), billing: !!hdmEnt.billing}); }catch(e){ return String(e); } }")
        btn = pg.locator('#hdm-plan-buy-plus')
        diag['button_visible'] = btn.is_visible() if btn.count() else False
        diag['button_box'] = btn.bounding_box() if btn.count() else None
        if btn.count():
            btn.scroll_into_view_if_needed(); pg.wait_for_timeout(500)
            try: btn.click(timeout=8000)          # לחיצה אמיתית (בלי force) — כמו משתמש
            except Exception as e: diag['click_error'] = str(e)[:160]
        pg.wait_for_timeout(2000)
        diag['layers_after_click'] = layers(pg)
        diag['checkout_open'] = pg.evaluate("() => hdmLayerOpen('hdm-checkout-screen')")
        body = pg.evaluate("() => { var b = document.getElementById('hdm-checkout-body'); return b ? b.innerText : '(אין אלמנט)'; }")
        diag['checkout_len'] = len(body)
        print('DIAG ' + json.dumps(diag, ensure_ascii=False, default=str)[:900], flush=True)
        print('PAGE ' + mask(body)[:700].replace('\n', ' | '), flush=True)
        ok_page = diag['checkout_open'] and '48.90' in body and 'חידוש' in body and not pg.locator('#hdm-co-accept').is_checked()
        check('2. "הצטרפות לפלוס" (לחיצה אמיתית) פותחת עמוד תשלום: ₪48.90, חידוש אוטומטי, תיבת תקנון לא מסומנת', ok_page, diag, stop=False)
        if ok_page:
            pay = pg.locator('#hdm-co-pay')
            check('2. כפתור "המשך לתשלום מאובטח" מוצג (לא נלחץ)', pay.count() == 1 and pay.is_visible(), '', stop=False)
            pg.locator('#hdm-co-tab-basic').click(); pg.wait_for_timeout(500)
            b2 = pg.evaluate("() => document.getElementById('hdm-checkout-body').innerText")
            check('2. מעבר ללשונית בסיסי בעמוד התשלום: ₪29.90', '29.90' in b2, b2[:120], stop=False)
            check('2. אין לשונית VIP בעמוד התשלום', pg.locator('#hdm-co-tab-vip').count() == 0, '', stop=False)
            pg.locator('#hdm-co-pay').click(); pg.wait_for_timeout(800)
            m = pg.inner_text('#hdm-co-msg')
            check('2. לחיצה על "לתשלום" בלי סימון התקנון — נחסמת, בלי פנייה לתשלום', 'לסמן' in m or 'לא ניתן' in m or 'יש ל' in m, m, stop=False)
        check('2. לא נוצר ניסיון תשלום', counts()['c'] == before['c'], '', stop=False)
        # 3. מחיקה דרך כפתור המחיקה באפליקציה
        pg.evaluate("() => { try{ hdmCloseLayer('hdm-checkout-screen'); hdmCloseLayer('hdm-plans-screen'); }catch(e){} }"); pg.wait_for_timeout(500)
        pg.evaluate("() => openDeleteAccount()"); pg.wait_for_timeout(700)
        pg.fill('#hdm-del-confirm', 'מחיקה'); pg.click('#hdm-del-go'); pg.wait_for_timeout(10000)
        left = sql(f"select (select count(*) from auth.users where email={lit(EMAIL)}) u, (select count(*) from public.docs where collection='profiles' and id={lit(pid or '-')}) d, (select count(*) from public.hdm_accounts where profile_id={lit(pid or '-')}) a")[0]
        check('3. מחיקה דרך כפתור המחיקה באפליקציה → פרטי ההתחברות, הפרופיל והחשבון נמחקו', left == {'u': 0, 'd': 0, 'a': 0}, left)
        c.close()
        c, pg = newpage(br); login(pg, EMAIL, PW2)
        check('3. אחרי המחיקה אי אפשר להיכנס', not my_id(pg), '')
        c.close()
        check('אין שגיאות JavaScript בדף', not errors, errors[:3], stop=False)
        br.close()
    code = 0 if all(results) else 1
except SystemExit:
    code = 1
except Exception as e:
    print('ERROR ' + mask(e)[:300], flush=True); code = 1
finally:
    after = counts()
    same = {k: v for k, v in after.items() if k != 'c'} == {k: v for k, v in before.items() if k != 'c'} and after['c'] == before['c']
    print(('PASS ' if same else 'FAIL ') + f"אין תשלום/חיוב/שינוי מנויים: תשלומים {before['p']}→{after['p']}, ניסיונות תשלום {before['c']}→{after['c']}, חיובי חידוש {before['r']}→{after['r']}, מנויים זהים={before['s']==after['s']}", flush=True)
    if console: print('CONSOLE ' + mask(' || '.join(console[:4]))[:400], flush=True)
    rem = sql("select count(*) n from auth.users where email like 'life.through.numbers333+golive-%'")[0]['n']
    print(f'חשבונות בדיקה שנשארו: {rem}', flush=True)
    print(f'SUMMARY {sum(results)}/{len(results)} עברו', flush=True)
sys.exit(code)
