#!/usr/bin/env python3
# קריאה בלבד: מי התחבר למסד של Staging לפי יומני Supabase. הריפו ציבורי — לכן לא מודפסות כתובות IP:
# כל כתובת מסווגת: GitHub Actions (מריץ הבדיקות שלנו) / פנימי / אחר (מוצג רק כטביעה קצרה).
import os, re, json, hashlib, ipaddress, collections, urllib.request, urllib.parse, datetime as dt
tok, api = os.environ["SBT"], os.environ["API"]
now = dt.datetime.now(dt.timezone.utc)
def get(url, headers=None):
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers or {}), timeout=60) as r: return json.load(r)
try:
    meta = get("https://api.github.com/meta")
    GH = [ipaddress.ip_network(n) for n in meta.get("actions", [])]
except Exception:
    GH = []
def cls(ip):
    try: a = ipaddress.ip_address(ip)
    except ValueError: return None
    if a.is_private or a.is_loopback or a.is_link_local: return "internal"
    if any(a in n for n in GH): return "github-actions"
    return "OTHER#" + hashlib.sha256(ip.encode()).hexdigest()[:6]
IPRE = re.compile(r'(?<![\w.:])(\d{1,3}(?:\.\d{1,3}){3}|[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{0,4}){2,7})(?![\w.:])')
def scrub(m):
    return IPRE.sub(lambda x: "[" + (cls(x.group(1)) or x.group(1)) + "]", m)
def q(sql, hours):
    p = {"sql": sql, "iso_timestamp_start": (now - dt.timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ"),
         "iso_timestamp_end": (now + dt.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")}
    try: return get(api + "/analytics/endpoints/logs?" + urllib.parse.urlencode(p), {"Authorization": "Bearer " + tok})
    except Exception as e: return {"error": str(e)[:120]}
out = [f"GitHub Actions ranges loaded: {len(GH)}"]
H = 24
for src in ("supavisor_logs", "postgres_logs", "pgbouncer_logs"):
    allc = collections.Counter(); samples = []; total = 0; first = last = None
    for lim in (1000, 300):
        d = q(f"SELECT timestamp, event_message FROM logs WHERE source = '{src}' ORDER BY timestamp DESC LIMIT {lim}", H)
        if not d.get("error"): break
    rows = d.get("result") or []
    for r in rows:
        m = r.get("event_message", ""); total += 1
        ips = [cls(x) for x in IPRE.findall(m)]; ips = [x for x in ips if x]
        user = (re.search(r'(?:user|usename|db_user)["=:\s]+"?([A-Za-z0-9_.\-]+)', m) or [None, "?"])[1]
        fail = bool(re.search(r'fail|denied|invalid password|wrong password', m, re.I))
        for c in (ips or ["no-ip"]):
            allc[(("FAIL " if fail else "") + user, c)] += 1
        if len(samples) < 2 and ips: samples.append(scrub(m)[:260])
    ts = [r.get("timestamp") for r in rows if r.get("timestamp")]
    out.append(f"{src}: {total} rows (24h) {('ERR ' + d['error']) if d.get('error') else ''} {('from ' + min(ts)[:16] + ' to ' + max(ts)[:16]) if ts else ''}")
    for (u, c), v in sorted(allc.items(), key=lambda kv: -kv[1])[:12]:
        out.append(f"  {v:5d}  user={u}  source={c}")
    for s in samples: out.append("  sample: " + s)
# פירוט: הודעות כישלון ביומן המסד וחיבורים מאושרים — עם שדות המטא (משתמש / אפליקציה / כתובת מסווגת)
def attrs(r):
    a = r.get("log_attributes") or {}
    if isinstance(a, str):
        try: a = json.loads(a)
        except Exception: a = {}
    return a
for label, cond in (("pg-fail", "event_message ILIKE '%fail%' OR event_message ILIKE '%denied%'"),
                    ("pg-auth", "event_message ILIKE '%connection authorized%' OR event_message ILIKE '%connection received%'")):
    d = q(f"SELECT timestamp, event_message, log_attributes FROM logs WHERE source = 'postgres_logs' AND ({cond}) ORDER BY timestamp DESC LIMIT 300", 24)
    rows = d.get("result") or []
    msgs = collections.Counter(); who = collections.Counter(); keys = set()
    for r in rows:
        a = attrs(r); keys |= set(a.keys())
        msg = re.sub(r'"[^"]{0,80}"', '"…"', scrub(r.get("event_message", "")))[:150]
        msgs[msg] += 1
        u = next((str(a[k]) for k in a if re.search(r'user_name|usename|\buser\b', k)), "?")
        app = next((str(a[k]) for k in a if 'application' in k), "-")
        ip = next((str(a[k]) for k in a if re.search(r'remote|client|host', k) and IPRE.search(str(a[k]))), "")
        ipc = (cls(IPRE.search(ip).group(1)) if ip else "no-ip")
        who[(u, app[:30], ipc)] += 1
    out.append(f"{label}: {len(rows)} rows {('ERR ' + d['error']) if d.get('error') else ''}")
    for m, v in msgs.most_common(6): out.append(f"  msg {v:4d}  {m}")
    for (u, app, c), v in who.most_common(10): out.append(f"  who {v:4d}  user={u} app={app} source={c}")
    if keys: out.append("  attr keys: " + ", ".join(sorted(keys))[:300])
# כל השורות ב-24 שעות: לפי משתמש, אפליקציה ומקור (מסווג)
for src in ("postgres_logs", "supavisor_logs"):
    d = q(f"SELECT timestamp, event_message, log_attributes FROM logs WHERE source = '{src}' ORDER BY timestamp DESC LIMIT 1000", 24)
    rows = d.get("result") or []; who = collections.Counter(); keys = set()
    for r in rows:
        a = attrs(r); keys |= set(a.keys())
        u = next((str(a[k]) for k in a if re.search(r'user', k)), "?")
        app = next((str(a[k]) for k in a if 'application' in k), "-")
        raw = " ".join(str(a[k]) for k in a if re.search(r'connection_from|remote|client|peer|ip', k))
        m = IPRE.search(raw); ipc = cls(m.group(1)) if m else "no-ip"
        who[(u[:40], app[:24], ipc)] += 1
    out.append(f"ALL {src}: {len(rows)} rows {('ERR ' + d['error']) if d.get('error') else ''}")
    for (u, app, c), v in who.most_common(15): out.append(f"  {v:4d}  user={u} app={app} source={c}")
    out.append("  keys: " + ", ".join(sorted(k for k in keys if not k.startswith('parsed.query')))[:400])
print("\n".join(out))
