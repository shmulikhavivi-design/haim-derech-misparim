#!/usr/bin/env python3
# קריאה בלבד: מי התחבר למסד של Staging לפי יומני Supabase (שם משתמש, אפליקציה, כתובת). לא מדפיס סיסמאות.
import os, re, json, collections, urllib.request, urllib.parse, datetime as dt
tok, api = os.environ["SBT"], os.environ["API"]
now = dt.datetime.now(dt.timezone.utc)
def q(sql, hours):
    p = {"sql": sql, "iso_timestamp_start": (now - dt.timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ"),
         "iso_timestamp_end": (now + dt.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")}
    req = urllib.request.Request(api + "/analytics/endpoints/logs?" + urllib.parse.urlencode(p), headers={"Authorization": "Bearer " + tok})
    try:
        with urllib.request.urlopen(req, timeout=60) as r: return json.load(r)
    except Exception as e: return {"error": str(e)[:120]}
out = []
for hours in (24, 6, 1):
    d = q("SELECT min(timestamp) AS first, max(timestamp) AS last, count() AS n FROM logs WHERE source = 'postgres_logs'", hours)
    if d.get("result"): out.append(f"postgres_logs ({hours}h window): {d['result'][0]}"); break
H = int(os.environ.get("AUDIT_HOURS", "24"))
for src in ("postgres_logs", "supavisor_logs", "pgbouncer_logs"):
    d = q(f"SELECT timestamp, event_message FROM logs WHERE source = '{src}' AND (event_message ILIKE '%connection authorized%' OR event_message ILIKE '%authentication failed%' OR event_message ILIKE '%password%' OR event_message ILIKE '%client%') ORDER BY timestamp DESC LIMIT 1000", H)
    rows = d.get("result") or []
    c = collections.Counter(); fails = collections.Counter(); first = {}; 
    for r in rows:
        m = r.get("event_message", "")
        ts = r.get("timestamp")
        user = (re.search(r'user[=:"\s]+([A-Za-z0-9_.\-]+)', m) or [None, "?"])[1]
        app = (re.search(r'application_name[=:"\s]+([A-Za-z0-9_.\-]+)', m) or [None, "-"])[1]
        ip = (re.search(r'(?:host|client|peer|addr)[^0-9]{0,12}(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}|[0-9a-f:]{6,})', m) or [None, "-"])[1]
        key = f"{user} | app={app} | ip={ip}"
        if re.search(r'fail', m, re.I): fails[key] += 1
        else: c[key] += 1
    out.append(f"{src}: {len(rows)} rows {('ERR '+d['error']) if d.get('error') else ''}")
    for k, v in c.most_common(12): out.append(f"  ok   {v:4d}  {k}")
    for k, v in fails.most_common(8): out.append(f"  FAIL {v:4d}  {k}")
    if rows and not c and not fails:
        out.append("  sample: " + rows[0].get("event_message", "")[:300])
print("\n".join(out))
