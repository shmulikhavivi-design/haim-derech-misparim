#!/usr/bin/env python3
"""Resend test - Staging only. Sends ONE test email from the verified test subdomain.
Never touches Brevo, Supabase Production or the live app.
MODE=check -> connection + domain check only (no email sent)
MODE=send  -> check, then send one email to RESEND_TEST_TO (Walla only) and poll its status."""
import json, os, sys, time, urllib.request, urllib.error

API = "https://api.resend.com"
DOMAIN = "test.haimderechmisparim.com"
FROM = f"חיים דרך מספרים <noreply@{DOMAIN}>"
REPLY_TO = "life.through.numbers333@gmail.com"
KEY = os.environ.get("RESEND_API_KEY", "").strip()
TO = os.environ.get("RESEND_TEST_TO", "").strip()
MODE = os.environ.get("MODE", "check")

def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers={
        "Authorization": f"Bearer {KEY}", "Content-Type": "application/json",
        "User-Agent": "hdm-staging-resend-test"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try: return e.code, json.loads(e.read() or b"{}")
        except Exception: return e.code, {}

def mask(addr):
    u, _, d = addr.partition("@")
    return (u[:2] + "***@" + d) if d else "***"

print(f"== Resend Staging test | mode={MODE} | sender domain={DOMAIN}")
if not KEY:
    print("RESULT: MISSING_SECRET RESEND_API_KEY (staging environment)"); sys.exit(2)
print("RESEND_API_KEY: present (value hidden)")

full_access = None
st, js = call("GET", "/domains")
if st == 200:
    full_access = True
    doms = {d.get("name"): d for d in js.get("data", [])}
    d = doms.get(DOMAIN)
    if not d:
        print(f"RESULT: DOMAIN_NOT_IN_ACCOUNT ({DOMAIN}); domains seen: {list(doms)}"); sys.exit(3)
    print(f"domain {DOMAIN}: status={d.get('status')} region={d.get('region')}")
    st2, det = call("GET", f"/domains/{d['id']}")
    if st2 == 200:
        for rec in det.get("records", []):
            print(f"  record {rec.get('record')} {rec.get('type')} {rec.get('name')}: {rec.get('status')}")
    if d.get("status") != "verified":
        print("RESULT: DOMAIN_NOT_VERIFIED"); sys.exit(3)
elif st in (401, 403):
    full_access = False
    print(f"key is sending-only (GET /domains -> {st}: {js.get('message','')}); domain status not readable by API — OK, continuing")
else:
    print(f"RESULT: API_ERROR GET /domains -> {st} {js}"); sys.exit(4)

if MODE != "send":
    print("RESULT: CHECK_OK — connection ready, no email sent"); sys.exit(0)

if not TO:
    print("RESULT: MISSING_SECRET RESEND_TEST_TO (staging environment)"); sys.exit(2)
if not TO.lower().endswith(("@walla.co.il", "@walla.com")):
    print(f"RESULT: REFUSED — recipient {mask(TO)} is not a Walla address"); sys.exit(5)

stamp = time.strftime("%d.%m.%Y %H:%M UTC", time.gmtime())
body = {
    "from": FROM, "to": [TO], "reply_to": REPLY_TO,
    "subject": "בדיקת מסירה – חיים דרך מספרים",
    "text": f"זהו מייל בדיקה מסביבת הבדיקות של חיים דרך מספרים ({stamp}). אין צורך לבצע שום פעולה.",
    "html": f'<div dir="rtl" style="font-family:Arial,sans-serif">זהו מייל בדיקה מסביבת הבדיקות של <b>חיים דרך מספרים</b> ({stamp}).<br>אין צורך לבצע שום פעולה.</div>',
    "tags": [{"name": "env", "value": "staging"}, {"name": "purpose", "value": "walla_test"}],
}
st, js = call("POST", "/emails", body)
print(f"send -> HTTP {st} to {mask(TO)}")
if st not in (200, 201) or "id" not in js:
    print(f"RESULT: SEND_FAILED {js.get('name','')} {js.get('message','')}"); sys.exit(6)
eid = js["id"]
print(f"email id: {eid}")

last = None
for i in range(16):  # ~4 minutes
    time.sleep(15)
    st, js = call("GET", f"/emails/{eid}")
    if st in (401, 403):
        print("RESULT: SENT_ACCEPTED — key is sending-only, delivery status must be read in Resend > Emails"); sys.exit(0)
    if st != 200:
        print(f"status poll -> HTTP {st}"); continue
    last = js.get("last_event")
    print(f"t+{(i+1)*15}s last_event={last}")
    if last in ("delivered", "bounced", "complained", "failed", "suppressed"):
        break
print(f"RESULT: LAST_EVENT={last}")
sys.exit(0 if last == "delivered" else 7)
