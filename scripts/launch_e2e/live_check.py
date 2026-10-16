# בדיקת האתר החי אחרי פריסה — בלי ליצור חשבון ובלי לכתוב נתונים.
import time, urllib.request, urllib.error
from playwright.sync_api import sync_playwright
SITE = "https://shmulikhavivi-design.github.io/haim-derech-misparim/"
fail = 0
def ok(n, c, i=""):
    global fail; fail |= (not c); print(f"::{'notice' if c else 'error'} title=live-{n}::{'✅' if c else '❌'} {n} {str(i)[:300]}")
def code(path):
    try: return urllib.request.urlopen(SITE + path + "?t=" + str(int(time.time())), timeout=30).status
    except urllib.error.HTTPError as e: return e.code
ok("staging_html_404", code("staging.html") == 404, code("staging.html"))
ok("internal_files_404", code("supabase/production/01_production_migration.sql") == 404 and code("scripts/production/run.sh") == 404)
ok("manifest_200", code("manifest.webmanifest") == 200)
with sync_playwright() as p:
    b = p.chromium.launch(); pg = b.new_context(viewport={"width": 390, "height": 844}, is_mobile=True, locale="he-IL").new_page()
    errs = []; pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
    auth = []; pg.on("response", lambda r: "/auth/v1/token" in r.url and auth.append(r.status))
    pg.route("**/auth/v1/signup**", lambda r: r.abort())
    r = pg.goto(SITE + "?live=" + str(int(time.time())), wait_until="networkidle", timeout=60000); pg.wait_for_timeout(3000)
    html = pg.content()
    ok("site_200", r.status == 200, r.status)
    ok("new_version_live", "המסלולים בתשלום יופעלו בקרוב" in html and "'בקרוב'))" in html)
    ok("prices_unchanged", all(x in html for x in ["29.90", "48.90", "79.90", "₪0"]))
    if pg.locator("#intro-screen").is_visible():
        bt = pg.locator("#intro-screen button").first; bt.click() if bt.count() else pg.evaluate("startFromIntro()"); pg.wait_for_timeout(800)
    ok("auth_choice_visible", pg.locator("#auth-choice-screen").is_visible())
    pg.get_by_role("button", name="הרשמה").first.click(); pg.wait_for_timeout(700)
    ok("signup_with_unchecked_consent", pg.locator("#signup-screen").is_visible() and not pg.locator("#su-consent").is_checked())
    pg.reload(wait_until="networkidle"); pg.wait_for_timeout(2000)
    if pg.locator("#intro-screen").is_visible():
        bt = pg.locator("#intro-screen button").first; bt.click() if bt.count() else pg.evaluate("startFromIntro()"); pg.wait_for_timeout(800)
    pg.get_by_role("button", name="התחברות").first.click(); pg.wait_for_timeout(700)
    pg.fill("#li-email", "hdm-live-check@example.invalid"); pg.fill("#li-pass", "NotARealPassword-123"); pg.click("#li-submit"); pg.wait_for_timeout(4000)
    ok("auth_server_responds", 400 in auth, auth)
    ok("no_js_errors", not errs, errs)
    b.close()
raise SystemExit(fail)
