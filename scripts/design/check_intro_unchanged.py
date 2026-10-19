#!/usr/bin/env python3
# בדיקה סטטית: מסך הפתיחה (#intro-screen) זהה ל-main — ה-HTML שלו וכל כללי ה-CSS שהבורר שלהם נוגע בו.
# שימוש: python3 scripts/design/check_intro_unchanged.py <main/staging.html> <branch/staging.html>
import re, sys, hashlib

def intro_html(s):
    a = s.index('<div class="intro" id="intro-screen">')
    depth, i = 0, a
    for m in re.finditer(r'<div\b|</div>', s[a:]):
        depth += 1 if m.group(0) == '<div' else -1
        if depth == 0:
            return s[a:a + m.end()]
    raise SystemExit('intro block not closed')

def intro_css(s):
    rules = []
    for block in re.findall(r'<style[^>]*>(.*?)</style>', s, re.S):
        block = re.sub(r'/\*.*?\*/', '', block, flags=re.S)
        for sel, body in re.findall(r'([^{}]+)\{([^{}]*)\}', block):
            sel = ' '.join(sel.split())
            if re.search(r'intro', sel) and not sel.startswith('html:has(#intro-screen.intro-hide)'):
                rules.append(sel + '{' + ' '.join(body.split()) + '}')
    return rules

main, branch = (open(p, encoding='utf-8').read() for p in sys.argv[1:3])
h1, h2 = intro_html(main), intro_html(branch)
c1, c2 = intro_css(main), intro_css(branch)
ok = True
print('intro HTML  sha256 main=%s branch=%s' % (hashlib.sha256(h1.encode()).hexdigest()[:12], hashlib.sha256(h2.encode()).hexdigest()[:12]))
if h1 != h2: ok = False; print('FAIL intro HTML changed')
if c1 != c2:
    ok = False; print('FAIL intro CSS changed:'); [print('  -', r[:160]) for r in set(c1) ^ set(c2)]
print('intro CSS rules: %d (main) / %d (branch)' % (len(c1), len(c2)))
# המשתנים הגלובליים (--bg וכו') לא משמשים את מסך הפתיחה
if re.search(r'var\(--', ' '.join(c2)): ok = False; print('FAIL intro CSS uses shared variables')
print('PASS מסך הפתיחה זהה ל-main' if ok else 'FAIL')
sys.exit(0 if ok else 1)
