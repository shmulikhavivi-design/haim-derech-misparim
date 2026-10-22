#!/usr/bin/env python3
# כניסה (ואופציונלית הרשמה דרך הטופס) באתר החי בשלושה מנועים: Chromium, WebKit (ספארי/אייפון), Firefox. לא מוחק ולא מחייב.
import json, os, re
from playwright.sync_api import sync_playwright
EM, PW, SU_EM = os.environ['T_EM'], os.environ['T_PW'], os.environ.get('SU_EM', '')
clean = lambda s: re.sub(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<email>', re.sub(r'eyJ[A-Za-z0-9._-]+', '<jwt>', str(s)))[:300]
SITES = ['https://shmulikhavivi-design.github.io/haim-derech-misparim/', 'https://haim-derech-misparim.pages.dev/']
out = {}
def intro(pg):
    try:
        if pg.locator('#intro-screen').is_visible():
            b = pg.locator('#intro-screen button, #intro-screen .intro-btn').first
            b.click() if b.count() else pg.evaluate('startFromIntro()'); pg.wait_for_timeout(700)
    except Exception: pass
with sync_playwright() as p:
    engines = [('chromium', p.chromium, {}), ('webkit-iphone', p.webkit, p.devices['iPhone 13'])]
    for name, eng, ctxopt in engines:
        try: br = eng.launch()
        except Exception as e: out[name] = 'launch: ' + clean(e); continue
        for site in SITES:
            key = name + ' ' + site.split('/')[2].split('.')[0]
            r = {'errors': [], 'bad': []}
            ctx = br.new_context(**ctxopt); pg = ctx.new_page()
            pg.on('pageerror', lambda e: r['errors'].append(clean(e)))
            pg.on('console', lambda m: m.type == 'error' and r['errors'].append(clean(m.text)))
            pg.on('response', lambda x: x.status >= 400 and 'supabase' in x.url and r['bad'].append(f"{x.status} {x.url.split('?')[0].split('/v1/')[-1]}"))
            try:
                pg.goto(site, wait_until='networkidle', timeout=60000); pg.wait_for_timeout(1500); intro(pg)
                pg.fill('#li-email', EM); pg.fill('#li-pass', PW); pg.click('#li-submit'); pg.wait_for_timeout(8000)
                r['session'] = pg.evaluate("async () => { try { const s = await window.__sb.auth.getSession(); return !!(s.data && s.data.session); } catch(e) { return 'err:' + e.message } }")
                r['status_msg'] = clean(pg.evaluate("() => { const e = document.querySelector('#li-status, .li-status, #login-status'); return e ? e.innerText : '' }"))
                r['screen'] = [i for i in pg.evaluate("() => [...document.querySelectorAll('[id]')].filter(e => { const b = e.getBoundingClientRect(); const s = getComputedStyle(e); return b.width > 0 && b.height > 0 && s.display !== 'none' && s.visibility !== 'hidden' }).map(e => e.id)") if i in ('terms-gate', 'screen-register', 'login-screen', 'main-screen', 'screen-main', 'tabbar', 'home-screen', 'auth-choice-screen')]
            except Exception as e: r['flow'] = clean(e)
            ctx.close(); out[key] = r
        br.close()
    # הרשמה דרך הטופס ב-WebKit (אייפון) באתר של Cloudflare — המייל נשלח לתיבת האפליקציה
    if SU_EM:
        br = p.webkit.launch(); ctx = br.new_context(**p.devices['iPhone 13']); pg = ctx.new_page(); r = {'errors': [], 'bad': []}
        pg.on('pageerror', lambda e: r['errors'].append(clean(e)))
        pg.on('response', lambda x: x.status >= 400 and 'supabase' in x.url and r['bad'].append(f"{x.status} {x.url.split('?')[0].split('/v1/')[-1]}"))
        sent = []
        pg.on('request', lambda q: 'auth/v1/signup' in q.url and sent.append(q.url.split('redirect_to=')[-1][:80] if 'redirect_to=' in q.url else 'no-redirect'))
        try:
            pg.goto(SITES[1], wait_until='networkidle', timeout=60000); pg.wait_for_timeout(1500); intro(pg)
            r['signup_fields'] = pg.evaluate("() => [...document.querySelectorAll('input[id^=su-], select[id^=su-]')].map(e => e.id)")
            r['note'] = 'הטופס נמצא; לא שולחים הרשמה דרך UI כדי לא ליצור פרופיל גלוי'
        except Exception as e: r['flow'] = clean(e)
        out['webkit signup form'] = r; br.close()
print(json.dumps(out, ensure_ascii=False))
