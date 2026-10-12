#!/usr/bin/env python3
# =====================================================================
# בונה את index.html לפרסום מתוך staging.html (אותו קוד בדיוק), ומחליף רק את ההגדרות:
#   * כתובת הפרויקט הפעיל והמפתח הציבורי שלו (publishable — אותו מפתח שכבר נמצא היום ב-index.html)
#   * בלי פס "סביבת בדיקות" ובלי מסך הדבקת מפתח
#   * שם נפרד לשמירת ההתחברות בדפדפן
#   python3 scripts/release/make_release_index.py  →  index.html
# =====================================================================
import pathlib, re

ROOT = pathlib.Path(__file__).resolve().parents[2]
src = (ROOT / 'staging.html').read_text(encoding='utf-8')
PROD_URL = 'https://qtspzigjlbtckqfyaubp.supabase.co'
PROD_PUBLISHABLE_KEY = 'sb_publishable_wwoXFH3xChSfQxHKZEbTKA_t_u5aGMP'   # מפתח ציבורי (לא סוד) — כמו ב-index.html הנוכחי

def sub(old, new, text, count=1):
    assert text.count(old) == count, f'לא נמצא בדיוק {count}×: {old[:60]}'
    return text.replace(old, new)

out = src
out = sub("    // ===== גרסת בדיקות: מחוברת רק לפרויקט Haim Derech Misparim Staging =====\n",
          "    // ===== הגרסה הפעילה: מחוברת לפרויקט Haim Derech Misparim =====\n", out)
out = sub("var SUPABASE_URL = 'https://ousepgdvzammgkxkweze.supabase.co';", f"var SUPABASE_URL = '{PROD_URL}';", out)
out = sub("var STAGING_PUBLISHABLE_KEY = '';", f"var STAGING_PUBLISHABLE_KEY = '{PROD_PUBLISHABLE_KEY}';", out)
out = sub("try{ if(!SUPABASE_KEY) SUPABASE_KEY = localStorage.getItem('hdm_staging_publishable_key') || ''; }catch(e){}\n", "", out)
# בלי פס "סביבת בדיקות" ובלי מסך הדבקת מפתח
out, n = re.subn(r"    \(function stagingBanner\(\)\{.*?\n    \}\)\(\);\n", "", out, count=1, flags=re.S)
assert n == 1, 'לא נמצא stagingBanner'
out = sub("storageKey: 'hdm-stg-auth-session'", "storageKey: 'hdm-auth-session-v2'", out)
out = sub("var hasSaved = !!store.getItem('hdm-stg-auth-session');", "var hasSaved = !!store.getItem('hdm-auth-session-v2');", out)

assert 'ousepgdvzammgkxkweze' not in out, 'נשארה כתובת Staging'
assert 'סביבת בדיקות (Staging)' not in out, 'נשאר פס הבדיקות'
assert not re.search(r"sb_secret_[A-Za-z0-9_-]{8,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.", out), 'נמצא מפתח סודי / JWT בקובץ'
(ROOT / 'index.html').write_text(out, encoding='utf-8')
print('נוצר index.html מתוך staging.html (', len(out.splitlines()), 'שורות )')
