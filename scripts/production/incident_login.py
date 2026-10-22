#!/usr/bin/env python3
# כניסה אמיתית לאתר החי עם משתמש בדיקה מאושר (נוצר לפני כן). אוסף שגיאות קונסול/רשת ומה מוצג אחרי הכניסה. לא כותב נתונים מעבר למה שהאפליקציה עושה בכניסה.
import json, os, re, sys
from playwright.sync_api import sync_playwright
SITE = os.environ.get('SITE', 'https://shmulikhavivi-design.github.io/haim-derech-misparim/')
EM, PW = os.environ['T_EM'], os.environ['T_PW']
clean = lambda s: re.sub(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<email>', re.sub(r'eyJ[A-Za-z0-9._-]+', '<jwt>', str(s)))[:400]
res = {'console': [], 'pageerr': [], 'bad_requests': [], 'steps': []}
with sync_playwright() as p:
    b = p.chromium.launch(); pg = b.new_page(viewport={'width': 390, 'height': 844})
    pg.on('console', lambda m: m.type in ('error', 'warning') and res['console'].append(clean(m.type + ': ' + m.text)))
    pg.on('pageerror', lambda e: res['pageerr'].append(clean(e)))
    def onresp(r):
        if r.status >= 400 and ('supabase' in r.url or 'github.io' in r.url or 'pages.dev' in r.url):
            body = ''
            try: body = r.text()[:200]
            except Exception: pass
            res['bad_requests'].append(clean(f"{r.status} {r.request.method} {r.url.split('?')[0]} {body}"))
    pg.on('response', onresp)
    pg.on('requestfailed', lambda r: res['bad_requests'].append(clean(f"FAILED {r.method} {r.url.split('?')[0]} {r.failure}")))
    pg.goto(SITE, wait_until='networkidle', timeout=60000); pg.wait_for_timeout(2000)
    res['steps'].append('נטען: ' + clean(pg.title()))
    try:
        if pg.locator('#intro-screen').is_visible():
            btn = pg.locator('#intro-screen button, #intro-screen .intro-btn').first
            btn.click() if btn.count() else pg.evaluate('startFromIntro()')
            pg.wait_for_timeout(800)
    except Exception as e: res['steps'].append('intro: ' + clean(e))
    try:
        if not pg.locator('#li-email').is_visible():
            for sel in ['text=כניסה', 'text=התחברות', '#show-login', '[onclick*="Login"]']:
                if pg.locator(sel).count() and pg.locator(sel).first.is_visible(): pg.locator(sel).first.click(); pg.wait_for_timeout(600); break
        pg.fill('#li-email', EM); pg.fill('#li-pass', PW); pg.click('#li-submit')
        res['steps'].append('נשלחה כניסה')
    except Exception as e: res['steps'].append('טופס הכניסה: ' + clean(e))
    pg.wait_for_timeout(9000)
    vis = pg.evaluate("""() => [...document.querySelectorAll('body *')].filter(e => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e);
        return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none' && e.id; }).map(e => e.id).slice(0, 60)""")
    res['visible_ids'] = vis
    res['logged_in'] = pg.evaluate("() => !!(window.__sb && true)") and pg.evaluate("async () => { try { const s = await window.__sb.auth.getSession(); return !!(s && s.data && s.data.session); } catch(e) { return 'err:' + e.message } }")
    txt = pg.evaluate("() => document.body.innerText")
    res['screen_text'] = clean(re.sub(r'\s+', ' ', txt))[:400]
    errs = [t for t in re.findall(r'[^.\n]*(?:שגיאה|נכשל|לא הצלחנו|Error|error)[^.\n]*', txt)][:5]
    res['error_texts'] = [clean(e) for e in errs]
    pg.screenshot(path=os.environ.get('SHOT', '/tmp/login.png'))
    b.close()
print(json.dumps(res, ensure_ascii=False))
