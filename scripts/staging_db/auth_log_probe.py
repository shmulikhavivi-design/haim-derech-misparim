#!/usr/bin/env python3
# קריאה בלבד: שאילתות ליומני Staging דרך Management API. קורא SBT ו-API מהסביבה. מסתיר כתובות מייל.
import os, re, json, time, urllib.request, urllib.parse, datetime as dt
tok, api = os.environ["SBT"], os.environ["API"]
now = dt.datetime.now(dt.timezone.utc)
def q(sql, hours=1):
    params = {"sql": sql,
              "iso_timestamp_start": (now - dt.timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ"),
              "iso_timestamp_end": (now + dt.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")}
    req = urllib.request.Request(api + "/analytics/endpoints/logs?" + urllib.parse.urlencode(params),
                                 headers={"Authorization": "Bearer " + tok})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=40) as r:
                d = json.load(r)
        except Exception as e:
            d = {"error": f"{type(e).__name__}: {getattr(e, 'code', '')}"}
        if not (isinstance(d.get("error"), str) and "Retry" in d["error"]):
            return d
        time.sleep(5)
    return d
scrub = lambda s: re.sub(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+", "<email>", s)
out = []
d = q("SELECT source_name, count() AS n FROM logs GROUP BY source_name ORDER BY n DESC LIMIT 20")
out.append("sources(1h): " + (json.dumps(d.get("result"), ensure_ascii=False) if d.get("result") is not None else "ERR " + str(d.get("error"))[:200]))
for label, sql in (
    ("auth-errors", "SELECT timestamp, event_message FROM logs WHERE source_name = 'auth_logs' AND (event_message ILIKE '%error%' OR event_message ILIKE '%mail%' OR event_message ILIKE '%smtp%') ORDER BY timestamp DESC LIMIT 15"),
    ("any-mail", "SELECT timestamp, source_name, event_message FROM logs WHERE event_message ILIKE '%smtp%' OR event_message ILIKE '%gomail%' OR event_message ILIKE '%sending%' ORDER BY timestamp DESC LIMIT 15"),
):
    d = q(sql)
    rows = d.get("result")
    if rows is None:
        out.append(f"{label}: ERR " + str(d.get("error"))[:200]); continue
    out.append(f"{label}: {len(rows)} rows")
    seen = set()
    for r in rows:
        m = r.get("event_message", "")
        try:
            j = json.loads(m); m = " ".join(f"{k}={j[k]}" for k in ("level", "msg", "error", "component", "path", "status") if k in j)
        except Exception:
            pass
        m = scrub(m)[:500]
        if m in seen: continue
        seen.add(m); out.append("  · " + m)
        if len(seen) >= 6: break
print("\n".join(out))
