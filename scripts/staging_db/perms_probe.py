# שמות הסודות בסביבה staging, ולכל טוקן של Supabase: אילו פרויקטים הוא רואה, והאם מותר לו לקרוא/לשנות הגדרות Auth של Staging.
# בדיקת הכתיבה היא PATCH ריק ({}) ל-Staging בלבד — לא משנה כלום. ערכים לא מודפסים. Production לא נבדק לכתיבה.
import json, os, urllib.request, urllib.error
ALL = json.loads(os.environ.get('ALL') or '{}'); S = os.environ['SREF']; P = os.environ['PREF']
def req(method, url, tok, body=None):
    r = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode(),
                               headers={'Authorization': 'Bearer ' + tok, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(r, timeout=25) as x: return x.status, x.read().decode()[:2000]
    except urllib.error.HTTPError as e: return e.code, e.read().decode()[:300]
    except Exception as e: return 0, type(e).__name__
names = sorted(k for k in ALL if k.lower() != 'github_token')
print('סודות בסביבה staging:', ', '.join(names) or '(אין)')
for k in names:
    v = (ALL[k] or '').strip()
    if v.startswith('postgres'): print(f'- {k}: כתובת מסד נתונים'); continue
    if not v.startswith('sbp_'): print(f'- {k}: לא טוקן Supabase (אורך {len(v)})'); continue
    c, b = req('GET', 'https://api.supabase.com/v1/projects', v)
    try: refs = ['staging' if p['id']==S else 'PRODUCTION' if p['id']==P else 'other' for p in json.loads(b)]
    except Exception: refs = [f'HTTP {c}']
    rc, _ = req('GET', f'https://api.supabase.com/v1/projects/{S}/config/auth', v)
    wc, wb = req('PATCH', f'https://api.supabase.com/v1/projects/{S}/config/auth', v, {})
    msg = ''
    try: msg = json.loads(wb).get('message', '')[:160]
    except Exception: pass
    print(f'- {k}: טוקן Supabase | פרויקטים: {",".join(refs)} | קריאת Auth ב-Staging: HTTP {rc} | כתיבת Auth ב-Staging (PATCH ריק): HTTP {wc} {msg}')
