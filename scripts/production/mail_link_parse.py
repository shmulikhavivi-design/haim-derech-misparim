# מדפיס רק דומיין, סוג ו-redirect_to של קישורי אימות/איפוס במייל. הטוקן לא מודפס.
import sys, re, html, urllib.parse as u
t = html.unescape(sys.stdin.read()); out = []
for m in sorted(set(re.findall(r"https?://[^\s\"'<>]+", t))):
    p = u.urlparse(m); q = u.parse_qs(p.query)
    if "verify" in p.path or "redirect_to" in q:
        typ = q.get("type", ["?"])[0]; rt = q.get("redirect_to", ["(none)"])[0]
        out.append(p.netloc + p.path + " type=" + typ + " redirect_to=" + rt)
print(" | ".join(out) or "no verify/reset link in body")
