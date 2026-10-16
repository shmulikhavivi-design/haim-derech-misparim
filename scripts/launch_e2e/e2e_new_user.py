#!/usr/bin/env python3
"""
חיים דרך מספרים — בדיקת קצה לקצה של משתמש חדש באתר החי (אחרי ההשקה).
יוצר חשבון בדיקה אחד עם תיבת דואר זמנית (mail.tm), עובר הרשמה → מייל אימות → התחברות → שימוש,
ומוחק את החשבון בסוף דרך "מחיקת חשבון" שבאפליקציה. לא נוגע במשתמשים קיימים, לא מסמן 🎯 ולא שולח הודעות.
"""
import json, os, re, random, string, struct, sys, time, zlib, urllib.request, urllib.error
from playwright.sync_api import sync_playwright

SITE = "https://shmulikhavivi-design.github.io/haim-derech-misparim/"
OUT = os.environ.get("E2E_OUT", "/tmp/e2e"); os.makedirs(OUT, exist_ok=True)
R = {"steps": {}, "page_errors": [], "email": {}, "notes": []}
def step(name, ok, info=""):
    R["steps"][name] = {"ok": bool(ok), "info": str(info)[:400]}
    msg = (("✅ " if ok else "❌ ") + name + (" — " + str(info)[:300] if info else "")).replace("%", "%25").replace("\n", " ")
    print(f"::{'notice' if ok else 'error'} title=e2e-{name}::{msg}", flush=True)
    return ok

# ---------- תיבת דואר זמנית ----------
API = "https://api.mail.tm"
def mt(method, path, data=None, tok=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(data).encode() if data is not None else None,
                                 headers={"Content-Type": "application/json", "Accept": "application/json", **({"Authorization": "Bearer " + tok} if tok else {})})
    with urllib.request.urlopen(req, timeout=30) as r: return json.loads(r.read() or b"{}")
try:
    dom = mt("GET", "/domains")["hydra:member"][0]["domain"]
except Exception as e:
    print(f"::error title=e2e-temp_inbox::mail.tm unreachable: {type(e).__name__}: {str(e)[:200]}"); sys.exit(1)
user = "hdmtest" + "".join(random.choices(string.ascii_lowercase + string.digits, k=8))
EMAIL = f"{user}@{dom}"
MPASS = "".join(random.choices(string.ascii_letters + string.digits, k=16))
APASS = "Hdm-" + "".join(random.choices(string.ascii_letters + string.digits, k=14)) + "9"
mt("POST", "/accounts", {"address": EMAIL, "password": MPASS})
TOKEN = mt("POST", "/token", {"address": EMAIL, "password": MPASS})["token"]
R["email"]["domain"] = dom
step("temp_inbox_created", True, "***@" + dom)

def png(path):
    w = h = 64
    raw = b"".join(b"\x00" + bytes([200, 150, 70]) * w for _ in range(h))
    def ch(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + ch(b"IDAT", zlib.compress(raw)) + ch(b"IEND", b""))
PHOTO = os.path.join(OUT, "photo.png"); png(PHOTO)

def pass_intro(page):
    if page.locator("#intro-screen").is_visible():
        b = page.locator("#intro-screen button").first
        b.click() if b.count() else page.evaluate("startFromIntro()")
        page.wait_for_timeout(800)

deleted = False
with sync_playwright() as p:
    b = p.chromium.launch()
    ctx = b.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=2, is_mobile=True, has_touch=True, locale="he-IL")
    page = ctx.new_page()
    page.on("pageerror", lambda e: R["page_errors"].append(str(e)[:300]))
    rpc = {}
    def on_resp(r):
        m = re.search(r"/rest/v1/rpc/([a-z_0-9]+)", r.url)
        if m:
            rpc.setdefault(m.group(1), []).append(r.status)
            if m.group(1) == "hdm_delete_my_data":
                try: R["delete_result"] = r.json()
                except Exception: pass
        if "/auth/v1/signup" in r.url: rpc.setdefault("auth_signup", []).append(r.status)
        if "/auth/v1/token" in r.url: rpc.setdefault("auth_token", []).append(r.status)
    page.on("response", on_resp)
    try:
        # ---------- 1. הרשמה ----------
        page.goto(SITE + "?e2e=" + str(int(time.time())), wait_until="networkidle", timeout=60000); page.wait_for_timeout(2500)
        pass_intro(page)
        page.get_by_role("button", name="הרשמה").first.click(); page.wait_for_timeout(700)
        page.fill("#su-name", "בדיקת מערכת"); page.fill("#su-birth", "1990-05-17"); page.select_option("#su-gender", "אחר")
        page.fill("#su-city", "תל אביב"); page.fill("#su-email", EMAIL); page.fill("#su-pass", APASS)
        page.check("#su-consent"); page.click("#signup-screen .su-submit"); page.wait_for_timeout(1500)
        step("signup_step1", page.locator("#signup-step2").is_visible(), page.locator("#su-status").inner_text())
        page.set_input_files("#su2-photo-input", PHOTO); page.wait_for_timeout(1500)
        for sel, val in [("#su2-looking", "כולם"), ("#su2-marital", "רווק/ה"), ("#su2-children", "לא"), ("#su2-smoking", "לא")]:
            try: page.select_option(sel, val)
            except Exception as e: R["notes"].append(f"{sel}: {e}"[:150])
        page.fill("#su2-height", "175"); page.fill("#su2-agemin", "25"); page.fill("#su2-agemax", "45")
        page.fill("#su2-bio", "חשבון בדיקה אוטומטי — נמחק מיד בסיום הבדיקה")
        page.click("#signup-step2 .su-submit"); page.wait_for_timeout(2000)
        page.screenshot(path=f"{OUT}/1_step2.png")
        step("signup_step2", page.locator("#signup-step3").is_visible(), page.locator("#su2-status").inner_text())
        page.fill("#su3-first", "בדיקה"); page.fill("#su3-last", "מערכת"); page.fill("#su3-job", "בדיקות")
        chips = page.locator("#su3-chips .su-chip")
        for i in range(min(3, chips.count())): chips.nth(i).click()
        page.click("#signup-step3 .su-submit"); page.wait_for_timeout(6000)
        page.screenshot(path=f"{OUT}/2_after_signup.png")
        st3 = page.locator("#su3-status").inner_text()
        step("signup_submitted_needs_confirm", "מייל" in st3 and 200 in rpc.get("auth_signup", []), f"signup HTTP {rpc.get('auth_signup')} | {st3}")

        # ---------- 2. מייל האימות ----------
        msg = None; t0 = time.time()
        while time.time() - t0 < 300:
            ms = mt("GET", "/messages", tok=TOKEN).get("hydra:member", [])
            if ms: msg = mt("GET", "/messages/" + ms[0]["id"], tok=TOKEN); break
            time.sleep(8)
        if not step("confirmation_email_received", msg, f"after {int(time.time()-t0)}s"): raise SystemExit
        R["email"].update({"seconds": int(time.time() - t0), "from_name": msg.get("from", {}).get("name"),
                           "from_domain": (msg.get("from", {}).get("address") or "").split("@")[-1], "subject": msg.get("subject")})
        body = " ".join(msg.get("html") or []) + " " + (msg.get("text") or "")
        links = [l.replace("&amp;", "&") for l in re.findall(r'https?://[^\s"\'<>]+', body)]
        link = next((l for l in links if "verify" in l or "token" in l or "confirm" in l), None)
        R["email"]["hebrew_body"] = bool(re.search(r"[֐-׿]", body))
        if not step("confirmation_link_found", link, (link or "")[:60] + "…"): raise SystemExit

        # ---------- 3. לחיצה על הקישור (לשונית חדשה, אותו דפדפן) ----------
        lp = ctx.new_page(); lp.on("pageerror", lambda e: R["page_errors"].append("link-tab: " + str(e)[:300]))
        lp.goto(link, wait_until="networkidle", timeout=60000); lp.wait_for_timeout(4000)
        lp.screenshot(path=f"{OUT}/3_link_opened.png")
        step("confirmation_link_opens_site", lp.url.startswith(SITE) and "error" not in lp.url.lower(), lp.url.split("#")[0].split("?")[0])
        lp.close()

        # ---------- 4. התחברות בלשונית המקורית ----------
        page.goto(SITE + "?e2e2=" + str(int(time.time())), wait_until="networkidle", timeout=60000); page.wait_for_timeout(3000)
        pass_intro(page)
        logged = page.evaluate("!!(window.myId && window.__authSignedIn)")
        if not logged:
            page.get_by_role("button", name="התחברות").first.click(); page.wait_for_timeout(700)
            page.fill("#li-email", EMAIL); page.fill("#li-pass", APASS); page.click("#li-submit"); page.wait_for_timeout(7000)
        page.screenshot(path=f"{OUT}/4_after_login.png")
        state = page.evaluate("""() => ({ myId: (typeof myId!=='undefined')?myId:null,
             active: (document.querySelector('.screen.active')||{}).id || null,
             gate: !!document.querySelector('#terms-gate.open, #terms-gate[aria-hidden=\"false\"]'),
             loginStatus: (document.querySelector('#li-status')||{}).textContent || '' })""")
        R["state_after_login"] = state
        if state.get("gate"):
            page.check("#tg-consent"); page.locator("#terms-gate button.su-submit, #terms-gate .tg-go, #terms-gate button").last.click(); page.wait_for_timeout(3000)
            R["notes"].append("terms gate shown after login and accepted")
        step("login_after_confirm_enters_app", state.get("myId") and str(state.get("myId")).startswith("reg_"), json.dumps(state, ensure_ascii=False))

        # ---------- 5. שימוש: הפרופיל נשמר בשרת, מסך ההתאמות, רשימת השיחות ----------
        prof = page.evaluate("""async () => { try { const s = await dbCap.doc('profiles/' + myId).get(); const d = s.exists ? s.data() : null;
             return { exists: s.exists, name: d && d.currentName, hasPhoto: !!(d && (d.photoUrl || d.photoAssetId)), noBirthInPublic: !(d && d.birthdate) }; } catch(e) { return { err: String(e) }; } }""")
        step("profile_saved_on_server", prof.get("exists"), json.dumps(prof, ensure_ascii=False))
        step("profile_photo_saved", prof.get("hasPhoto"), "")
        step("birthdate_not_public", prof.get("noBirthInPublic"), "")
        page.screenshot(path=f"{OUT}/5_app.png")
        bad_rpc = {k: v for k, v in rpc.items() if k.startswith("hdm_") and any(s >= 400 for s in v)}
        step("server_functions_ok", not bad_rpc, json.dumps({k: v[:5] for k, v in rpc.items()}, ensure_ascii=False))
        plan = page.evaluate("async () => { try { return await window.__hdmRpc('hdm_my_plan'); } catch(e) { return String(e).slice(0,120); } }")
        R["new_user_plan"] = plan
    except SystemExit:
        pass
    except Exception as e:
        step("unexpected_error", False, f"{type(e).__name__}: {str(e)[:250]}")
    finally:
        # ---------- 6. מחיקת חשבון הבדיקה ----------
        try:
            if page.evaluate("!!(window.myId && window.__authSignedIn)"):
                page.evaluate("openDeleteAccount()"); page.wait_for_timeout(600)
                page.fill("#hdm-del-confirm", "מחיקה"); page.click("#hdm-del-go"); page.wait_for_timeout(6000)
                dr = R.get("delete_result") or {}
                deleted = step("test_account_deleted_via_app", dr.get("authUserDeleted") is True, json.dumps(dr))
        except Exception as e:
            step("test_account_deleted_via_app", False, e)
        b.close()

# אימות שהחשבון נמחק: התחברות עם אותם פרטים חייבת להיכשל
if deleted:
    with sync_playwright() as p:
        b = p.chromium.launch(); pg = b.new_page(); st = []
        pg.on("response", lambda r: "/auth/v1/token" in r.url and st.append(r.status))
        pg.goto(SITE, wait_until="networkidle", timeout=60000); pg.wait_for_timeout(2000); pass_intro(pg)
        pg.get_by_role("button", name="התחברות").first.click(); pg.wait_for_timeout(600)
        pg.fill("#li-email", EMAIL); pg.fill("#li-pass", APASS); pg.click("#li-submit"); pg.wait_for_timeout(4000)
        step("deleted_account_cannot_login", st and all(s == 400 for s in st), st); b.close()
try:
    for m in mt("GET", "/messages", tok=TOKEN).get("hydra:member", []): mt("DELETE", "/messages/" + m["id"], tok=TOKEN)
except Exception: pass
R["page_errors"] = R["page_errors"][:10]
json.dump(R, open(f"{OUT}/result.json", "w"), ensure_ascii=False, indent=1)
print("::notice title=e2e-summary::" + json.dumps({k: R.get(k) for k in ("email", "notes", "page_errors", "new_user_plan", "delete_result")}, ensure_ascii=False).replace("%", "%25")[:3000])
sys.exit(0 if all(s["ok"] for s in R["steps"].values()) else 1)
