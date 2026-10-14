# =====================================================================
# חיים דרך מספרים — בדיקת דפדפן ללוח הניהול (admin-staging.html) מול פרויקט Staging
#
# * שני משתמשי בדיקה זמניים נוצרים במסד: מנהלת ומשתמש רגיל (‎hdm-adm-<ריצה>-*@example.invalid).
#   בסוף — ובכל מקרה של כישלון — הם נמחקים, ובודקים שלא נשאר כלום.
# * מסך אייפון (390×844), supabase-js האמיתית ושרת ה-Auth האמיתי של Staging.
# * פילוח גיל ומין נבדק גם במנוע של ספארי (WebKit, פרופיל iPhone 13).
# משתני סביבה: STAGING_DB_URL (סוד), PAGE (נתיב ל-admin-staging.html)
# =====================================================================
import os, random, string, subprocess, sys, json, http.server, threading, functools
from playwright.sync_api import sync_playwright

STG = 'https://ousepgdvzammgkxkweze.supabase.co'
DB = os.environ['STAGING_DB_URL']
PAGE = os.environ.get('PAGE', 'admin-staging.html')
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'adm{RUN}_'
MAIL = f'hdm-adm-{RUN}-'
PW = 'Adm-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(20))
SHOTS = '/tmp/hdm-shots'; os.makedirs(SHOTS, exist_ok=True)

def sql(q):
    r = subprocess.run(['psql', DB, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError('SQL נכשל: ' + (r.stderr.strip().splitlines()[-1][:200] if r.stderr.strip() else ''))
    return r.stdout.strip()

CRYPT = 'extensions.crypt' if sql("select count(*) from pg_proc where proname='crypt' and pronamespace='extensions'::regnamespace") != '0' else 'crypt'
SALT = CRYPT.replace('crypt', 'gen_salt')
PEOPLE = {'admin': ('מנהלת בדיקה', 'אישה', 'plus'), 'user': ('משתמש בדיקה', 'גבר', None)}
IDS = {k: PFX + k for k in PEOPLE}
results = []

AGE_SQL = """
with b as (
  select case when lower(coalesce(p.data->>'gender','')) in ('גבר','זכר','male','m','man') then 'male'
              when lower(coalesce(p.data->>'gender','')) in ('אישה','אשה','נקבה','female','f','woman') then 'female'
              else 'other' end g,
         extract(year from age((now() at time zone 'Asia/Jerusalem')::date, pp.birthdate))::int a
    from public.docs p left join public.hdm_profile_private pp on pp.profile_id = p.id
   where p.collection = 'profiles' and pp.birthdate is not null),
t as (select g, case when a < 18 then null when a < 25 then '18-24' when a < 35 then '25-34' when a < 45 then '35-44'
                     when a < 55 then '45-54' when a < 65 then '55-64' else '65+' end k from b)
select k, count(*) filter (where g='male'), count(*) filter (where g='female'), count(*) from t where k is not null group by k"""
AGE_KEYS = ['18-24', '25-34', '35-44', '45-54', '55-64', '65+']

def db_ages():
    out = {k: (0, 0, 0) for k in AGE_KEYS}
    for line in filter(None, sql(AGE_SQL).splitlines()):
        k, m, f, t = line.split('|'); out[k] = (int(m), int(f), int(t))
    return out

def ui_table(pg):
    rows = pg.eval_on_selector_all('#ag-table tbody tr', "trs => trs.map(tr => Array.from(tr.children).map(td => td.textContent.trim()))")
    return {r[0].replace('–', '-'): [int(x.replace(',', '')) for x in r[1:]] for r in rows}

def check_ages(pg, tag):
    pg.wait_for_function("() => document.querySelectorAll('#ag-table tbody tr').length > 0", timeout=15000)
    exp = db_ages(); got = ui_table(pg)
    has_other = pg.evaluate("() => !document.querySelector('#ag-table thead th[data-c=other]').classList.contains('hidden')")
    norm = {k: [v[0], v[1], v[-1]] for k, v in got.items()}   # גברים, נשים, סך (בלי עמודת "אחר" אם מוצגת)
    check(f'{tag}: גיל ומין — שישה טווחים, גברים/נשים/סך זהים למסד', list(got) == AGE_KEYS and all(norm[k] == list(exp[k]) for k in AGE_KEYS), f'{norm} vs {exp}')
    check(f'{tag}: בגרף שורה לכל טווח עם הסך הנכון',
          pg.eval_on_selector_all('#ag-chart .ag-row', "rs => rs.map(r => r.dataset.key + ':' + r.querySelector('.n').textContent.replace(/,/g,''))")
          == [f'{k}:{exp[k][2]}' for k in AGE_KEYS])
    # סינון מין: נשים
    pg.click('#ag-gender button[data-g=female]'); pg.wait_for_timeout(150)
    fem = ui_table(pg)
    check(f'{tag}: סינון "נשים" — טבלה בעמודה אחת עם מספר הנשים בכל טווח', all(fem[k] == [exp[k][1]] for k in AGE_KEYS), fem)
    sm = int(pg.inner_text('#ag-sum b').replace(',', ''))
    check(f'{tag}: סינון "נשים" — הסיכום = סך הנשים בכל הטווחים', sm == sum(exp[k][1] for k in AGE_KEYS), sm)
    # סינון גיל: 25–34 בלבד, ואז הוספת 35–44
    pg.click('#ag-ages button[data-a="25-34"]'); pg.wait_for_timeout(150)
    one = ui_table(pg)
    check(f'{tag}: סינון גיל 25–34 + נשים — מוצג רק הטווח הזה', list(one) == ['25-34'] and one['25-34'] == [exp['25-34'][1]], one)
    pg.click('#ag-ages button[data-a="35-44"]'); pg.wait_for_timeout(150)
    two = ui_table(pg); sm2 = int(pg.inner_text('#ag-sum b').replace(',', ''))
    check(f'{tag}: בחירת שני טווחים — סיכום = סכום שניהם', list(two) == ['25-34', '35-44'] and sm2 == exp['25-34'][1] + exp['35-44'][1], f'{two} {sm2}')
    pg.click('#ag-gender button[data-g=male]'); pg.wait_for_timeout(150)
    sm3 = int(pg.inner_text('#ag-sum b').replace(',', ''))
    check(f'{tag}: אותם טווחים + גברים — סיכום = גברים בשני הטווחים', sm3 == exp['25-34'][0] + exp['35-44'][0], sm3)
    pg.screenshot(path=f'{SHOTS}/ages-{tag}-filtered.png', full_page=True)
    pg.click('#ag-ages button[data-a=all]'); pg.click('#ag-gender button[data-g=all]'); pg.wait_for_timeout(150)
    check(f'{tag}: "כל הגילאים" + "כולם" מחזיר את התצוגה המלאה', list(ui_table(pg)) == AGE_KEYS)
    body = pg.inner_text('body')
    check(f'{tag}: אין בדף אימיילים, שמות או תאריכי לידה', '@' not in body and 'מנהלת בדיקה' not in body and '1988-05-05' not in body and '05/05/1988' not in body)
    check(f'{tag}: מותאם לאייפון — בלי גלילה לרוחב', pg.evaluate("() => document.documentElement.scrollWidth <= window.innerWidth + 1"))
    small = pg.evaluate("() => Array.from(document.querySelectorAll('#ag button')).filter(b => b.getBoundingClientRect().height < 36).length")
    check(f'{tag}: כפתורי הסינון בגודל נוח למגע', small == 0, small)
    pg.locator('#ag').screenshot(path=f'{SHOTS}/ages-{tag}.png')

def check(name, ok, got=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  -> {str(got)[:160]}'), flush=True)

def create_people():
    for k, (name, gender, plan) in PEOPLE.items():
        pid, email = IDS[k], f'{MAIL}{k}@example.invalid'
        prof = json.dumps({'currentName': name, 'gender': gender, 'lookingFor': 'נשים' if gender == 'גבר' else 'גברים',
                           'birthdate': '1988-05-05', 'birthFirstName': 'בדיקה', 'birthLastName': 'בדיקה',
                           'location': 'תל אביב', 'photoUrl': 'data:image/png;base64,iVBORw0KGgo='}, ensure_ascii=False)
        sql(f"""begin;
          with u as (
            insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                                    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                                    confirmation_token, recovery_token, email_change_token_new, email_change)
            values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', '{email}',
                    {CRYPT}('{PW}', {SALT}('bf')), now(), '{{"provider":"email","providers":["email"]}}', '{{}}', now(), now(), '', '', '', '')
            returning id)
          , i as (insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
                  select gen_random_uuid(), u.id::text, u.id, jsonb_build_object('sub', u.id::text, 'email', '{email}', 'email_verified', true), 'email', now(), now(), now() from u)
          insert into public.hdm_accounts (auth_user_id, profile_id) select id, '{pid}' from u;
          insert into public.docs (collection, id, data) values ('profiles', '{pid}', $j${prof}$j$::jsonb);
          commit;""")
        if plan: sql(f"select public.hdm_admin_set_plan('{pid}', '{plan}', 30, 'e2e-admin')")
    sql(f"select public.hdm_admin_grant('{MAIL}admin@example.invalid')")

def cleanup():
    ids = "array[" + ",".join(f"'{v}'" for v in IDS.values()) + "]"
    sql(f"""begin;
      delete from public.docs where collection='profiles' and id = any({ids});
      delete from public.hdm_profile_private where profile_id = any({ids});
      delete from public.hdm_subscription_events where profile_id = any({ids});
      delete from public.hdm_subscriptions where profile_id = any({ids});
      delete from public.hdm_accounts where profile_id = any({ids});
      delete from auth.users where email like '{MAIL}%@example.invalid';
      commit;""")
    return sql(f"""select (select count(*) from auth.users where email like '{MAIL}%')
                    + (select count(*) from public.hdm_admins a where not exists (select 1 from auth.users u where u.id = a.auth_user_id))
                    + (select count(*) from public.docs where id like '%{PFX}%')
                    + (select count(*) from public.hdm_subscriptions where profile_id like '{PFX}%')""")

html_dir = os.path.dirname(os.path.abspath(PAGE))
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=html_dir))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()
URL = f'http://127.0.0.1:{srv.server_address[1]}/{os.path.basename(PAGE)}'
seen_hosts, errors = set(), []

def login(pg, k):
    pg.fill('#em', f'{MAIL}{k}@example.invalid'); pg.fill('#pw', PW); pg.click('#login-btn')
    pg.wait_for_function("() => ['dash','denied'].some(id => !document.getElementById(id).classList.contains('hidden')) || document.getElementById('login-err').textContent", timeout=20000)
    pg.wait_for_timeout(300)

def visible(pg, id):
    return pg.evaluate(f"() => !document.getElementById('{id}').classList.contains('hidden')")

print(f'ריצה {RUN}', flush=True)
exit_code = 1
try:
    create_people()
    with sync_playwright() as p:
        br = p.chromium.launch()
        ctx = br.new_context(viewport={'width': 390, 'height': 844}, device_scale_factor=2, is_mobile=True, has_touch=True, locale='he-IL')
        pg = ctx.new_page(); pg.on('pageerror', lambda e: errors.append(str(e))); pg.on('request', lambda r: seen_hosts.add(r.url.split('/')[2]))
        pg.goto(URL); pg.wait_for_timeout(2000)

        check('בלי התחברות: מוצג מסך כניסה, לא נתונים', visible(pg, 'login') and not visible(pg, 'dash'))
        anon = pg.evaluate("async () => { const r = await sb.rpc('hdm_admin_dashboard'); return r.error ? 'blocked' : 'DATA'; }")
        anon2 = pg.evaluate("async () => { const r = await sb.rpc('hdm_admin_age_gender'); return r.error ? 'blocked' : 'DATA'; }")
        check('אורח: קריאה ישירה לפילוח גיל ומין נחסמת', anon2 == 'blocked', anon2)
        check('אורח: קריאה ישירה ל-API של הלוח נחסמת', anon == 'blocked', anon)

        login(pg, 'user')
        check('משתמש רגיל: מוצג "אינו מורשה", בלי נתונים', visible(pg, 'denied') and not visible(pg, 'dash'))
        direct = pg.evaluate("async () => { const r = await sb.rpc('hdm_admin_dashboard'); return r.error ? (r.error.message || 'blocked') : 'DATA'; }")
        check('משתמש רגיל: קריאה ישירה ל-API נחסמת בשרת (HDM_NOT_ADMIN)', 'HDM_NOT_ADMIN' in direct, direct)
        direct2 = pg.evaluate("async () => { const r = await sb.rpc('hdm_admin_age_gender'); return r.error ? (r.error.message || 'blocked') : 'DATA'; }")
        check('משתמש רגיל: פילוח גיל ומין נחסם בשרת (HDM_NOT_ADMIN)', 'HDM_NOT_ADMIN' in direct2, direct2)
        tbl = pg.evaluate("async () => { const r = await sb.from('hdm_admins').select('*'); return r.error ? 'blocked' : (r.data || []).length; }")
        check('משתמש רגיל: אין גישה לרשימת המנהלים', tbl in ('blocked', 0), tbl)
        grant = pg.evaluate(f"async () => {{ const r = await sb.rpc('hdm_admin_grant', {{ p_email: '{MAIL}user@example.invalid' }}); return r.error ? 'blocked' : 'GRANTED'; }}")
        check('משתמש רגיל: לא יכול להפוך את עצמו למנהל', grant == 'blocked', grant)
        pg.evaluate("async () => { await sb.auth.signOut(); }"); pg.goto(URL); pg.wait_for_timeout(1500)

        login(pg, 'admin')
        check('מנהלת: הלוח מוצג', visible(pg, 'dash'))
        total_ui = pg.inner_text('#u-total').replace(',', '').strip()
        total_db = sql("select count(*) from public.docs where collection='profiles'")
        check('סך המשתמשים בלוח = מספר הפרופילים במסד', total_ui == total_db, f'{total_ui} vs {total_db}')
        plans_ui = pg.eval_on_selector_all('#plans .tile', "els => els.map(e => e.children[0].textContent + ':' + e.children[2].textContent)")
        check('ארבעה מסלולים עם המחירים', plans_ui == ['חינם:₪0.00 לחודש', 'בסיסי:₪29.90 לחודש', 'פלוס:₪48.90 לחודש', 'VIP:₪79.90 לחודש'], plans_ui)
        plus_ui = int(pg.inner_text('#plans .tile:nth-child(3) .v').replace(',', ''))
        plus_db = int(sql("select count(*) from public.docs p where p.collection='profiles' and public.hdm_plan_of(p.id)='plus'"))
        check('מספר מנויי פלוס בלוח = במסד', plus_ui == plus_db, f'{plus_ui} vs {plus_db}')
        check('הכנסות: לא מוצג מספר מומצא (אין מערכת תשלום)', pg.inner_text('#r-total') == 'אין נתונים' and visible(pg, 'r-note'), pg.inner_text('#r-total'))
        body = pg.inner_text('body')
        check('אין בדף אימיילים או שמות של משתמשים', '@' not in body and 'מנהלת בדיקה' not in body and 'משתמש בדיקה' not in body)
        check('הדף מותאם לאייפון (בלי גלילה לרוחב)', pg.evaluate("() => document.documentElement.scrollWidth <= window.innerWidth + 1"))
        check_ages(pg, 'Chromium')
        # ספארי (WebKit) בפרופיל iPhone 13
        wk = p.webkit.launch()
        wctx = wk.new_context(**p.devices['iPhone 13'], locale='he-IL')
        wp = wctx.new_page(); wp.on('pageerror', lambda e: errors.append('webkit: ' + str(e)))
        wp.goto(URL); wp.wait_for_timeout(2000)
        login(wp, 'admin')
        check('iPhone (WebKit): הלוח מוצג למנהלת', visible(wp, 'dash'))
        check_ages(wp, 'iPhone')
        wp.screenshot(path=f'{SHOTS}/admin-iphone-webkit-full.png', full_page=True)
        wk.close()
        pg.screenshot(path=f'{SHOTS}/admin-iphone-top.png')
        pg.screenshot(path=f'{SHOTS}/admin-iphone-full.png', full_page=True)

        sql(f"select public.hdm_admin_revoke('{MAIL}admin@example.invalid')")
        pg.click('text=↻ רענון'); pg.wait_for_timeout(2500)
        check('אחרי הסרת ההרשאה: רענון מציג "אינו מורשה"', visible(pg, 'denied') and not visible(pg, 'dash'))

        check('אין שגיאות JavaScript בדף', not errors, errors[:2])
        check('הדף פנה רק ל-Staging (לא לפרויקט הפעיל)', not any('qtspzigjlbtckqfyaubp' in h for h in seen_hosts), sorted(seen_hosts))
        br.close()
    exit_code = 0 if all(results) else 1
except Exception as e:
    print('FAIL שגיאה כללית: ' + str(e)[:300], flush=True); exit_code = 1
finally:
    try:
        left = cleanup(); print(f'ניקוי: נשארו {left} רשומות בדיקה', flush=True)
        if left != '0': exit_code = 1
    except Exception as e:
        print('FAIL ניקוי: ' + str(e)[:200], flush=True); exit_code = 1
    print(f'SUMMARY {sum(results)}/{len(results)} passed', flush=True)
    sys.exit(exit_code)
