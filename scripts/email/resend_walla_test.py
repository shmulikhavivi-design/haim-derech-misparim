#!/usr/bin/env python3
"""Resend diagnostics - Staging only. No real recipients: sends go ONLY to Resend's
simulation inboxes (delivered@resend.dev / bounced@resend.dev), never to a person.
Never touches Brevo, Supabase Production or the live app."""
import json, os, subprocess, sys, time, urllib.request, urllib.error

API = "https://api.resend.com"
DOMAIN = "test.haimderechmisparim.com"
ROOT = "haimderechmisparim.com"
FROM = f"חיים דרך מספרים <noreply@{DOMAIN}>"
REPLY_TO = "life.through.numbers333@gmail.com"
KEY = os.environ.get("RESEND_API_KEY", "").strip()
SIM_ONLY = {"delivered@resend.dev", "bounced@resend.dev"}
summary = []

def ok(name, cond, info=""):
    summary.append((("PASS" if cond is True else "FAIL" if cond is False else "INFO"), name, info))
    print(f"[{summary[-1][0]}] {name} {info}")

def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers={
        "Authorization": f"Bearer {KEY}", "Content-Type": "application/json", "User-Agent": "hdm-staging-diag"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try: return e.code, json.loads(e.read() or b"{}")
        except Exception: return e.code, {}

def dig(name, rtype):
    out = subprocess.run(["dig", "+short", rtype, name, "@1.1.1.1"], capture_output=True, text=True, timeout=20).stdout
    return [l.strip().strip('"') for l in out.splitlines() if l.strip()]

print("=" * 60, "\n1) CONNECTION & PERMISSIONS\n" + "=" * 60)
if not KEY:
    ok("RESEND_API_KEY in staging", False, "missing"); sys.exit(2)
ok("RESEND_API_KEY in staging", True, "(value hidden)")
st, js = call("GET", "/domains")
full = st == 200
ok("API reachable + key valid", st in (200, 401, 403) and not (st == 401 and "invalid" in str(js).lower()), f"GET /domains -> {st}")
ok("key permission", None, "Full access" if full else f"Sending access only ({js.get('message','')})")
dom = None
if full:
    doms = {d.get("name"): d for d in js.get("data", [])}
    print("  domains in account:", list(doms))
    d = doms.get(DOMAIN)
    ok(f"{DOMAIN} in account", bool(d))
    if d:
        st2, dom = call("GET", f"/domains/{d['id']}")
        ok(f"{DOMAIN} verified", dom.get("status") == "verified", f"status={dom.get('status')} region={dom.get('region')}")
        for rec in dom.get("records", []):
            print(f"    {rec.get('record'):6} {rec.get('type'):4} {rec.get('name')}: {rec.get('status')}")
        for k in ("open_tracking", "click_tracking", "tls"):
            if k in dom: ok(f"domain setting {k}", None, str(dom.get(k)))
    sk, ks = call("GET", "/api-keys")
    if sk == 200:
        print("  api keys:", [(k.get("name"), k.get("created_at", "")[:10]) for k in ks.get("data", [])])

print("=" * 60, "\n2) DNS (public resolver 1.1.1.1)\n" + "=" * 60)
dkim = dig(f"resend._domainkey.{DOMAIN}", "TXT")
ok("DKIM resend._domainkey.test", any("p=" in x for x in dkim), (dkim[0][:40] + "…") if dkim else "none")
mx_send = dig(f"send.{DOMAIN}", "MX"); spf_send = dig(f"send.{DOMAIN}", "TXT")
ok("Return-Path send.test MX", bool(mx_send), ", ".join(mx_send))
ok("Return-Path send.test SPF", any("amazonses" in x for x in spf_send), "; ".join(spf_send))
dm_sub = dig(f"_dmarc.{DOMAIN}", "TXT"); dm_root = dig(f"_dmarc.{ROOT}", "TXT")
ok("DMARC on test subdomain", None, "; ".join(dm_sub) or "none → inherits root policy")
ok("DMARC on root", any("v=DMARC1" in x for x in dm_root), "; ".join(dm_root))
spf_root = [x for x in dig(ROOT, "TXT") if x.startswith("v=spf1")]
ok("root SPF single record", len(spf_root) <= 1, f"{len(spf_root)} record(s): " + "; ".join(spf_root))
ok("test subdomain A/MX (not required)", None, f"A={dig(DOMAIN,'A')} MX={dig(DOMAIN,'MX')}")
for w in ("walla.co.il", "walla.com"):
    ok(f"Walla MX {w}", None, ", ".join(dig(w, "MX")))
for dn in (DOMAIN, ROOT):
    r = dig(f"{dn}.dbl.spamhaus.org", "A")
    ok(f"Spamhaus DBL {dn}", None if any(x.startswith("127.255.255") for x in r) else (not r),
       "listed!" if r and not any(x.startswith("127.255.255") for x in r) else ("not listed" if not r else "resolver blocked, inconclusive"))

print("=" * 60, "\n3) SIGNUP-CONFIRMATION FLOW (simulated recipients only)\n" + "=" * 60)
fake_url = "https://haimderechmisparim.com/staging.html#type=signup&token=TEST-ONLY-NOT-VALID"
html = f'''<div dir="rtl" lang="he" style="font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:1.7;color:#222;max-width:560px;margin:0 auto;text-align:right">
<p style="font-size:20px;font-weight:bold;margin:0 0 12px">ברוכים הבאים ל"חיים דרך מספרים"</p>
<p>תודה שנרשמת. כדי להשלים את ההרשמה ולהתחיל להכיר אנשים שמתאימים לך, יש לאשר את כתובת המייל שלך:</p>
<p style="margin:24px 0"><a href="{fake_url}" style="background:#994F69;color:#ffffff;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:bold;display:inline-block">אישור כתובת המייל</a></p>
<p>הקישור תקף לזמן מוגבל. אם הוא פג, אפשר לבקש קישור חדש במסך הכניסה לאפליקציה.</p>
<p>אם לא נרשמת ל"חיים דרך מספרים", אפשר להתעלם מהמייל. לא ייפתח חשבון בלי אישור.</p>
<hr style="border:none;border-top:1px solid #ddd;margin:24px 0">
<p style="font-size:13px;color:#666;margin:0">חיים דרך מספרים · haimderechmisparim.com<br>אורן 3, קיסריה · 054-6628866 · life.through.numbers333@gmail.com<br>[בדיקת Staging — סימולציה בלבד]</p></div>'''
text = f"ברוכים הבאים ל\"חיים דרך מספרים\". לאישור כתובת המייל: {fake_url}\n[בדיקת Staging — סימולציה בלבד]"
sent = {}
for to in ("delivered@resend.dev", "bounced@resend.dev"):
    assert to in SIM_ONLY
    st, js = call("POST", "/emails", {"from": FROM, "to": [to], "reply_to": REPLY_TO,
        "subject": "אישור כתובת המייל שלך — חיים דרך מספרים", "html": html, "text": text,
        "tags": [{"name": "env", "value": "staging"}, {"name": "purpose", "value": "signup_sim"}]})
    ok(f"send signup email → {to} (simulation)", st in (200, 201) and "id" in js, f"HTTP {st} {js.get('message','')}")
    if "id" in js: sent[to] = js["id"]
if full and sent:
    final = {}
    for i in range(12):
        time.sleep(10)
        for to, eid in sent.items():
            s, e = call("GET", f"/emails/{eid}")
            if s == 200: final[to] = e.get("last_event"); body_html = e.get("html") or ""
        print(f"  t+{(i+1)*10}s", final)
        if all(v in ("delivered", "bounced", "failed", "suppressed") for v in final.values()) and len(final) == len(sent): break
    ok("delivered@resend.dev → delivered", final.get("delivered@resend.dev") == "delivered", str(final.get("delivered@resend.dev")))
    ok("bounced@resend.dev → bounced (bounce handling)", final.get("bounced@resend.dev") == "bounced", str(final.get("bounced@resend.dev")))
elif sent:
    ok("delivery status", None, "sending-only key: status visible only in Resend > Emails")

print("=" * 60, "\nSUMMARY\n" + "=" * 60)
for s, n, i in summary: print(f"{s:4} | {n} | {i}")
fails = [n for s, n, _ in summary if s == "FAIL"]
print("RESULT:", "ALL_PASS" if not fails else "FAILS: " + "; ".join(fails))
