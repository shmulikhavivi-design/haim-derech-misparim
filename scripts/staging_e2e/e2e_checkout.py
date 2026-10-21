# =====================================================================
# חיים דרך מספרים — בדיקת דפדפן: עמוד התשלום (דרישות Grow)
#   1. אישור תקנון חובה (לא מסומן מראש, בלי אישור אין המשך)  2. קישורים לתקנון  3. עמוד תשלום תקין
# רצה על הקובץ המקומי בלבד. כל בקשה ל-Supabase ול-Grow נחסמת — אין גישה למסד, אין חיוב ואין שינוי ב-Production.
#   python3 scripts/staging_e2e/e2e_checkout.py [index.html|staging.html]
# =====================================================================
import functools, http.server, sys, threading, pathlib, re
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[2]
PAGE = sys.argv[1] if len(sys.argv) > 1 else 'index.html'
PLANS = {'basic': ('בסיסי', '₪29.90'), 'plus': ('פלוס', '₪48.90'), 'vip': ('VIP', '₪79.90')}
DOCS = {'terms': 'תנאי שימוש', 'cancel': 'מדיניות ביטול מנוי', 'privacy': 'מדיניות פרטיות', 'business': 'מחירים, אספקת השירות ופרטי העסק'}

results = []
def check(name, ok, got=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {str(got)[:200]}'), flush=True)

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(ROOT))
handler.log_message = lambda *a: None
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f'http://127.0.0.1:{srv.server_address[1]}/{PAGE}'

blocked = []
def guard(route):
    u = route.request.url
    if 'supabase.co' in u or 'grow' in u.lower() or 'meshulam' in u.lower():
        blocked.append(u); return route.abort()
    return route.continue_()

with sync_playwright() as p:
    for label, opts in (('iPhone', p.devices['iPhone 13']), ('Desktop', {'viewport': {'width': 1280, 'height': 900}})):
        if 'default_browser_type' in opts: opts = {k: v for k, v in opts.items() if k != 'default_browser_type'}
        b = p.chromium.launch(); ctx = b.new_context(**opts, locale='he-IL', timezone_id='Asia/Jerusalem')
        ctx.route('**/*', guard)
        pg = ctx.new_page(); errors = []
        pg.on('pageerror', lambda e: errors.append(str(e)))
        print(f'--- {label} ---')
        for plan, (name, price) in PLANS.items():
            pg.goto(f'{BASE}#checkout-{plan}'); pg.wait_for_timeout(700)
            scr = pg.locator('#hdm-checkout-screen')
            check(f'[{label}/{plan}] עמוד התשלום נפתח מקישור ישיר בלי חשבון', 'open' in (scr.get_attribute('class') or ''))
            check(f'[{label}/{plan}] שם המסלול והמחיר', pg.inner_text('#hdm-co-plan') == name and price in pg.inner_text('#hdm-co-price'), pg.inner_text('#hdm-co-summary'))
            summ = pg.inner_text('#hdm-co-summary')
            check(f'[{label}/{plan}] פרטי המנוי: סוג, חיוב ראשון, חיוב הבא, מע"מ, מה כלול',
                  all(t in summ for t in ('מנוי חודשי מתחדש אוטומטית', 'חיוב ראשון', 'חיוב הבא', 'כולל מע"מ', 'מה כלול')), summ)
            ren = pg.inner_text('#hdm-co-renewal')
            check(f'[{label}/{plan}] חידוש אוטומטי ותנאי ביטול', all(t in ren for t in ('מתחדש אוטומטית', price, 'לבטל בכל עת', 'ביטול מנוי', 'עד סוף התקופה', 'חוק הגנת הצרכן')), ren)
            mer = pg.inner_text('#hdm-co-merchant')
            check(f'[{label}/{plan}] פרטי העסק ואמצעי תשלום', all(t in mer for t in ('Grow', '038364659', 'אורן 3, קיסריה', '054-6628866', '18')), mer)
            cb = pg.locator('#hdm-co-accept')
            check(f'[{label}/{plan}] תיבת אישור התקנון קיימת, חובה ולא מסומנת', cb.count() == 1 and not cb.is_checked() and cb.get_attribute('required') is not None)
            lab = pg.inner_text('#hdm-co-check-box')
            check(f'[{label}/{plan}] נוסח האישור כולל תקנון, ביטול, פרטיות, סכום וחידוש', all(t in lab for t in ('תקנון', 'מדיניות ביטול מנוי', 'מדיניות הפרטיות', price, 'חידוש אוטומטי')), lab)
            url0 = pg.url
            pg.click('#hdm-co-pay', force=True); pg.wait_for_timeout(200)   # הקשה על הכפתור כשהוא מסומן כלא פעיל
            check(f'[{label}/{plan}] בלי אישור — אין המשך לתשלום והודעת שגיאה', pg.url == url0 and 'לא ניתן להמשיך' in pg.inner_text('#hdm-co-msg')
                  and 'is-error' in (pg.get_attribute('#hdm-co-check-box', 'class') or ''), pg.inner_text('#hdm-co-msg'))
            pg.click('#hdm-co-accept'); pg.wait_for_timeout(150)
            check(f'[{label}/{plan}] אחרי סימון — כפתור התשלום פעיל', pg.get_attribute('#hdm-co-pay', 'aria-disabled') == 'false')
            pg.click('#hdm-co-pay'); pg.wait_for_timeout(200)
            check(f'[{label}/{plan}] סליקה כבויה — אין מעבר ואין חיוב', pg.url == url0 and 'לא בוצע ולא יבוצע שום חיוב' in pg.inner_text('#hdm-co-msg'), pg.inner_text('#hdm-co-msg'))
        # קישורי התקנון נפתחים מעל עמוד התשלום, ו"חזרה" מחזיר אליו
        for kind, title in DOCS.items():
            pg.locator('#hdm-co-links a', has_text=re.compile({'terms': 'תקנון', 'cancel': 'ביטול', 'privacy': 'פרטיות', 'business': 'העסק'}[kind])).click(); pg.wait_for_timeout(200)
            top = pg.evaluate("() => { const r = document.querySelector('#hdm-checkout-screen').getBoundingClientRect(); const el = document.elementFromPoint(r.left + r.width/2, r.top + 200); return !!(el && el.closest('#legal-screen')); }")
            check(f'[{label}] קישור "{title}" פותח את המסמך מעל עמוד התשלום', pg.inner_text('#legal-title') == title and top, pg.inner_text('#legal-title'))
            pg.evaluate('closeLegal()'); pg.wait_for_timeout(100)
            check(f'[{label}] סגירת "{title}" מחזירה לעמוד התשלום', 'open' in (pg.get_attribute('#hdm-checkout-screen', 'class') or ''))
        # קישורי תקנון גם בתוך תיבת האישור
        n = pg.locator('#hdm-co-check-box a').count()
        check(f'[{label}] בתיבת האישור יש קישורים לתקנון, למדיניות הביטול ולפרטיות', n == 3, n)
        # החלפת מסלול בעמוד מעדכנת מחיר ומאפסת? — הסימון נשמר רק לאותו ביקור; פתיחה מחדש מתחילה בלי סימון
        pg.click('#hdm-co-tab-vip'); pg.wait_for_timeout(100)
        check(f'[{label}] בחירת מסלול בעמוד מעדכנת מחיר', '₪79.90' in pg.inner_text('#hdm-co-price'))
        pg.evaluate("hdmOpenCheckout('basic')"); pg.wait_for_timeout(100)
        check(f'[{label}] פתיחה מחדש — התיבה לא מסומנת', not pg.locator('#hdm-co-accept').is_checked())
        # מסך המסלולים: כפתורי הצטרפות למסלולים בתשלום פותחים את עמוד התשלום
        pg.evaluate("hdmCloseCheckout(); hdmRenderPlans(); hdmOpenLayer('hdm-plans-screen')"); pg.wait_for_timeout(100)
        for plan, (name, price) in PLANS.items():
            btn = pg.locator(f'#hdm-plan-buy-{plan}')
            ok = btn.count() == 1 and price in btn.inner_text()
            if ok:
                btn.click(); pg.wait_for_timeout(150)
                ok = pg.inner_text('#hdm-co-plan') == name and pg.evaluate("() => { const r = document.querySelector('#hdm-checkout-screen').getBoundingClientRect(); const el = document.elementFromPoint(r.left + r.width/2, r.top + 120); return !!(el && el.closest('#hdm-checkout-screen')); }")
                pg.evaluate('hdmCloseCheckout()'); ok = ok and 'open' in (pg.get_attribute('#hdm-plans-screen', 'class') or '')
            check(f'[{label}] מסך המסלולים: "{name}" ← עמוד התשלום', ok)
        check(f'[{label}] אין כפתור "בקרוב" במסלולים בתשלום', 'בקרוב' not in pg.inner_text('#hdm-plans-body'))
        pg.evaluate("hdmCloseLayer('hdm-plans-screen'); hdmOpenCheckout('plus')"); pg.wait_for_timeout(100)
        if label == 'iPhone':
            ov = pg.evaluate("() => { const s = document.querySelector('#hdm-checkout-screen'); return s.scrollWidth - s.clientWidth; }")
            check('[iPhone] בלי גלילה אופקית', ov <= 1, ov)
            small = pg.evaluate("() => [...document.querySelectorAll('#hdm-co-pay, .hdm-co-tabs button, #hdm-checkout-screen .signup-back')].filter(e => e.getBoundingClientRect().height < 44).map(e => e.id || e.className + ':' + Math.round(e.getBoundingClientRect().height))")
            check('[iPhone] כפתורים בגובה מגע 44px לפחות', not small, small)
            pg.locator('#hdm-co-links').scroll_into_view_if_needed()
            check('[iPhone] העמוד נגלל עד הקישורים בתחתית', pg.locator('#hdm-co-links').is_visible())
        # תאריך החיוב הבא
        nx = pg.evaluate("() => [[2027,0,31],[2028,0,31],[2026,11,15],[2026,9,19]].map(a => { const d = hdmCoNextCharge(new Date(a[0],a[1],a[2])); return [d.getFullYear(), d.getMonth()+1, d.getDate()].join('-'); })")
        check(f'[{label}] חיוב הבא: אותו יום בחודש הבא / סוף חודש', nx == ['2027-2-28', '2028-2-29', '2027-1-15', '2026-11-19'], nx)
        check(f'[{label}] אין שגיאות JavaScript בעמוד התשלום', not [e for e in errors if 'supabase' not in e.lower()], errors)
        b.close()
    check('אף בקשה לא יצאה ל-Grow (רק Supabase נחסם)', not [u for u in blocked if 'supabase.co' not in u], blocked)
srv.shutdown()
print(f'\n{sum(results)}/{len(results)} עברו')
sys.exit(0 if all(results) else 1)
