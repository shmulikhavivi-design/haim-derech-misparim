# צילומי מסך מקומיים של מסכי האפליקציה (בלי מסד: כל בקשה ל-Supabase נחסמת). לבדיקת עיצוב בלבד.
#   python3 scripts/design/shots_local.py <page.html> <out_dir>
import functools, http.server, sys, threading, pathlib, os
from playwright.sync_api import sync_playwright
ROOT = pathlib.Path(__file__).resolve().parents[2]
PAGE, OUT = sys.argv[1], sys.argv[2]; os.makedirs(OUT, exist_ok=True)
h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(ROOT)); h.log_message = lambda *a: None
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), h); threading.Thread(target=srv.serve_forever, daemon=True).start()
URL = f'http://127.0.0.1:{srv.server_address[1]}/{PAGE}'
SCREENS = {
  'intro':    None,
  'authchoice': "() => { const i=document.getElementById('intro-screen'); i.classList.add('intro-hide'); i.style.display='none'; }",
  'register': "() => { const i=document.getElementById('intro-screen'); i.classList.add('intro-hide'); i.style.display='none'; document.getElementById('auth-choice-screen').classList.add('auth-hide'); go('screen-register'); }",
  'match':    "() => { const i=document.getElementById('intro-screen'); i.style.display='none'; i.classList.add('intro-hide'); document.getElementById('auth-choice-screen').classList.add('auth-hide'); go('screen-match'); }",
  'settings': "() => { const i=document.getElementById('intro-screen'); i.style.display='none'; i.classList.add('intro-hide'); document.getElementById('auth-choice-screen').classList.add('auth-hide'); go('screen-settings'); }",
  'profile':  "() => { const i=document.getElementById('intro-screen'); i.style.display='none'; i.classList.add('intro-hide'); document.getElementById('auth-choice-screen').classList.add('auth-hide'); go('screen-profile'); }",
  'chats':    "() => { const i=document.getElementById('intro-screen'); i.style.display='none'; i.classList.add('intro-hide'); document.getElementById('auth-choice-screen').classList.add('auth-hide'); go('screen-chats'); }",
  'connect':  "() => { const i=document.getElementById('intro-screen'); i.style.display='none'; i.classList.add('intro-hide'); document.getElementById('auth-choice-screen').classList.add('auth-hide'); go('screen-connect'); }",
  'plans':    "() => { const i=document.getElementById('intro-screen'); i.style.display='none'; i.classList.add('intro-hide'); document.getElementById('auth-choice-screen').classList.add('auth-hide'); go('screen-match'); window.hdmRefreshPlan=()=>Promise.resolve(); myId='t'; hdmEnt={forId:'t',installed:true,plan:'free'}; hdmOpenPlans(); }",
  'checkout': "() => { const i=document.getElementById('intro-screen'); i.style.display='none'; i.classList.add('intro-hide'); document.getElementById('auth-choice-screen').classList.add('auth-hide'); go('screen-match'); hdmOpenCheckout('plus'); }",
}
with sync_playwright() as p:
    d = {k: v for k, v in p.devices['iPhone 13'].items() if k != 'default_browser_type'}
    b = p.chromium.launch()
    for name, js in SCREENS.items():
        c = b.new_context(**d, locale='he-IL', timezone_id='Asia/Jerusalem')
        c.route('**/*', lambda r: r.abort() if 'supabase.co' in r.request.url else r.continue_())
        pg = c.new_page(); pg.goto(URL); pg.wait_for_timeout(900)
        if js: pg.evaluate(js); pg.wait_for_timeout(500)
        pg.screenshot(path=f'{OUT}/{name}.png'); c.close()
    b.close()
srv.shutdown(); print('ok', OUT)
