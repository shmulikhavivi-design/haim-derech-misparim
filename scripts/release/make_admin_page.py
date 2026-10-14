#!/usr/bin/env python3
# בונה את admin.html (Production) מתוך admin-staging.html — אותו קוד בדיוק, ומחליף רק את ההגדרות.
#   python3 scripts/release/make_admin_page.py  →  admin.html
import pathlib
ROOT = pathlib.Path(__file__).resolve().parents[2]
src = (ROOT / 'admin-staging.html').read_text(encoding='utf-8')
def sub(old, new, text):
    assert text.count(old) == 1, f'לא נמצא בדיוק פעם אחת: {old[:60]}'
    return text.replace(old, new)
out = src
out = sub("  // ===== הגדרות: פרויקט Staging =====", "  // ===== הגדרות: הפרויקט הפעיל (Production) =====", out)
out = sub("var SUPABASE_URL = 'https://ousepgdvzammgkxkweze.supabase.co';", "var SUPABASE_URL = 'https://qtspzigjlbtckqfyaubp.supabase.co';", out)
out = sub("var SUPABASE_KEY = 'sb_publishable_UXJrkbmi6h3j3Yvaey5Nvw_HIDJOy40';", "var SUPABASE_KEY = 'sb_publishable_wwoXFH3xChSfQxHKZEbTKA_t_u5aGMP';", out)
out = sub("var STORAGE_KEY  = 'hdm-stg-auth-session';", "var STORAGE_KEY  = 'hdm-auth-session-v2';", out)
out = sub("var ENV_LABEL    = 'Staging';", "var ENV_LABEL    = '';", out)
out = sub('<span class="env" id="env-tag">Staging</span>', '<span class="env hidden" id="env-tag"></span>', out)
assert 'ousepgdvzammgkxkweze' not in out and 'UXJrkbmi6h3j3Yvaey5Nvw' not in out, 'נשארה הגדרת Staging'
(ROOT / 'admin.html').write_text(out, encoding='utf-8')
print('נוצר admin.html (Production) מתוך admin-staging.html')
