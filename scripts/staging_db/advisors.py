#!/usr/bin/env python3
# קריאה בלבד: יועצי האבטחה והביצועים של Supabase לפרויקט Staging. SBT ו-API מהסביבה.
import os, json, urllib.request
tok, api = os.environ["SBT"], os.environ["API"]
def get(path):
    req = urllib.request.Request(api + path, headers={"Authorization": "Bearer " + tok})
    try:
        with urllib.request.urlopen(req, timeout=40) as r: return r.status, json.load(r)
    except urllib.error.HTTPError as e: return e.code, {}
    except Exception as e: return 0, {"err": type(e).__name__}
out = []
for kind in ("security", "performance"):
    code, d = get(f"/advisors/{kind}")
    lints = d.get("lints", []) if isinstance(d, dict) else []
    out.append(f"{kind}: HTTP {code}, {len(lints)} findings")
    for l in lints[:12]:
        out.append(f"  · [{l.get('level')}] {l.get('name')}: {(l.get('detail') or l.get('title') or '')[:220]}")
for path in ("/config/database/postgres", "/network-restrictions", "/ssl-enforcement"):
    code, d = get(path)
    out.append(f"{path}: HTTP {code} {json.dumps(d, ensure_ascii=False)[:250] if code == 200 else ''}")
print("\n".join(out))
