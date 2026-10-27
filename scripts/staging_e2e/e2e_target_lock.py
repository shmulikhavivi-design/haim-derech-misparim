# =====================================================================
# חיים דרך מספרים — בדיקה מול Staging בלבד: ביטול התראות מול מסירה בו-זמנית (נעילת משתמש לאורך המסירה).
# דפדפן (staging.html) + פונקציית השליחה hdm-target-mailer שפרוסה ב-Staging עם מפתח Brevo לא תקף בכוונה —
# כך שום מייל לא יוצא (Brevo דוחה), וגם כתובות הבדיקה הן @example.invalid. משתמשי הבדיקה נמחקים בסוף ובכל כישלון.
# =====================================================================
import concurrent.futures, json, os, time, random, string, subprocess, sys, http.server, threading, functools, urllib.request, urllib.error

DB = os.environ['STAGING_DB_URL']; KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', ''); PAGE = os.environ['PAGE_NEW']
FN = 'https://ousepgdvzammgkxkweze.supabase.co/functions/v1/hdm-target-mailer'; CRON = os.environ.get('HDM_CRON_SECRET', '')
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'tl{RUN}_'; MAIL = f'hdm-targetlock-{RUN}-'; DOM = 'example.invalid'
PW = 'Fl-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(18)) + '1!'
if not KEY.startswith('sb_publishable_'): print('⛔ no publishable key'); sys.exit(2)

def sql(q):
    r = subprocess.run(['psql', DB, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q], capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError('sql: ' + r.stderr.strip()[:200])
    return r.stdout.strip()
results = []
def check(name, ok, got=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {str(got)[:260]}'), flush=True)

CRYPT = 'extensions.crypt' if sql("select count(*) from pg_proc where proname='crypt' and pronamespace='extensions'::regnamespace") != '0' else 'crypt'
SALT = CRYPT.replace('crypt', 'gen_salt')
REQ = sql("select public.hdm_required_terms_version()")

def make_user(tag, gender, looking, birth, first, last):
    pid, email = PFX + tag, f'{MAIL}{tag}@{DOM}'
    profile = json.dumps({'currentName': 'בדיקה ' + tag, 'birthdate': birth, 'birthFirstName': first, 'birthLastName': last, 'gender': gender,
                          'lookingFor': looking, 'location': 'חיפה', 'photoUrl': 'data:image/png;base64,iVBORw0KGgo=', 'createdAt': 0}, ensure_ascii=False)
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
        foreach t in array array['hdm_subscription_events','hdm_chat_openings','hdm_subscriptions','hdm_hidden_profiles'] loop
          if to_regclass('public.' || t) is not null and exists (select 1 from information_schema.columns where table_schema='public' and table_name=t and column_name='profile_id') then
            execute format('delete from public.%I where profile_id like %L', t, '{PFX}%');
          end if; end loop; end $d$;
      delete from public.docs where id like '{PFX}%' or data::text like '%{PFX}%';
      delete from public.hdm_consents where user_id in (select id from auth.users where email like '{MAIL}%');
      delete from public.hdm_accounts where auth_user_id in (select id from auth.users where email like '{MAIL}%');
      delete from auth.users where email like '{MAIL}%'; commit;""")
    return sql(f"""select (select count(*) from auth.users where email like '{MAIL}%') + (select count(*) from public.docs where id like '{PFX}%')
                 + (select count(*) from public.hdm_target_email_log where sender_profile like '{PFX}%' or recipient_profile like '{PFX}%')""")

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

def login(pg, app, email, hash_=''):
    pg.goto(app + hash_, wait_until='networkidle'); pg.wait_for_timeout(1200)
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
    pg.fill('#li-email', email); pg.fill('#li-pass', PW); pg.click('#li-submit')
    try: pg.wait_for_function("() => myId", timeout=20000)
    except Exception: pass
    pg.wait_for_timeout(1500)

def open_card(pg, pid):
    pg.evaluate("""async (id) => { const s = await dbCap.doc('profiles/' + id).get(); const p = s.data();
        currentMatchId = id; currentMatchData = p; renderMatchCard(p); go('screen-match'); }""", pid)
    pg.wait_for_timeout(300)
def outbox(uemail): return sql(f"select count(*) from public.hdm_target_email_outbox o join auth.users u on u.id = o.user_id where u.email = '{uemail}'")
def interests(a, b): return sql(f"select count(*) from public.docs where collection='interests' and id='{a}__{b}'")
def call_worker(secret):
    req = urllib.request.Request(FN, data=b'{}', method='POST', headers={'content-type': 'application/json', **({'x-hdm-cron': secret} if secret else {})})
    try:
        with urllib.request.urlopen(req, timeout=90) as r: return r.status, r.read().decode()[:300]
    except urllib.error.HTTPError as e: return e.code, e.read().decode()[:300]
    except Exception as e: return 0, str(e)[:200]
def setting_state(pg):
    return pg.evaluate("() => ({ st: document.getElementById('set-target-emails-state').textContent.trim(), aria: document.getElementById('set-target-emails').getAttribute('aria-checked'), shown: getComputedStyle(document.getElementById('screen-settings')).display !== 'none' })")


def as_user(email, q):
    uid = sql(f"select id from auth.users where email = '{email}'")
    claims = json.dumps({'sub': uid, 'role': 'authenticated'})
    return sql(f"begin; select set_config('request.jwt.claims', '{claims}', true), set_config('request.jwt.claim.sub', '{uid}', true); set local role authenticated; {q}; commit;")
def psql_steps(*stmts):   # כל פקודה בטרנזקציה משלה, באותו חיבור (כמו פונקציית השליחה)
    args = ['psql', DB, '-X', '-At', '-v', 'ON_ERROR_STOP=1']
    for st in stmts: args += ['-c', st]
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError('psql: ' + r.stderr.strip()[:200])
    return r.stdout.strip().splitlines()
def row(email): return sql(f"select o.status from public.hdm_target_email_outbox o join auth.users u on u.id=o.user_id where u.email='{email}' order by o.id desc limit 1")
def rid(email): return sql(f"select o.id from public.hdm_target_email_outbox o join auth.users u on u.id=o.user_id where u.email='{email}' order by o.id desc limit 1")
def uid(email): return sql(f"select id from auth.users where email='{email}'")
def pref(email): return sql(f"select coalesce((select target_emails::text from public.hdm_target_email_prefs where user_id='{uid(email)}'),'none')")
def timed(f):
    t = time.time(); v = f(); return v, time.time() - t
print(f'ריצה {RUN}', flush=True)
code = 1
try:
    s, sm = make_user('sender', 'אישה', 'גברים', '1986-04-12', 'אבי', 'שלום')
    sql(f"select public.hdm_admin_set_plan('{s}', 'basic')")
    R = [make_user(f'r{i}', 'גבר', 'נשים', f'198{i}-0{i+1}-1{i}', 'עמית', 'רז') for i in range(1, 5)]
    for p, _ in R: as_user(sm, f"select public.hdm_send_target('{p}')")
    check('הכנה: 4 חצים → 4 מיילים בתור', all(row(e) == 'pending' for _, e in R), [row(e) for _, e in R])
    # ---- א. ביטול בזמן מסירה (במסד, כמו שפונקציית השליחה עושה): הביטול ממתין לסוף המסירה ----
    (p1, e1) = R[0]; i1 = rid(e1); k1 = f"hashtextextended('hdm_target_email:{uid(e1)}', 0)"
    sql(f"update public.hdm_target_email_outbox set status='claimed', claimed_at=now() where id={i1}")
    with concurrent.futures.ThreadPoolExecutor(2) as ex:
        fa = ex.submit(lambda: psql_steps(f"select pg_advisory_lock({k1})", f"select 'B' || count(*) from public.hdm_target_email_begin({i1})",
                                          "select pg_sleep(3)", f"select public.hdm_target_email_done({i1}, 'sent', null)", f"select pg_advisory_unlock({k1})"))
        time.sleep(1)
        fb = ex.submit(lambda: timed(lambda: as_user(e1, "select public.hdm_set_target_emails(false)")))
        ra = fa.result(); _, tb = fb.result()
    check('א. מסירה שהתחילה (נעילה מוחזקת): begin הצליח', 'B1' in ra, ra)
    check('א. ביטול שנשלח בזמן המסירה — המתין לסופה (לא "עקף" אותה)', tb >= 1.5, round(tb, 2))
    check('א. המייל שנמסר מסומן נשלח, והביטול נשמר מיד אחריו', row(e1) == 'sent' and pref(e1) == 'false', [row(e1), pref(e1)])
    # ---- ב. ביטול לפני המסירה: לא נמסר ----
    (p2, e2) = R[1]; i2 = rid(e2); k2 = f"hashtextextended('hdm_target_email:{uid(e2)}', 0)"
    sql(f"update public.hdm_target_email_outbox set status='claimed', claimed_at=now() where id={i2}")
    as_user(e2, "select public.hdm_set_target_emails(false)")
    rb = psql_steps(f"select pg_advisory_lock({k2})", f"select 'B' || count(*) from public.hdm_target_email_begin({i2})", f"select pg_advisory_unlock({k2})")
    check('ב. ביטול שנשמר לפני המסירה — begin מסרב, לא נמסר', 'B0' in rb and row(e2) == 'skipped', [rb, row(e2)])
    # ---- ג. פונקציית השליחה האמיתית, עם "Brevo" איטי (שרת בדיקה שמשהה 4 שניות — לא Brevo, לא נשלח מייל) ----
    (p3, e3) = R[2]; (p4, e4) = R[3]
    as_user(e4, "select public.hdm_set_target_emails(false)")          # ד. ביטל לפני ההרצה
    with concurrent.futures.ThreadPoolExecutor(2) as ex:
        fw = ex.submit(lambda: timed(lambda: call_worker(CRON)))
        time.sleep(1.8)
        k3 = f"hashtextextended('hdm_target_email:{uid(e3)}', 0)"
        locks = sql(f"select pg_try_advisory_xact_lock({k3})")   # f = הנעילה של המשתמש מוחזקת ע"י פונקציית השליחה
        fo = ex.submit(lambda: timed(lambda: as_user(e3, "select public.hdm_set_target_emails(false)")))
        (wst, wbody), tw = fw.result(); _, to = fo.result()
    print(f'   פונקציה: HTTP {wst} {wbody} ({tw:.1f}s) | ביטול: {to:.1f}s | נעילה תפוסה בזמן המסירה: {locks == 'f'}', flush=True)
    check('ג. פונקציית השליחה החזיקה את נעילת המשתמש בזמן הקריאה ל"Brevo"', locks == 'f', locks)
    check('ג. ביטול שנשלח בזמן המסירה האמיתית — המתין לסופה', to >= 1.0, round(to, 2))
    check('ג. המייל שנמסר — נשלח פעם אחת, והביטול נשמר מיד אחריו', row(e3) == 'sent' and pref(e3) == 'false', [row(e3), pref(e3)])
    check('ד. מי שביטל לפני ההרצה — לא נמסר (דילוג), בלי קריאה ל"Brevo"', row(e4) == 'skipped', row(e4))
    try: wj = json.loads(wbody).get('target', {})
    except Exception: wj = {}
    a4 = sql(f"select o.attempts from public.hdm_target_email_outbox o join auth.users u on u.id=o.user_id where u.email='{e4}'")
    check('ג+ד. תוצאת ההרצה: נמסר רק 1 (מי שביטל — 0 ניסיונות מסירה)', wj.get('sent') == 1 and a4 == '0', [wbody, a4])
    check('אחרי הכול — נעילות המשתמשים שוחררו', all(sql(f"select pg_try_advisory_xact_lock(hashtextextended('hdm_target_email:{uid(e)}', 0))") == 't' for _, e in R))
    code = 0 if all(results) else 1
except Exception as e:
    print('ERROR', str(e)[:300], flush=True); code = 1
finally:
    try: left = cleanup(); print(f'ניקוי: נשארו {left} רשומות בדיקה', flush=True); code = code if left == '0' else 1
    except Exception as e: print('ניקוי נכשל', str(e)[:200], flush=True); code = 1
print(f'SUMMARY עברו {sum(results)} מתוך {len(results)}', flush=True)
sys.exit(code)
