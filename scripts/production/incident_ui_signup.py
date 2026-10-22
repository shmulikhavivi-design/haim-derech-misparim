#!/usr/bin/env python3
# הרשמה מלאה דרך הטופס האמיתי באתר החי (3 שלבים, כולל תמונה), Chrome + ספארי/אייפון, שתי הכתובות. המייל לתיבת האפליקציה (+incui…).
# לא מאשרים את המייל ולכן לא נוצר פרופיל גלוי. מתעד את בקשת ההרשמה לשרת, התשובה, וההודעה שהמשתמש רואה.
import json, os, re, base64
from playwright.sync_api import sync_playwright
T = os.environ.get('T', 'x')
clean = lambda s: re.sub(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<email>', re.sub(r'eyJ[A-Za-z0-9._-]+', '<jwt>', str(s)))[:350]
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAVklEQVR4nO3PQQ0AIBDAsIN/z2CCB0nZrSs0M2tm1nIu8MAAAAAAAAAAAAD/AwAAAAAAAPg3AAAAAAAAAH4FAAAAAAAAAB4AAAAAAAAAAAAAAAD8C4w/ASBzA3EPAAAAAElFTkSuQmCC')
open('/tmp/p.png', 'wb').write(PNG)
SITES = ['https://shmulikhavivi-design.github.io/haim-derech-misparim/', 'https://haim-derech-misparim.pages.dev/']
out = {}
def vis_errors(pg):
    return pg.evaluate("""() => [...document.querySelectorAll('.su-err, .su-field.bad, .bad .su-err, [id$=-status]')].filter(e => e.offsetParent && e.innerText.trim()).map(e => (e.id||'') + ':' + e.innerText.trim()).slice(0, 6)""")
with sync_playwright() as p:
    for ename, eng, opt in [('chrome', p.chromium, {'viewport': {'width': 390, 'height': 844}}), ('iphone', p.chromium, {k: v for k, v in p.devices['iPhone 13'].items() if k != 'default_browser_type'})]:
        br = eng.launch()
        for site in SITES:
            tag = ename + '-' + ('gh' if 'github' in site else 'cf')
            em = f"life.through.numbers333+incui{tag.replace('-', '')}{T}@gmail.com"
            r = {'steps': [], 'errors': [], 'net': []}
            ctx = br.new_context(**opt); pg = ctx.new_page()
            pg.on('pageerror', lambda e: r['errors'].append(clean(e)))
            pg.on('console', lambda m: m.type == 'error' and r['errors'].append(clean(m.text)))
            def onresp(x):
                if 'auth/v1' in x.url or (x.status >= 400 and 'supabase' in x.url):
                    b = ''
                    try: b = x.text()[:160]
                    except Exception: pass
                    r['net'].append(clean(f"{x.status} {x.request.method} {x.url.split('?')[0].split('/v1/')[-1]} {'redirect_to=' + x.url.split('redirect_to=')[1][:60] if 'redirect_to=' in x.url else ''} {b}"))
            pg.on('response', onresp)
            try:
                pg.goto(site, wait_until='networkidle', timeout=60000); pg.wait_for_timeout(1500)
                pg.evaluate("() => { try { document.getElementById('intro-screen') && (document.getElementById('intro-screen').style.display='none'); } catch(e){} ; openSignup(); }"); pg.wait_for_timeout(800)
                pg.fill('#su-name', 'בדיקת מערכת'); pg.fill('#su-birth', '1990-05-17') if pg.get_attribute('#su-birth', 'type') == 'date' else pg.fill('#su-birth', '17/05/1990')
                pg.select_option('#su-gender', 'אישה'); pg.fill('#su-city', 'תל אביב'); pg.fill('#su-email', em); pg.fill('#su-pass', 'Test-' + T[-6:] + '-Aa1!x')
                pg.check('#su-consent', force=True); pg.evaluate('submitSignup()'); pg.wait_for_timeout(1200)
                r['steps'].append('שלב 1: ' + ('עבר' if pg.locator('#signup-step2').get_attribute('aria-hidden') == 'false' else 'נעצר ' + clean(vis_errors(pg))))
                pg.set_input_files('#su2-photo-input', '/tmp/p.png'); pg.wait_for_timeout(800)
                for sel in pg.evaluate("() => [...document.querySelectorAll('#signup-step2 select')].map(s => s.id)"):
                    v = pg.evaluate("(id) => { const o = [...document.getElementById(id).options].find(o => o.value); return o ? o.value : '' }", sel)
                    if v: pg.select_option('#' + sel, v)
                for iid, val in [('su2-height', '165'), ('su2-agemin', '30'), ('su2-agemax', '45'), ('su2-childcount', '0'), ('su2-bio', 'בדיקה')]:
                    try:
                        if pg.locator('#' + iid).count() and pg.locator('#' + iid).is_visible() and pg.locator('#' + iid).evaluate('e => e.tagName') != 'SELECT': pg.fill('#' + iid, val)
                    except Exception: pass
                pg.evaluate('submitSignupStep2()'); pg.wait_for_timeout(1200)
                r['steps'].append('שלב 2: ' + ('עבר' if pg.locator('#signup-step3').get_attribute('aria-hidden') == 'false' else 'נעצר ' + clean(vis_errors(pg))))
                pg.fill('#su3-first', 'בדיקה'); pg.fill('#su3-last', 'מערכת'); 
                if pg.locator('#su3-job').count(): pg.fill('#su3-job', 'בדיקות')
                pg.locator('#su3-chips .su-chip').first.click()
                pg.evaluate('submitSignupStep3()'); pg.wait_for_timeout(9000)
                r['steps'].append('שלב 3 — ההודעה למשתמש: ' + clean(pg.inner_text('#su3-status')))
            except Exception as e: r['steps'].append('נעצר: ' + clean(e))
            ctx.close(); out[tag] = r
        br.close()
print(json.dumps(out, ensure_ascii=False))
