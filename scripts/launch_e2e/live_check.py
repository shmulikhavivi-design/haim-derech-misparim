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
    ok("heart_levels_live", all(x in html for x in ["❤️ התאמה גבוהה מאוד", "🩷 התאמה טובה", "💔 התאמה מאתגרת"]))
    ok("plan_texts_live", "ניתוח נומרולוגי מקוצר (3 שורות)" in html and "❤️ גבוהה מאוד, 🩷 טובה או 💔 מאתגרת" in html and "ניתוח נומרולוגי מורחב לאחר סימון 🎯 הדדי" not in html)
    ok("plus_extended_off_in_app", "plus:  { target: true,  chat: true,  chatLimit: null, score: 'full',  whoLiked: true,  analysis: 'none'" in html)
    lvl = pg.evaluate("() => [matchCategoryLabel({goodCount:3}), matchCategoryLabel({goodCount:1}), matchCategoryLabel({goodCount:0})]")
    vip = pg.evaluate("() => ({ items: HDM_PLAN_INFO.vip.items, price: HDM_PLAN_INFO.vip.price, prices: ['free','basic','plus','vip'].map(k => HDM_PLAN_INFO[k].price), feats: JSON.stringify(HDM_PLAN_FEATURES) })")
    ok("vip_benefit_text", "30% הנחה על שירותי נומרולוגיה אצל נומרולוגית" in vip["items"] and not any("לימור" in x for x in vip["items"]), vip["items"])
    ok("vip_other_benefits_unchanged", vip["items"][:3] == ["כל הטבות פלוס", "ניתוח נומרולוגי מורחב מיד לאחר סימון 🎯, גם ללא הדדיות", "פתיחת צ׳אט עדיין מחייבת סימון הדדי"] and len(vip["items"]) == 5, vip["items"])
    ok("prices_and_features_unchanged", vip["prices"] == ["₪0", "₪29.90", "₪48.90", "₪79.90"] and '"vip":{"target":true,"chat":true,"chatLimit":null,"score":"full","whoLiked":true,"analysis":"own","vip":true}' in vip["feats"], vip)
    ok("analysis_screen_text", "כמנוי/ה VIP מגיעה לך 30% הנחה על שירותי נומרולוגיה אצל נומרולוגית." in html and "זכאים של לימור רון" not in html)
    mail = pg.evaluate("() => { myProfile = { currentName: 'בדיקה' }; myId = 'x'; const a = document.createElement('div'); a.innerHTML = hdmVipBookingHtml(); const h = a.querySelector('a[href^=\"mailto:\"]').getAttribute('href'); return decodeURIComponent(h.split('body=')[1]); }")
    ok("booking_email_updated", mail.startswith("שלום,\n") and "לימור" not in mail and "30%" in mail, mail[:60])
    pg.evaluate("() => { myProfile = null; myId = null; }")
    ok("level_mapping", lvl == ["❤️ התאמה גבוהה מאוד", "🩷 התאמה טובה", "💔 התאמה מאתגרת"], lvl)
    pv = pg.evaluate("() => { hdmEnt = null; return true; }")
    ok("plus_card_shows_3_lines_basic_hides", pg.evaluate("() => HDM_PLAN_FEATURES.plus.score === 'full' && HDM_PLAN_FEATURES.basic.score === 'label' && HDM_PLAN_FEATURES.vip.analysis === 'own' && HDM_PLAN_FEATURES.plus.analysis === 'none'"))
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
