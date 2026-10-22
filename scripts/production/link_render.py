# מציג את דף Grow בדפדפן (iPhone, בלי הזנה, בלי חיוב) ומחזיר רק את הטקסט הגלוי ושדות הטופס — לקישור האמיתי ולקישור שגוי בכוונה.
import sys, json
from playwright.sync_api import sync_playwright
out = {}
with sync_playwright() as pw:
    br = pw.chromium.launch(); dev = pw.devices['iPhone 13']
    for label, url in [('real', sys.argv[1]), ('bad', sys.argv[2])]:
        c = br.new_context(**dev); pg = c.new_page()
        try:
            pg.goto(url, timeout=45000); pg.wait_for_timeout(7000)
            frames = [f for f in pg.frames]
            txt = ' '.join((f.evaluate("() => document.body ? document.body.innerText : ''") or '') for f in frames)
            inputs = sum(f.locator('input').count() for f in frames)
            out[label] = {'text': ' '.join(txt.split())[:260], 'inputs': inputs, 'frames': len(frames), 'url_ok': pg.url.startswith('https://')}
        except Exception as e:
            out[label] = {'error': str(e)[:200]}
        c.close()
    br.close()
print(json.dumps(out, ensure_ascii=False))
