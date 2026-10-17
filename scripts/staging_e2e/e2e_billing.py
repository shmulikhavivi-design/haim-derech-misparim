# =====================================================================
# חיים דרך מספרים — בדיקת דפדפן של מסך "המנוי שלי" (staging.html) מול Staging בלבד
#
# * בלי Grow ובלי חיובים: תשלום מאושר מדומה נקלט דרך hdm_billing_apply_grow_event (כמו שפונקציית השרת תעשה).
# * משתמשי בדיקה: hdm-bill-<ריצה>-*@example.invalid, מזהי פרופיל bill<ריצה>_*. בסוף — ובכל כישלון — הכול נמחק.
# משתני סביבה: STAGING_DB_URL (סוד), STAGING_PUBLISHABLE_KEY (מפתח ציבורי), PAGE (נתיב ל-staging.html)
# =====================================================================
import json, os, random, string, subprocess, sys, http.server, threading, functools, uuid
from playwright.sync_api import sync_playwright

DB = os.environ['STAGING_DB_URL']
KEY = os.environ.get('STAGING_PUBLISHABLE_KEY', '')
PAGE = os.environ.get('PAGE', 'staging.html')
RUN = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(6))
PFX = f'bill{RUN}_'
MAIL = f'hdm-bill-{RUN}-'
PW = 'Bill-' + ''.join(random.choice(string.ascii_letters + string.digits) for _ in range(20))
if not KEY.startswith('sb_publishable_'):
    print('⛔ STAGING_PUBLISHABLE_KEY חסר או לא ציבורי'); sys.exit(2)

def sql(q):
    r = subprocess.run(['psql', DB, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q], capture_output=True, text=True)
    if r.returncode != 0: raise RuntimeError('sql: ' + r.stderr.strip()[:200])
    return r.stdout.strip()

results = []
def check(name, ok, got=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ← {str(got)[:200]}'), flush=True)

CRYPT = 'extensions.crypt' if sql("select count(*) from pg_proc where proname='crypt' and pronamespace='extensions'::regnamespace") != '0' else 'crypt'
SALT = CRYPT.replace('crypt', 'gen_salt')
PEOPLE = {'paid': 'פזית משלמת', 'manual': 'מני ותיק', 'buyer': 'בתיה קונה', 'upg': 'אורית משדרגת'}
IDS = {k: PFX + k for k in PEOPLE}
IDS_SQL = "array[" + ",".join(f"'{v}'" for v in IDS.values()) + "]"
DD = f'{PFX}DD'

def cleanup():
    sql(f"""begin;
      delete from public.hdm_payments where profile_id = any({IDS_SQL}) or grow_transaction_id like '{PFX}%';
      delete from public.hdm_checkouts where profile_id = any({IDS_SQL});
      delete from public.hdm_subscription_events where profile_id = any({IDS_SQL});
      delete from public.hdm_subscriptions where profile_id = any({IDS_SQL});
      delete from public.hdm_renewal_charges where profile_id = any({IDS_SQL});
      delete from public.hdm_billing_tokens where profile_id = any({IDS_SQL});
      delete from public.hdm_grow_outbox where profile_id = any({IDS_SQL}) or grow_direct_debit_id like '{PFX}%';
      delete from public.docs where collection = 'profiles' and id = any({IDS_SQL});
      delete from public.hdm_accounts where profile_id = any({IDS_SQL});
      delete from auth.users where email like '{MAIL}%@example.invalid';
      commit;""")
    return sql(f"""select (select count(*) from auth.users where email like '{MAIL}%') + (select count(*) from public.hdm_accounts where profile_id like '{PFX}%')
                 + (select count(*) from public.hdm_checkouts where profile_id like '{PFX}%') + (select count(*) from public.hdm_payments where profile_id like '{PFX}%')
                 + (select count(*) from public.hdm_grow_outbox where profile_id like '{PFX}%') + (select count(*) from public.hdm_subscriptions where profile_id like '{PFX}%')""")

def create_people():
    consent = sql("select public.hdm_required_terms_version()")
    for k, name in PEOPLE.items():
        pid, email = IDS[k], f'{MAIL}{k}@example.invalid'
        profile = json.dumps({'currentName': name, 'birthdate': '1990-01-01', 'birthFirstName': 'א', 'birthLastName': 'ב', 'gender': 'אישה',
                              'lookingFor': 'גברים', 'location': 'חיפה', 'photoUrl': 'data:image/png;base64,iVBORw0KGgo=', 'createdAt': 0}, ensure_ascii=False)
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
          , a as (insert into public.hdm_accounts (auth_user_id, profile_id) select id, '{pid}' from u)
          insert into public.hdm_consents (user_id, profile_id, version, source) select id, '{pid}', '{consent}', 'signup' from u;
          insert into public.docs (collection, id, data) values ('profiles', '{pid}', $j${profile}$j$::jsonb);
          commit;""")
    # ותיק: פלוס ידני ללא הגבלת זמן (כמו 4 החשבונות הקיימים)
    sql(f"select public.hdm_admin_set_plan('{IDS['manual']}', 'plus', null, 'e2e billing')")
    # משלמת: ניסיון תשלום עם הסכמה + אירוע "תשלום מאושר" מדומה מ-Grow
    ck = str(uuid.uuid4())
    sql(f"""insert into public.hdm_checkouts (id, user_id, profile_id, plan, amount_agorot, terms_version)
            select '{ck}', auth_user_id, profile_id, 'plus', 4890, public.hdm_billing_current_terms() from public.hdm_accounts where profile_id = '{IDS['paid']}'""")
    r = sql(f"""select public.hdm_billing_apply_grow_event('{json.dumps({'transactionId': PFX + 'T1', 'kind': 'initial', 'outcome': 'approved', 'amountAgorot': 4890, 'checkoutId': ck, 'directDebitId': DD})}'::jsonb)->>'result'""")
    if r != 'started': raise RuntimeError('simulated payment: ' + r)
    # משדרגת: בסיסי בתשלום, באמצע התקופה (15 ימים מתוך ~31)
    ck2 = str(uuid.uuid4())
    sql(f"""insert into public.hdm_checkouts (id, user_id, profile_id, plan, amount_agorot, terms_version)
            select '{ck2}', auth_user_id, profile_id, 'basic', 2990, public.hdm_billing_current_terms() from public.hdm_accounts where profile_id = '{IDS['upg']}'""")
    r = sql(f"""select public.hdm_billing_apply_grow_event('{json.dumps({'transactionId': PFX + 'T2', 'kind': 'initial', 'outcome': 'approved', 'amountAgorot': 2990, 'checkoutId': ck2, 'directDebitId': DD + '2'})}'::jsonb)->>'result'""")
    if r != 'started': raise RuntimeError('simulated payment 2: ' + r)
    sql(f"""update public.hdm_subscriptions set period_anchor = now() - interval '15 days',
             current_period_end = public.hdm_billing_add_months(now() - interval '15 days', 1) where profile_id = '{IDS['upg']}'""")

html_dir = os.path.dirname(os.path.abspath(PAGE))
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=html_dir))
srv.RequestHandlerClass.log_message = lambda *a: None
threading.Thread(target=srv.serve_forever, daemon=True).start()
APP = f'http://127.0.0.1:{srv.server_address[1]}/{os.path.basename(PAGE)}'
seen_hosts, errors = set(), []

def login(pg, k):
    pg.evaluate("() => { try{ var i=document.getElementById('intro-screen'); if(i) i.style.display='none'; openLogin(); }catch(e){} }")
    pg.fill('#li-email', f'{MAIL}{k}@example.invalid'); pg.fill('#li-pass', PW); pg.click('#li-submit')
    try: pg.wait_for_function("() => myId || document.getElementById('li-status').textContent.trim()", timeout=15000)
    except Exception: pass
    pg.wait_for_timeout(500)
    return pg.evaluate("() => myId")

def open_plans(pg):
    pg.evaluate("() => hdmOpenPlans()")
    try: pg.wait_for_function("() => hdmEnt && hdmEnt.forId === myId && !hdmEnt.error && hdmEnt.billing", timeout=15000)
    except Exception: pass
    pg.wait_for_timeout(500)
    return pg.inner_text('#hdm-plans-body')

def new_page(ctx, url):
    pg = ctx.new_page(); pg.on('pageerror', lambda e: errors.append(str(e))); pg.on('request', lambda r: seen_hosts.add(r.url.split('/')[2]))
    pg.goto(url); pg.wait_for_timeout(2500)
    return pg

print(f'ריצה {RUN}', flush=True)
exit_code = 1
try:
    create_people()
    with sync_playwright() as pw:
        br = pw.chromium.launch()
        def ctx_new():
            c = br.new_context(); c.add_init_script(f"try{{ localStorage.setItem('hdm_staging_publishable_key', {json.dumps(KEY)}); }}catch(e){{}}"); return c

        # --- מנוי בתשלום: תאריך החיוב הבא + ביטול ---
        c = ctx_new(); pg = new_page(c, APP)
        check('משלמת: התחברות', login(pg, 'paid') == IDS['paid'])
        t = open_plans(pg)
        nxt = sql(f"select to_char(current_period_end at time zone 'Asia/Jerusalem', 'FMDD.FMMM.YYYY') from public.hdm_subscriptions where profile_id = '{IDS['paid']}'")
        check('מוצג "החיוב הבא" עם התאריך והסכום', 'החיוב הבא' in t and nxt in t and '₪48.90' in t, [nxt, t[:300]])
        check('מוצג שהמנוי מתחדש אוטומטית עד ביטול', 'מתחדש אוטומטית' in t, t[:300])
        check('יש כפתור "ביטול מנוי"', pg.locator('#hdm-bill-cancel').count() == 1)
        pg.click('#hdm-bill-cancel'); pg.wait_for_timeout(300)
        t = pg.inner_text('#hdm-plans-body')
        check('אישור ביטול: מוסבר שהמסלול פעיל עד סוף התקופה', 'החיובים הבאים ייעצרו' in t and nxt in t, t[:400])
        check('לפני האישור — עדיין מתחדש', sql(f"select auto_renew from public.hdm_subscriptions where profile_id='{IDS['paid']}'") == 't')
        pg.click('#hdm-bill-cancel-yes')
        try: pg.wait_for_function("() => !document.getElementById('hdm-bill-cancel-yes') && hdmEnt && hdmEnt.billing && !hdmEnt.billing.autoRenew", timeout=15000)
        except Exception: pass
        pg.wait_for_timeout(400)
        t = pg.inner_text('#hdm-plans-body')
        check('אחרי ביטול: "המנוי בוטל ולא יתחדש" + פעיל עד', 'המנוי בוטל ולא יתחדש' in t and nxt in t and 'החיוב הבא' not in t, t[:300])
        row = sql(f"select auto_renew::text || '|' || status from public.hdm_subscriptions where profile_id='{IDS['paid']}'")
        check('במסד: החידוש נעצר, המסלול עדיין פלוס', row == 'false|canceled' and sql(f"select public.hdm_plan_of('{IDS['paid']}')") == 'plus', row)
        check('במסד: נרשם ביטול הוראת הקבע מול Grow', sql(f"select count(*) from public.hdm_grow_outbox where grow_direct_debit_id='{DD}' and reason='customer' and done_at is null") == '1')
        c.close()

        # --- ותיק עם פלוס ידני: אין חיוב ואין ביטול ---
        c = ctx_new(); pg = new_page(c, APP)
        check('ותיק: התחברות', login(pg, 'manual') == IDS['manual'])
        t = open_plans(pg)
        check('ותיק: בלי "המנוי שלי", בלי תאריך חיוב ובלי ביטול', 'החיוב הבא' not in t and pg.locator('#hdm-bill-cancel').count() == 0 and 'פלוס' in t, t[:300])
        check('ותיק: אין כפתור הצטרפות (רכישה עוד לא פתוחה)', pg.locator('.hdm-plan-btn.buy').count() == 0)
        c.close()

        # --- לקוח חינם: בלי preview אין רכישה; עם preview — מסך הסכמה ---
        c = ctx_new(); pg = new_page(c, APP)
        check('חינם: התחברות', login(pg, 'buyer') == IDS['buyer'])
        t = open_plans(pg)
        check('ברירת מחדל: הכפתורים "בקרוב", אין רכישה', pg.locator('.hdm-plan-btn.buy').count() == 0 and 'בקרוב' in t, t[-300:])
        pg.goto(APP + '?billing=preview'); pg.wait_for_timeout(2500)
        login(pg, 'buyer') if not pg.evaluate("() => myId") else None
        t = open_plans(pg)
        check('preview: יש כפתורי הצטרפות לשלושת המסלולים', pg.locator('.hdm-plan-btn.buy').count() == 3, pg.locator('.hdm-plan-btn.buy').count())
        pg.locator('.hdm-plan-btn.buy').first.click(); pg.wait_for_timeout(300)
        t = pg.inner_text('#hdm-plans-body')
        check('מסך הסכמה: מוצגים תנאי החידוש והמחיר', 'מתחדש אוטומטית מדי חודש' in t and '₪29.90' in t and 'החיוב הראשון היום' in t, t[:400])
        check('תיבת ההסכמה לא מסומנת מראש', pg.evaluate("() => document.getElementById('hdm-bill-accept').checked") is False)
        check('בלי סימון — "המשך לתשלום" חסום', pg.evaluate("() => document.getElementById('hdm-bill-pay').disabled") is True)
        n0 = sql(f"select count(*) from public.hdm_checkouts where profile_id='{IDS['buyer']}'")
        pg.evaluate("() => { var b=document.getElementById('hdm-bill-pay'); b.disabled=false; hdmBillStart(); }"); pg.wait_for_timeout(800)
        check('עקיפה בלי סימון — לא נשלח כלום לשרת', sql(f"select count(*) from public.hdm_checkouts where profile_id='{IDS['buyer']}'") == n0 == '0')
        pg.check('#hdm-bill-accept'); pg.wait_for_timeout(100)
        check('עם סימון — הכפתור נפתח', pg.evaluate("() => document.getElementById('hdm-bill-pay').disabled") is False)
        pg.click('#hdm-bill-pay')
        try: pg.wait_for_function("() => /לא בוצע שום חיוב|לא הצלחנו/.test(document.getElementById('hdm-plans-body').innerText)", timeout=15000)
        except Exception: pass
        t = pg.inner_text('#hdm-plans-body')
        check('הודעה: ההסכמה נשמרה, לא בוצע שום חיוב', 'לא בוצע שום חיוב' in t, t[:400])
        row = sql(f"select plan || '|' || amount_agorot || '|' || status || '|' || terms_version from public.hdm_checkouts where profile_id='{IDS['buyer']}'")
        check('במסד: ניסיון תשלום עם ההסכמה (מסלול, סכום, גרסת תנאים)', row == 'basic|2990|pending|' + sql("select public.hdm_billing_current_terms()"), row)
        check('במסד: הלקוח נשאר בחינם (אין הרשאות בלי אישור תשלום)', sql(f"select public.hdm_plan_of('{IDS['buyer']}')") == 'free')
        c.close()

        # --- שדרוג באמצע החודש (preview בלבד; בלי חיוב) ---
        c = ctx_new(); pg = new_page(c, APP + '?billing=preview')
        check('משדרגת: התחברות', login(pg, 'upg') == IDS['upg'])
        t = open_plans(pg)
        check('preview: כפתורי שדרוג לפלוס ול-VIP בלבד', pg.locator('.hdm-plan-btn.buy').count() == 2 and 'שדרוג לפלוס' in t and 'שדרוג לVIP' in t, t[-400:])
        pe_txt = sql(f"select to_char(current_period_end at time zone 'Asia/Jerusalem', 'FMDD.FMMM.YYYY') from public.hdm_subscriptions where profile_id = '{IDS['upg']}'")
        pg.locator('.hdm-plan-btn.buy').first.click()
        try: pg.wait_for_function("() => document.getElementById('hdm-bill-accept')", timeout=15000)
        except Exception: pass
        t = pg.inner_text('#hdm-plans-body')
        exp = int(sql(f"select public.hdm_billing_proration('basic', 'plus', period_anchor, current_period_end) from public.hdm_subscriptions where profile_id = '{IDS['upg']}'"))
        shown = f'₪{exp/100:.2f}'; shown2 = f'₪{(exp-1)/100:.2f}'
        check('שדרוג: מוצג החיוב היחסי לפי יתרת התקופה', ('חיוב עכשיו' in t) and (shown in t or shown2 in t) and 800 <= exp <= 1100, [shown, t[:500]])
        check('שדרוג: מוצג שתאריך החיוב לא משתנה ומחיר פלוס מהחיוב הבא', 'לא משתנה' in t and pe_txt in t and '₪48.90' in t, t[:500])
        check('שדרוג: תיבת הסכמה לא מסומנת, הכפתור חסום', pg.evaluate("() => !document.getElementById('hdm-bill-accept').checked && document.getElementById('hdm-bill-pay').disabled"))
        pg.check('#hdm-bill-accept'); pg.click('#hdm-bill-pay')
        try: pg.wait_for_function("() => /לא בוצע שום חיוב|לא הצלחנו|הסכום התעדכן/.test(document.getElementById('hdm-plans-body').innerText)", timeout=15000)
        except Exception: pass
        t = pg.inner_text('#hdm-plans-body')
        check('שדרוג: ההסכמה נשמרה, לא בוצע חיוב', 'לא בוצע שום חיוב' in t, t[:500])
        row = sql(f"select kind || '|' || plan || '|' || from_plan || '|' || status from public.hdm_checkouts where profile_id='{IDS['upg']}' and kind='upgrade'")
        check('במסד: ניסיון תשלום שדרוג בסכום היחסי', row == 'upgrade|plus|basic|pending' and sql(f"select amount_agorot between 800 and 1100 from public.hdm_checkouts where profile_id='{IDS['upg']}' and kind='upgrade'") == 't', row)
        check('במסד: עדיין בסיסי עד אישור תשלום', sql(f"select public.hdm_plan_of('{IDS['upg']}')") == 'basic')
        # אישור תשלום מדומה (כמו פונקציית השרת אחרי Grow) → פלוס מיד, אותו תאריך
        cku, amtu = sql(f"select id || '|' || amount_agorot from public.hdm_checkouts where profile_id='{IDS['upg']}' and kind='upgrade'").split('|')
        r = sql(f"""select public.hdm_billing_apply_grow_event('{json.dumps({'transactionId': PFX + 'U1', 'kind': 'upgrade', 'outcome': 'approved', 'amountAgorot': int(amtu), 'checkoutId': cku})}'::jsonb)->>'result'""")
        t = open_plans(pg)
        check('אחרי אישור: פלוס, החיוב הבא ₪48.90 באותו תאריך', r == 'upgraded' and 'פלוס' in t and '₪48.90' in t and pe_txt in t, [r, t[:300]])
        pg.evaluate("() => openLegal('terms')"); pg.wait_for_timeout(300)
        lt = pg.inner_text('#legal-body')
        check('תנאי השימוש: סעיף מנויים, חיובים, שדרוגים, חידושים וביטולים', all(w in lt for w in ['מנויים, חיובים, שדרוגים, חידושים וביטולים', 'ההפרש היחסי', 'מתחדש אוטומטית', 'הביטול עוצר את החיובים הבאים']), lt[:200])
        c.close()

        check('אין שגיאות JavaScript בדף', not errors, errors[:2])
        check('הדף פנה רק ל-Staging (לא לפרויקט הפעיל)', not any('qtspzigjlbtckqfyaubp' in h for h in seen_hosts), sorted(seen_hosts))
        br.close()
    exit_code = 0 if results and all(results) else 1
except Exception as e:
    print('FAIL שגיאה בבדיקה: ' + str(e)[:300], flush=True); exit_code = 1
finally:
    left = cleanup()
    print(f'ניקוי: נשארו {left} רשומות בדיקה', flush=True)
    if left != '0': exit_code = 1
    srv.shutdown()
print(f'SUMMARY {sum(results)}/{len(results)} passed', flush=True)
sys.exit(exit_code)
