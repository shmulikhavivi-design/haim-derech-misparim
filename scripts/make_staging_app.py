#!/usr/bin/env python3
"""Turns a copy of the app into the Staging version. Used only on a separate staging branch
that is never merged into main.

  python3 scripts/make_staging_app.py <STAGING_PROJECT_URL> <STAGING_PUBLISHABLE_KEY>

What it changes (and nothing else):
  * the Supabase project URL and publishable key in index.html -> the Staging project
  * a fixed "סביבת בדיקות" ribbon at the top of every screen
  * the page title and the home-screen name, so it can't be mistaken for the real app

Safety checks: the URL must be a Supabase project URL that is not the production one, and the key
must be a publishable key. A secret key (sb_secret_... / service_role) is refused: it must never be
in the app, in GitHub or in a chat.
"""
import re
import sys
from pathlib import Path

PROD_REF = "qtspzigjlbtckqfyaubp"
ROOT = Path(__file__).resolve().parent.parent


def fail(msg):
    sys.exit("עצירה: " + msg)


def main():
    if len(sys.argv) != 3:
        fail("צריך שני ערכים: כתובת הפרויקט והמפתח הציבורי (publishable).")
    url, key = sys.argv[1].strip().rstrip("/"), sys.argv[2].strip()

    m = re.fullmatch(r"https://([a-z0-9]{20})\.supabase\.co", url)
    if not m:
        fail("כתובת הפרויקט לא בפורמט https://<20 אותיות וספרות>.supabase.co — כדאי להעתיק אותה שוב מ-Supabase.")
    if m.group(1) == PROD_REF:
        fail("זו הכתובת של הפרויקט האמיתי. גרסת הבדיקות חייבת להתחבר רק ל-Staging.")
    if key.startswith("sb_secret_") or "service_role" in key:
        fail("זה מפתח סודי. אסור להכניס אותו לאפליקציה. צריך את המפתח הציבורי (Publishable).")
    if not re.fullmatch(r"sb_publishable_[A-Za-z0-9_\-]{10,}", key):
        fail("המפתח לא נראה כמו מפתח ציבורי (sb_publishable_...).")

    html_path = ROOT / "index.html"
    html = html_path.read_text(encoding="utf-8")

    html, n_url = re.subn(r"var SUPABASE_URL = 'https://[a-z0-9]+\.supabase\.co';",
                          f"var SUPABASE_URL = '{url}';   // 🧪 STAGING", html)
    html, n_key = re.subn(r"var SUPABASE_KEY = 'sb_publishable_[A-Za-z0-9_\-]+';",
                          f"var SUPABASE_KEY = '{key}';   // 🧪 STAGING — מפתח ציבורי (publishable)", html)
    if n_url != 1 or n_key != 1:
        fail(f"לא נמצאו בדיוק פעם אחת כתובת ומפתח בקוד (כתובת: {n_url}, מפתח: {n_key}).")
    if PROD_REF in html:
        fail("נשאר בקוד אזכור של הפרויקט האמיתי.")

    html = html.replace("<title>חיים דרך מספרים</title>", "<title>🧪 בדיקות · חיים דרך מספרים</title>", 1)
    html = html.replace('content="חיים דרך מספרים">', 'content="🧪 בדיקות">')
    ribbon = ('<div id="hdm-staging-ribbon" style="position:fixed;top:0;left:0;right:0;z-index:100000;'
              'background:#7a2e8f;color:#fff;font:600 12px/1.9 Heebo,sans-serif;text-align:center;'
              'pointer-events:none;padding-top:env(safe-area-inset-top,0px)">'
              '🧪 סביבת בדיקות — לא האפליקציה האמיתית</div>\n')
    if 'id="hdm-staging-ribbon"' not in html:
        html = html.replace("<body>\n", "<body>\n" + ribbon, 1)
    html_path.write_text(html, encoding="utf-8")

    mf = ROOT / "manifest.webmanifest"
    if mf.exists():
        t = mf.read_text(encoding="utf-8")
        t = re.sub(r'"name"\s*:\s*"[^"]*"', '"name": "🧪 חיים דרך מספרים — בדיקות"', t)
        t = re.sub(r'"short_name"\s*:\s*"[^"]*"', '"short_name": "🧪 בדיקות"', t)
        mf.write_text(t, encoding="utf-8")

    print("✅ גרסת הבדיקות מוכנה ומחוברת ל-" + url)


if __name__ == "__main__":
    main()
