# בדיקת "שלחו לי מייל אימות חדש" מול פרויקט Staging בלבד (בלי סודות — רק המפתח הציבורי של Staging).
#   python3 scripts/email/e2e_resend_staging.py <out_dir>
# 1. יוצר משתמש בדיקה לא מאושר ב-Staging, בכתובת כינוי של תיבת האפליקציה (life.through.numbers333+...@gmail.com).
# 2. מנסה להתחבר במסך ההתחברות של staging.html ← מצפה להודעת "צריך לאשר" ולכפתור השליחה החוזרת.
# 3. לוחץ על הכפתור (אחרי 65 שניות — מגבלת מייל אחד לדקה לכתובת) ← מצפה ל-200 מ-/auth/v1/resend ולהודעת הצלחה.
# לא נוגע ב-Production ולא שולח מייל לאף משתמש אמיתי.
import functools, http.server, json, os, pathlib, secrets, sys, threading, time, urllib.request
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = sys.argv[1] if len(sys.argv) > 1 else 'out'; os.makedirs(OUT, exist_ok=True)
REF, PROD = 'ousepgdvzammgkxkweze', 'qtspzigjlbtckqfyaubp'
KEY = 'sb_publishable_UXJrkbmi6h3j3Yvaey5Nvw_HIDJOy40'
page_src = (ROOT / 'staging.html').read_text(encoding='utf-8')
assert REF in page_src and PROD not in page_src, 'staging.html must point to Staging only'
AUTH = f'https://{REF}.supabase.co/auth/v1'
RUN = os.environ.get('GITHUB_RUN_ID') or str(int(time.time()))
EMAIL = f'life.through.numbers333+resend-stg-{RUN}@gmail.com'
PW = 'T' + secrets.token_hex(10) + '!a'
results = []
def note(k, v): results.append((k, v)); print(f'{k}: {v}', flush=True)

def post(path, body):
    req = urllib.request.Request(AUTH + path, data=json.dumps(body).encode(), method='POST',
                                 headers={'apikey': KEY, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as r: return r.status, json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or b'{}')

st, body = post('/signup', {'email': EMAIL, 'password': PW})
sent = body.get('confirmation_sent_at') or (body.get('user') or {}).get('confirmation_sent_at')
note('signup', f'HTTP {st}, confirmation_sent_at={sent}, msg={body.get("msg") or body.get("message") or ""}')
signup_ok = st == 200 and bool(sent)

h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(ROOT)); h.log_message = lambda *a: None
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), h); threading.Thread(target=srv.serve_forever, daemon=True).start()
URL = f'http://127.0.0.1:{srv.server_address[1]}/staging.html'
resend_calls = []
ok = False
with sync_playwright() as p:
    d = {k: v for k, v in p.devices['iPhone 13'].items() if k != 'default_browser_type'}
    b = p.chromium.launch(); c = b.new_context(**d, locale='he-IL', timezone_id='Asia/Jerusalem')
    c.add_init_script(f"try{{localStorage.setItem('hdm_staging_publishable_key','{KEY}')}}catch(e){{}}")
    c.route('**/*', lambda r: r.abort() if PROD in r.request.url else r.continue_())
    pg = c.new_page()
    pg.on('response', lambda r: resend_calls.append(r.status) if r.url.startswith(AUTH + '/resend') else None)
    pg.goto(URL); pg.wait_for_timeout(2500)
    pg.evaluate("() => { const i=document.getElementById('intro-screen'); if(i){i.classList.add('intro-hide'); i.style.display='none';} const a=document.getElementById('auth-choice-screen'); if(a) a.classList.add('auth-hide'); openLogin(); }")
    pg.wait_for_timeout(600)
    pg.fill('#li-email', EMAIL); pg.fill('#li-pass', PW); pg.click('#li-submit')
    pg.wait_for_function("() => (document.getElementById('li-status').textContent||'').length > 0", timeout=30000)
    msg1 = pg.inner_text('#li-status'); vis1 = pg.is_visible('#li-resend')
    pg.screenshot(path=f'{OUT}/1-login-unconfirmed.png')
    note('login-message', msg1); note('resend-button-visible', vis1)
    time.sleep(65)
    pg.click('#li-resend')
    pg.wait_for_function("() => /שלחנו מייל אימות חדש|נכשל|לא הצלחנו|יותר מדי/.test(document.getElementById('li-status').textContent||'')", timeout=60000)
    msg2 = pg.inner_text('#li-status')
    pg.screenshot(path=f'{OUT}/2-resend-sent.png')
    note('resend-http', resend_calls); note('resend-message', msg2)
    # לחיצה שנייה מיד — חייבת להיחסם במכשיר (בלי בקשה נוספת לשרת)
    n = len(resend_calls); pg.click('#li-resend'); pg.wait_for_timeout(1500)
    note('cooldown-blocks-second-click', len(resend_calls) == n and 'אפשר לבקש שוב' in pg.inner_text('#li-status'))
    ok = signup_ok and vis1 and 'לאשר' in msg1 and resend_calls[:1] == [200] and 'שלחנו מייל אימות חדש' in msg2 and results[-1][1] is True
    b.close()
srv.shutdown()
summary = os.environ.get('GITHUB_STEP_SUMMARY')
if summary:
    with open(summary, 'a', encoding='utf-8') as f:
        for k, v in results: f.write(f'- **{k}:** {v}\n')
        f.write(f"\n**RESULT:** {'✅ עבר' if ok else '❌ נכשל'}\n")
print('RESULT', 'PASS' if ok else 'FAIL'); sys.exit(0 if ok else 1)
