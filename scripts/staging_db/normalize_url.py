#!/usr/bin/env python3
"""
חיים דרך מספרים — ניקוי כתובת החיבור ל-Staging (רץ רק בתוך run.sh).

קורא את הכתובת מהמשתנה HDM_RAW_URL (לא מארגומנט, כדי שלא תופיע ברשימת התהליכים).
מתקן רק טעויות הדבקה מוכרות: רווחים, מציין-המקום [YOUR-PASSWORD], וסיסמה שהודבקה
אחרי ה-@ ליד שם השרת. לא מנחש סיסמה — אם אין מועמד אחד ברור, מחזיר את הכתובת כמו שהיא.

פלט (stdout בלבד, שורה לכל ערך) — נקרא רק ע"י run.sh, לעולם לא מודפס ליומן:
  שורה 1: הסיסמה (כדי ש-run.sh יסתיר אותה ביומן לפני כל שימוש)
  שורה 2: META repaired=<0|1> leaked=<0|1> host_kind=<direct|pooler|other>
  שאר השורות: "<label>\t<url>" — כתובות מועמדות לחיבור, לפי הסדר
"""
import hashlib
import os
import re
import sys
from urllib.parse import quote

STAGING_REF = 'ousepgdvzammgkxkweze'
# טביעת SHA-256 של הסיסמה שנחשפה ב-13.10.2026 (לא הסיסמה עצמה) — כדי לדווח כן/לא אם עדיין בשימוש
LEAKED_SHA256 = 'c279ff3d6e592d38b40193642f7a503740a3c693c364f510cb6eac2997bf4668'
REGIONS = ['eu-central-1', 'eu-central-2', 'eu-west-1', 'eu-west-2', 'eu-west-3', 'eu-north-1',
           'us-east-1', 'us-east-2', 'us-west-1', 'us-west-2', 'ca-central-1', 'sa-east-1',
           'ap-south-1', 'ap-southeast-1', 'ap-southeast-2', 'ap-northeast-1', 'ap-northeast-2',
           'il-central-1', 'me-central-1']
PLACEHOLDER = re.compile(r'\[?YOUR[-_]PASSWORD\]?', re.I)


def main() -> int:
    raw = os.environ.get('HDM_RAW_URL', '')
    url = raw.strip()
    m = re.match(r'^(postgres(?:ql)?)://(.*)$', url, re.S)
    if not m:
        return 1
    rest = m.group(2)
    repaired = url != raw

    # השרת: הטוקן היחיד שמכיל supabase.co / supabase.com
    tokens = rest.split()
    host_tok = [t for t in tokens if re.search(r'supabase\.(co|com)', t)]
    if len(host_tok) != 1:
        return 1
    host_tok = host_tok[0]
    hostpart = host_tok.split('@')[-1]
    hm = re.match(r'^([A-Za-z0-9.-]+)(?::(\d+))?(?:/([^?\s]*))?(?:\?(.*))?$', hostpart)
    if not hm:
        return 1
    host, port, db = hm.group(1), hm.group(2) or '5432', hm.group(3) or 'postgres'

    # משתמש וסיסמה מהחלק שלפני ה-@ הראשון
    first = tokens[0]
    userinfo = first.split('@', 1)[0] if '@' in first else first
    user, _, pw = userinfo.partition(':')
    pw_clean = PLACEHOLDER.sub('', pw).strip('[]')
    if pw_clean != pw:
        repaired = True
    pw = pw_clean

    # טוקנים נוספים (לא החלק הראשון ולא השרת) — מועמדים לסיסמה שהודבקה במקום הלא נכון
    extra = []
    for t in tokens[1:]:
        if t is host_tok:
            continue
        t = PLACEHOLDER.sub('', t).strip('[]@')
        if t:
            extra.append(t)
    # וגם חלק לפני השרת באותו טוקן (למשל "PASSWORD@db....")
    if host_tok is not first and '@' in host_tok:
        t = PLACEHOLDER.sub('', host_tok.rsplit('@', 1)[0]).strip('[]@')
        if t:
            extra.append(t)
    if len(pw) < 4 and len(extra) == 1 and len(extra[0]) >= 8:
        pw = extra[0]
        repaired = True
    elif extra:
        return 1  # לא ברור מה הסיסמה — לא מנחשים

    if not user or not pw or STAGING_REF not in (host + user):
        return 1

    leaked = hashlib.sha256(pw.encode()).hexdigest() == LEAKED_SHA256
    kind = 'direct' if host == f'db.{STAGING_REF}.supabase.co' else (
        'pooler' if host.endswith('.pooler.supabase.com') else 'other')

    def mk(u, h, p):
        return f'postgresql://{quote(u, safe="")}:{quote(pw, safe="")}@{h}:{p}/{quote(db, safe="")}?sslmode=require'

    out = [pw, f'META repaired={int(repaired)} leaked={int(leaked)} host_kind={kind}']
    out.append(f'given\t{mk(user, host, port)}')
    if kind == 'direct':  # שרתי GitHub בלי IPv6 — מנסים גם את ה-Pooler (Session, פורט 5432)
        for pre in ('aws-0', 'aws-1'):
            for r in REGIONS:
                out.append(f'pooler {pre}-{r}\t{mk("postgres." + STAGING_REF, f"{pre}-{r}.pooler.supabase.com", 5432)}')
    sys.stdout.write('\n'.join(out) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
