# =====================================================================
# חיים דרך מספרים — בדיקת דפדפן מול Staging בלבד: תיקון סינון הגילאים (26.10).
# טווח הגילאים מחייב בכל המסלולים ובשני הכיוונים, לנשים ולגברים; אין "הרחבה" שעוקפת; כרטיס שכבר נטען לא עוקף;
# שינוי טווח בטופס נשמר במסד ומיושם מיד; כשאין התאמות — הודעה עם הטווח וכפתור לשינוי. משתמשי בדיקה נמחקים בסוף. בלי חיובים.
# =====================================================================
import json, os, random, string, subprocess, sys, http.server, threading, functools
from playwright.sync_api import sync_playwright

DB = os.environ['STAGING_DB_URL']; KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', ''); PAGE = os.environ['PAGE_NEW']
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'ag{RUN}_'; MAIL = f'hdm-agefix-{RUN}-'; DOM = 'example.invalid'
PW = 'Ag-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(18)) + '1!'
if not KEY.startswith('sb_publishable_'): print('⛔ no publishable key'); sys.exit(2)

def sql(q):
    r = subprocess.run(['psql', DB, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q], capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError('sql: ' + r.stderr.strip()[:200])
    return r.stdout.strip()
results = []
def check(name, ok, got=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {str(got)[:300]}'), flush=True)

CRYPT = 'extensions.crypt' if sql("select count(*) from pg_proc where proname='crypt' and pronamespace='extensions'::regnamespace") != '0' else 'crypt'
SALT = CRYPT.replace('crypt', 'gen_salt')
REQ = sql("select public.hdm_required_terms_version()")

def make_user(tag, gender, looking, birth, first, last, age, amin, amax):
    pid, email = PFX + tag, f'{MAIL}{tag}@{DOM}'
    profile = json.dumps({'currentName': 'בדיקה ' + tag, 'birthdate': birth, 'birthFirstName': first, 'birthLastName': last, 'gender': gender,
                          'lookingFor': looking, 'age': str(age), 'ageMin': str(amin), 'ageMax': str(amax), 'location': 'חיפה',
                          'maritalStatus': 'רווק/ה', 'hasChildren': 'לא', 'smoking': 'לא',
                          'photoUrl': 'data:image/png;base64,iVBORw0KGgo=', 'createdAt': 0}, ensure_ascii=False)
    sql(f"""begin;
      with u as (
        insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                                created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
        values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', '{email}', {CRYPT}('{PW}', {SALT}('bf')), now(),
                '{{"provider":"email","providers":["email"]}}', '{{}}', now(), now(), '', '', '', '') returning id)
      , i as (insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
              select gen_random_uuid(), u.id::text, u.id, jsonb_build_object('sub', u.id::text, 'email', '{email}', 'email_verified', true), 'email', now(), now(), now() from u)
      , a as (insert into public.hdm_accounts (auth_user_id, profile_id) select id, '{pid}' from u)
      insert into public.hdm_consents (user_id, profile_id, version, source) select id, '{pid}', '{REQ}', 'signup' from u;
      insert into public.docs (collection, id, data) values ('profiles', '{pid}', $j${profile}$j$::jsonb);
      commit;""")
    return pid, email

def cleanup():
    sql(f"""begin;
      do $d$ declare t text; begin
        foreach t in array array['hdm_subscription_events','hdm_chat_openings','hdm_subscriptions','hdm_hidden_profiles','hdm_profile_private'] loop
          if to_regclass('public.' || t) is not null and exists (select 1 from information_schema.columns where table_schema='public' and table_name=t and column_name='profile_id') then
            execute format('delete from public.%I where profile_id like %L', t, '{PFX}%');
          end if; end loop; end $d$;
      delete from public.docs where id like '{PFX}%' or data::text like '%{PFX}%';
      delete from public.hdm_consents where user_id in (select id from auth.users where email like '{MAIL}%');
      delete from public.hdm_accounts where auth_user_id in (select id from auth.users where email like '{MAIL}%');
      delete from auth.users where email like '{MAIL}%'; commit;""")
    return sql(f"select (select count(*) from auth.users where email like '{MAIL}%') + (select count(*) from public.docs where id like '{PFX}%')")

def serve(page):
    d = os.path.dirname(os.path.abspath(page))
    s = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=d))
    s.RequestHandlerClass.log_message = lambda *a: None; threading.Thread(target=s.serve_forever, daemon=True).start()
    return f'http://127.0.0.1:{s.server_address[1]}/{os.path.basename(page)}'

errors = []
def newpage(br):
    c = br.new_context(viewport={'width': 390, 'height': 844})
    c.add_init_script(f"try{{ localStorage.setItem('hdm_staging_publishable_key', {json.dumps(KEY)}); }}catch(e){{}}")
    pg = c.new_page(); pg.on('pageerror', lambda e: errors.append(str(e)[:200])); return c, pg

def login(pg, app, email):
    pg.goto(app, wait_until='networkidle'); pg.wait_for_timeout(1200)
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
    pg.fill('#li-email', email); pg.fill('#li-pass', PW); pg.click('#li-submit')
    try: pg.wait_for_function("() => myId", timeout=20000)
    except Exception: pass
    try: pg.wait_for_function("() => hdmEnt && hdmEnt.forId === myId && !hdmEnt.error", timeout=15000)
    except Exception: pass
    pg.wait_for_timeout(1500)

def st(pg):
    for _ in range(12):
        if pg.evaluate("() => matchQueue !== null && matchQueueFor === myId"): break
        pg.wait_for_timeout(1000)
    pg.wait_for_timeout(1200)
    return pg.evaluate("""() => {
      const me = myProfile || {}, mn = parseInt(me.ageMin,10), mx = parseInt(me.ageMax,10), myAge = hdmAgeOf(me);
      const q = (matchQueue||[]);
      const bad = q.filter(e => { const a = hdmAgeOf(e.data), d = e.data||{}, omn = parseInt(d.ageMin,10), omx = parseInt(d.ageMax,10);
        return (a !== null && ((mn>0 && a<mn) || (mx>0 && a>mx))) || (myAge !== null && ((omn>0 && myAge<omn) || (omx>0 && myAge>omx))); }).map(e => e.id);
      return { ids: q.map(e => e.id), n: q.length, bad, relaxed: !!matchQueueRelaxed, plan: hdmPlanId(),
        why: document.getElementById('match-why').textContent.trim(), btn: !!document.getElementById('hdm-age-range-btn'),
        age: document.getElementById('match-age').textContent.trim(), cur: currentMatchId || null }; }""")

print(f'ריצה {RUN}', flush=True)
code = 1
try:
    W1, w1m = make_user('w1', 'אישה', 'גברים', '1990-03-03', 'נועה', 'כ', 36, 30, 43)   # כמו המשתמשת שדיווחה
    W4, w4m = make_user('w4', 'אישה', 'גברים', '1990-04-04', 'מיכל', 'ש', 36, 30, 43)   # אותו דבר במסלול פלוס
    W2, w2m = make_user('w2', 'אישה', 'גברים', '1976-02-02', 'רות', 'ל', 50, 49, 54)    # אין לה אף גבר בטווח
    W3, w3m = make_user('w3', 'אישה', 'גברים', '2001-02-02', 'דנה', 'ט', 25, 20, 30)
    M22, m22m = make_user('m22', 'גבר', 'נשים', '2004-01-01', 'יוסי', 'א', 22, 19, 30)  # כמו הגבר בן 22
    M36, m36m = make_user('m36', 'גבר', 'נשים', '1990-05-05', 'דוד', 'מ', 36, 30, 45)
    M40, m40m = make_user('m40', 'גבר', 'נשים', '1986-06-06', 'אבי', 'ר', 40, 20, 30)
    for pid, pl in [(W4, 'plus'), (M36, 'basic')]: sql(f"select public.hdm_admin_set_plan('{pid}', '{pl}')")
    APP = serve(PAGE)
    EXPECT = {  # מי חייב להופיע / אסור שיופיע (מתוך משתמשי הבדיקה)
        'w1':  (w1m,  'חינם',  [M36], [M22, M40]),
        'w4':  (w4m,  'פלוס',  [M36], [M22, M40]),
        'w3':  (w3m,  'חינם',  [M22], [M36, M40]),
        'm22': (m22m, 'חינם',  [W3], [W1, W4, W2]),
        'm36': (m36m, 'בסיסי', [W1, W4], [W3, W2]),
        'm40': (m40m, 'חינם',  [], [W1, W4, W2, W3]),
        'w2':  (w2m,  'חינם',  [], [M22, M36, M40]),
    }
    with sync_playwright() as pw_:
        br = pw_.chromium.launch()
        for tag, (mail, plan, must, never) in EXPECT.items():
            c, pg = newpage(br); login(pg, APP, mail); s = st(pg)
            check(f'{tag} ({plan}): מוצגים בדיוק מי שבטווח בשני הכיוונים', all(x in s['ids'] for x in must), [must, s['ids']])
            check(f'{tag} ({plan}): לא מוצג אף פרופיל מחוץ לטווח (גם לא בהרחבה)', not any(x in s['ids'] for x in never) and not s['relaxed'], s)
            check(f'{tag} ({plan}): כל הכרטיסים בתור (כולל משתמשי Staging אחרים) בטווח בשני הכיוונים', not s['bad'], s['bad'])
            if tag == 'w2':
                check('אין התאמות: הודעה עם הטווח 49–54 וכפתור לשינוי (לא מסך ריק)', s['n'] > 0 or ('49–54' in s['why'] and s['btn']), s)
                if s['n'] == 0:
                    pg.click('#hdm-age-range-btn', force=True); pg.wait_for_timeout(2000)
                    check('הכפתור פותח את עריכת הפרופיל עם הטווח השמור', pg.evaluate("() => hdmIsActive('screen-profile')") and pg.input_value('#pf-agemin') == '49' and pg.input_value('#pf-agemax') == '54',
                          pg.evaluate("() => [hdmIsActive('screen-profile'), document.getElementById('pf-agemin').value, document.getElementById('pf-agemax').value]"))
            if tag == 'w1':
                # כרטיס שכבר נטען / הוזרק לתור לא עוקף את הסינון
                pg.evaluate("""(id) => { matchQueue.unshift({ id: id, data: { gender: 'גבר', lookingFor: 'נשים', age: '22', ageMin: '19', ageMax: '30', lifePathNumber: 3, currentName: 'x' } }); showCardAt(0); }""", M22)
                pg.wait_for_timeout(500)
                s2 = pg.evaluate("() => ({ ids: matchQueue.map(e => e.id), cur: currentMatchId })")
                check('w1: פרופיל מחוץ לטווח שהוכנס לתור שכבר נטען — מוסר לפני הצגה', M22 not in s2['ids'] and s2['cur'] != M22, s2)
                # שמירת טווח חדש בטופס → נשמר במסד ומיושם מיד (36 כבר לא בטווח 37–43)
                pg.evaluate("() => openMyProfile()"); pg.wait_for_timeout(2500)
                pg.fill('#pf-agemin', '37'); pg.fill('#pf-agemax', '43'); pg.click('#profile-save-btn', force=True); pg.wait_for_timeout(3500)
                saved = sql(f"select (data->>'ageMin') || '-' || (data->>'ageMax') from public.docs where collection='profiles' and id='{W1}'")
                check('w1: שינוי הטווח בטופס נשמר במסד (37–43)', saved == '37-43', [saved, pg.evaluate("() => document.getElementById('profile-status') ? document.getElementById('profile-status').textContent : ''")])
                pg.evaluate("() => { go('screen-match'); loadNextMatch(); }"); s3 = st(pg)
                check('w1: אחרי השמירה הסינון מתעדכן מיד (בן 36 כבר לא מוצג, בלי רענון)', M36 not in s3['ids'] and not s3['bad'], s3)
                pg.reload(wait_until='networkidle'); pg.wait_for_timeout(3000); s4 = st(pg)
                check('w1: אחרי רענון — אותו טווח, אותה תוצאה', M36 not in s4['ids'] and M22 not in s4['ids'] and not s4['bad'], s4)
            c.close()
        check('אין שגיאות JavaScript בדף', not errors, errors[:3])
        br.close()
    code = 0 if all(results) else 1
except Exception as e:
    print('ERROR', str(e)[:400]); code = 1
finally:
    left = cleanup()
    print(f'ניקוי: נשארו {left} רשומות בדיקה')
    print(f'SUMMARY {sum(results)}/{len(results)} עברו')
sys.exit(code)
