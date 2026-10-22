#!/usr/bin/env python3
# תצוגה מקדימה של PR #41 מול Production: משתמש בדיקה רגיל (לא מנהל) — אין כפתור "ניהול", והשרת מסרב. לא כותב נתונים.
import json, os
from playwright.sync_api import sync_playwright
SITE, EM, PW = os.environ['SITE'], os.environ['T_EM'], os.environ['T_PW']; out = {}
with sync_playwright() as p:
    br = p.chromium.launch(); pg = br.new_page(viewport={'width': 390, 'height': 844}); errs = []
    pg.on('pageerror', lambda e: errs.append(str(e)[:150]))
    pg.goto(SITE, wait_until='networkidle'); pg.wait_for_timeout(1500)
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
    pg.fill('#li-email', EM); pg.fill('#li-pass', PW); pg.click('#li-submit'); pg.wait_for_timeout(8000)
    out['session'] = pg.evaluate("async () => { try { const s = await window.__sb.auth.getSession(); return !!(s.data && s.data.session); } catch(e) { return false } }")
    out['has_admin_code'] = pg.evaluate("() => typeof window.hdmOpenAdmin === 'function'")
    out['am_i_admin'] = pg.evaluate("async () => { try { return await window.__hdmRpc('hdm_am_i_admin'); } catch(e) { return 'err:' + (e.message||e) } }")
    out['dashboard'] = pg.evaluate("async () => { try { await window.__hdmRpc('hdm_admin_dashboard', { p_include_tests: true }); return 'got-data'; } catch(e) { return String(e && e.message || e).slice(0, 60) } }")
    out['users'] = pg.evaluate("async () => { try { await window.__hdmRpc('hdm_admin_users', {}); return 'got-data'; } catch(e) { return String(e && e.message || e).slice(0, 60) } }")
    out['admin_row_hidden'] = pg.evaluate("() => { const g = document.getElementById('set-admin-group'); return !g || g.hidden; }")
    out['errors'] = errs; br.close()
print(json.dumps(out, ensure_ascii=False))
