# =====================================================================
# חיים דרך מספרים — בדיקת דפדפן: "הצטרפות למנוי" מול "ניהול מנוי"
#   בלי מנוי פעיל: "💎 הצטרפות למנוי", שלושת המסלולים בראש המסך, בלי כפתור "ביטול מנוי" במסך המנויים
#   עם מנוי פעיל: "💎 ניהול מנוי", שדרוג למסלול גבוה יותר וביטול
#   כל כפתור הצטרפות/שדרוג ← עמוד התשלום של אותו מסלול, עם התקנון ותיבת האישור
# רצה על הקובץ המקומי. מצב המנוי מדומה בדף; כל בקשה ל-Supabase ול-Grow נחסמת — אין מסד, אין חיוב.
#   python3 scripts/staging_e2e/e2e_join_entry.py [index.html|staging.html]
# =====================================================================
import functools, http.server, sys, threading, pathlib
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[2]
PAGE = sys.argv[1] if len(sys.argv) > 1 else 'index.html'
NAMES = {'basic': 'בסיסי', 'plus': 'פלוס', 'vip': 'VIP'}
PRICES = {'basic': '₪29.90', 'plus': '₪48.90', 'vip': '₪79.90'}
LABELS = ['#hdm-plans-link', '#set-plans-label', '#profile-manage-sub']

results = []
def check(name, ok, got=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {str(got)[:200]}'), flush=True)

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(ROOT))
handler.log_message = lambda *a: None
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f'http://127.0.0.1:{srv.server_address[1]}/{PAGE}'
leaks = []

def as_user(pg, plan):
    """מצב מדומה: משתמש מחובר עם מסלול plan (None = לא מחובר). בלי פנייה לשרת."""
    pg.evaluate("""(plan) => {
      window.hdmRefreshPlan = () => Promise.resolve();
      if(plan === null){ myId = null; hdmEnt = null; }
      else { myId = 'test_user'; hdmEnt = { forId: 'test_user', installed: true, plan: plan, source: plan === 'free' ? 'default' : 'manual' }; }
      hdmApplyPlanUI(); hdmApplyPlansLabels();
    }""", plan)

def labels(pg): return [pg.inner_text(s).strip() for s in LABELS]

def open_plans(pg):
    pg.evaluate("() => { hdmCloseCheckout(); hdmCloseLayer('hdm-plans-screen'); hdmOpenPlans(); }"); pg.wait_for_timeout(150)

def buy_leads_to_checkout(pg, k, tag):
    pg.locator(f'#hdm-plan-buy-{k}').click(); pg.wait_for_timeout(150)
    top = pg.evaluate("() => { const r = document.querySelector('#hdm-checkout-screen').getBoundingClientRect(); const el = document.elementFromPoint(r.left + r.width/2, r.top + 120); return !!(el && el.closest('#hdm-checkout-screen')); }")
    check(f'{tag}: "{NAMES[k]}" — עמוד התשלום נראה מעל הכול (לא מוסתר)', top)
    ok = ('open' in (pg.get_attribute('#hdm-checkout-screen', 'class') or '') and pg.inner_text('#hdm-co-plan') == NAMES[k]
          and PRICES[k] in pg.inner_text('#hdm-co-price') and not pg.locator('#hdm-co-accept').is_checked()
          and pg.locator('#hdm-co-check-box a').count() == 3 and pg.locator('#hdm-co-links a').count() == 4)
    check(f'{tag}: "{NAMES[k]}" ← עמוד התשלום של {NAMES[k]}, עם תקנון ותיבת אישור לא מסומנת', ok, pg.inner_text('#hdm-co-plan'))
    pg.locator('#hdm-co-pay').scroll_into_view_if_needed(); pg.click('#hdm-co-pay', force=True); pg.wait_for_timeout(150)
    check(f'{tag}: "{NAMES[k]}" — בלי אישור התקנון אין המשך', 'לא ניתן להמשיך' in pg.inner_text('#hdm-co-msg'))
    pg.evaluate('hdmCloseCheckout()'); pg.wait_for_timeout(100)
    check(f'{tag}: "חזרה" מעמוד התשלום מחזיר למסך המנויים', 'open' in (pg.get_attribute('#hdm-plans-screen', 'class') or ''))

with sync_playwright() as p:
    for label, opts in (('iPhone', p.devices['iPhone 13']), ('Desktop', {'viewport': {'width': 1280, 'height': 900}})):
        opts = {k: v for k, v in opts.items() if k != 'default_browser_type'}
        b = p.chromium.launch(); ctx = b.new_context(**opts, locale='he-IL', timezone_id='Asia/Jerusalem')
        def guard(route):
            u = route.request.url
            if 'supabase.co' in u or 'grow' in u.lower():
                leaks.append(u); return route.abort()
            return route.continue_()
        ctx.route('**/*', guard)
        pg = ctx.new_page(); errors = []
        pg.on('pageerror', lambda e: errors.append(str(e)))
        pg.goto(BASE); pg.wait_for_timeout(800)
        L = f'[{label}]'

        # ברירת מחדל (לפני שהמסלול נטען): הצטרפות
        check(f'{L} ברירת מחדל: "💎 הצטרפות למנוי" בשלושת המקומות', all(t == '💎 הצטרפות למנוי' for t in labels(pg)), labels(pg))

        for state, tag in ((None, 'לא מחובר'), ('free', 'חינם')):
            as_user(pg, state); T = f'{L} {tag}'
            check(f'{T}: הכפתור נקרא "💎 הצטרפות למנוי" (מסך ראשי, הגדרות, פרופיל)', all(t == '💎 הצטרפות למנוי' for t in labels(pg)), labels(pg))
            open_plans(pg)
            check(f'{T}: כותרת המסך "הצטרפות למנוי"', pg.inner_text('#hdm-plans-title').strip() == 'הצטרפות למנוי')
            order = pg.evaluate("() => [...document.querySelectorAll('#hdm-plans-body .hdm-plan')].map(e => e.id)")
            check(f'{T}: בראש המסך בסיסי, פלוס ו-VIP (ואחריהם חינם)', order[:3] == ['hdm-plan-card-basic', 'hdm-plan-card-plus', 'hdm-plan-card-vip'], order)
            first = pg.evaluate("() => { const b = document.getElementById('hdm-plans-body').firstElementChild; return b && (b.id || b.className); }")
            check(f'{T}: שום תיבה לא מופיעה לפני המסלולים (מלבד שורת הסבר)', first in ('hdm-note',), first)
            for k in NAMES:
                t = pg.inner_text(f'#hdm-plan-buy-{k}') if pg.locator(f'#hdm-plan-buy-{k}').count() else ''
                check(f'{T}: כפתור "הצטרפות — {PRICES[k]} לחודש" ב{NAMES[k]}', t.startswith('הצטרפות') and PRICES[k] in t, t)
            check(f'{T}: אין כפתור "ביטול מנוי" במסך המנויים', pg.locator('#hdm-bill-cancel').count() == 0 and pg.locator('#hdm-manage-box').count() == 0)
            for k in NAMES: open_plans(pg); buy_leads_to_checkout(pg, k, T)
            if label == 'iPhone':
                open_plans(pg)
                vis = pg.evaluate("() => { const b = document.getElementById('hdm-plan-buy-basic').getBoundingClientRect(); return b.top < innerHeight && b.height >= 44; }")
                check(f'{T}: כפתור ההצטרפות הראשון נראה במסך בלי לגלול, בגובה 44px לפחות', vis)
        # חינם שהגיע מכפתור "ביטול מנוי" בפרופיל: ההסבר שאין מנוי לבטל (דרישת Grow — הכפתור בפרופיל נשאר ועובד)
        as_user(pg, 'free')
        pg.evaluate("() => { hdmCloseLayer('hdm-plans-screen'); hdmCancelEntry(); }"); pg.wait_for_timeout(150)
        t = pg.inner_text('#hdm-plans-body')
        check(f'{L} חינם: "ביטול מנוי" מהפרופיל עדיין עובד ומסביר שאין מנוי בתשלום', 'אין לך מנוי בתשלום' in t and pg.locator('#hdm-cancel-confirm').count() == 1, t[:200])
        check(f'{L} חינם: כפתור "ביטול מנוי" בפרופיל נשאר', pg.locator('#profile-cancel-sub').count() == 1)
        pg.evaluate("() => hdmCloseCancelInfo()")
        check(f'{L} חינם: אחרי "חזרה" אין כפתור ביטול במסך', pg.locator('#hdm-bill-cancel').count() == 0)

        # מנוי פעיל
        for plan in NAMES:
            as_user(pg, plan); T = f'{L} מנוי {NAMES[plan]}'
            check(f'{T}: הכפתור נקרא "💎 ניהול מנוי"', all(t == '💎 ניהול מנוי' for t in labels(pg)), labels(pg))
            open_plans(pg)
            check(f'{T}: כותרת "ניהול מנוי" ומצב המנוי בראש המסך', pg.inner_text('#hdm-plans-title').strip() == 'ניהול מנוי'
                  and NAMES[plan] in pg.inner_text('#hdm-plans-status'))
            higher = [k for k in NAMES if list(NAMES).index(k) > list(NAMES).index(plan)]
            got = [k for k in NAMES if pg.locator(f'#hdm-plan-buy-{k}').count()]
            check(f'{T}: אפשרויות שדרוג רק למסלול גבוה יותר {higher}', got == higher, got)
            for k in higher:
                check(f'{T}: כפתור "שדרוג ל־{NAMES[k]}"', pg.inner_text(f'#hdm-plan-buy-{k}').startswith('שדרוג ל־' + NAMES[k]))
                buy_leads_to_checkout(pg, k, T); open_plans(pg)
            check(f'{T}: כפתור "ביטול מנוי" מוצג', pg.locator('#hdm-bill-cancel').count() == 1)
            pg.locator('#hdm-bill-cancel').click(); pg.wait_for_timeout(100)
            check(f'{T}: "ביטול מנוי" פותח את שלב האישור', pg.locator('#hdm-cancel-confirm').count() == 1)
        check(f'{L} אין שגיאות JavaScript', not [e for e in errors if 'supabase' not in e.lower()], errors)
        b.close()
    check('אף בקשה לא יצאה ל-Grow', not [u for u in leaks if 'supabase.co' not in u], leaks)
srv.shutdown()
print(f'\n{sum(results)}/{len(results)} עברו')
sys.exit(0 if all(results) else 1)
