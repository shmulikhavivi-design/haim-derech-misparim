#!/usr/bin/env python3
"""
חיים דרך מספרים — בדיקת עשן לאתר החי אחרי ההשקה. לא יוצרת חשבון ולא כותבת נתונים.

* טוענת את האתר בדפדפן (גודל אייפון) ואוספת שגיאות JavaScript.
* בודקת שמסך הכניסה, ההרשמה ותיבת האישור החובה מופיעים.
* כל בקשת הרשמה לשרת (auth/v1/signup) נחסמת בדפדפן לפני שהיא יוצאת, כך שלא נוצר שום משתמש.
* בודקת שהרשמה בלי סימון התיבה לא מגיעה לשרת, ושעם סימון האפליקציה מנסה לשלוח (ונחסמת אצלנו).
* התחברות עם כתובת שלא קיימת: מוודאת ש-Supabase Auth עונה (נדחית, בלי שינוי נתונים).
"""
import json, os, sys, time
from playwright.sync_api import sync_playwright

SITE = "https://shmulikhavivi-design.github.io/haim-derech-misparim/"
OUT = os.environ.get("SMOKE_OUT", "/tmp/smoke")
os.makedirs(OUT, exist_ok=True)
res = {"page_errors": [], "console_errors": [], "signup_requests_blocked": 0, "checks": {}}

def ok(name, cond, info=""):
    res["checks"][name] = {"ok": bool(cond), "info": str(info)[:300]}

def pass_intro(page):
    # מסך הפתיחה: "מתחילים עכשיו" רק מסיר את השכבה
    btn = page.locator("#intro-screen button, #intro-screen .intro-btn").first
    if page.locator("#intro-screen").is_visible():
        if btn.count(): btn.click()
        else: page.evaluate("startFromIntro()")
        page.wait_for_timeout(800)

with sync_playwright() as p:
    b = p.chromium.launch()
    ctx = b.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=2, is_mobile=True, has_touch=True, locale="he-IL")
    page = ctx.new_page()
    page.on("pageerror", lambda e: res["page_errors"].append(str(e)[:300]))
    page.on("console", lambda m: m.type == "error" and res["console_errors"].append(m.text[:300]))
    def block_signup(route):
        res["signup_requests_blocked"] += 1
        route.abort()
    page.route("**/auth/v1/signup**", block_signup)
    auth_calls = []
    page.on("response", lambda r: "/auth/v1/token" in r.url and auth_calls.append(r.status))

    r = page.goto(SITE + "?smoke=" + str(int(time.time())), wait_until="networkidle", timeout=60000)
    ok("site_http_200", r and r.status == 200, r and r.status)
    page.wait_for_timeout(3000)
    page.screenshot(path=f"{OUT}/1_home.png")
    html = page.content()
    ok("new_version_deployed", 'id="su-consent"' in html and 'id="terms-gate"' in html)
    ok("no_staging_reference", "ousepgdvzammgkxkweze" not in html)
    ok("intro_screen_shown", page.locator("#intro-screen").is_visible())
    pass_intro(page)
    page.screenshot(path=f"{OUT}/1b_auth_choice.png")
    ok("auth_choice_visible", page.locator("#auth-choice-screen").is_visible())

    # הרשמה: בלי סימון התיבה — לא אמור לצאת שום דבר לשרת
    page.get_by_role("button", name="הרשמה").first.click(); page.wait_for_timeout(800)
    ok("signup_screen_visible", page.locator("#signup-screen").is_visible())
    cb = page.locator("#su-consent")
    ok("consent_unchecked_by_default", cb.count() == 1 and not cb.is_checked())
    links = page.locator("#su-f-consent a, #su-f-consent button")
    ok("consent_has_document_links", links.count() >= 3, links.count())
    page.fill("#su-name", "בדיקת עשן")
    page.fill("#su-birth", "1990-01-01")
    page.select_option("#su-gender", "אחר")
    page.fill("#su-city", "תל אביב")
    page.fill("#su-email", "hdm-smoke-test@example.invalid")
    page.fill("#su-pass", "SmokeTest-NotReal-12345")
    page.click("#signup-screen .su-submit"); page.wait_for_timeout(1500)
    page.screenshot(path=f"{OUT}/2_signup_no_consent.png")
    ok("signup_blocked_without_consent", res["signup_requests_blocked"] == 0 and not page.locator("#signup-step2").is_visible(),
       page.locator("#su-f-consent .su-err, #su-status").all_inner_texts())

    # עם סימון — עוברים לשלב 2 (תמונה והעדפות). לא ממשיכים הלאה, ולכן לא נשלחת הרשמה ולא נוצר חשבון
    cb.check(); page.click("#signup-screen .su-submit"); page.wait_for_timeout(2000)
    page.screenshot(path=f"{OUT}/3_signup_step2.png")
    ok("signup_continues_with_consent (stopped at step 2, no account created)",
       page.locator("#signup-step2").is_visible() and res["signup_requests_blocked"] == 0)

    # התחברות: כתובת שלא קיימת — Supabase Auth אמור לענות בדחייה
    page.goto(SITE + "?smoke2=" + str(int(time.time())), wait_until="networkidle", timeout=60000); page.wait_for_timeout(2000)
    pass_intro(page)
    page.get_by_role("button", name="התחברות").first.click(); page.wait_for_timeout(800)
    ok("login_screen_visible", page.locator("#login-screen").is_visible())
    ok("forgot_password_present", page.locator("#li-forgot").is_visible())
    page.fill("#li-email", "hdm-smoke-test@example.invalid"); page.fill("#li-pass", "SmokeTest-NotReal-12345")
    page.click("#li-submit"); page.wait_for_timeout(4000)
    page.screenshot(path=f"{OUT}/4_login_wrong.png")
    ok("auth_server_answers_login (expected 400 = wrong credentials)", any(s == 400 for s in auth_calls), auth_calls)
    b.close()

# שגיאות מבקשות שחסמנו בכוונה אינן תקלה באתר
res["page_errors"] = [e for e in res["page_errors"] if "signup" not in e.lower()]
res["console_errors"] = [e for e in res["console_errors"] if "ERR_FAILED" not in e and "signup" not in e.lower() and "400" not in e]
ok("no_javascript_errors", not res["page_errors"], res["page_errors"])
json.dump(res, open(f"{OUT}/result.json", "w"), ensure_ascii=False, indent=1)
print(json.dumps(res, ensure_ascii=False))
sys.exit(0 if all(c["ok"] for c in res["checks"].values()) else 1)
