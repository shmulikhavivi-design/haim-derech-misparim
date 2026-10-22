#!/usr/bin/env bash
# =====================================================================
# חיים דרך מספרים — פעולות Production דרך GitHub Actions (סביבת GitHub בשם "production")
#
# מצבים (לפי [prod:<mode>] בשורת הנושא של ה-commit; בלי סימון = check):
#   check     — קריאה בלבד: הבדיקה המקדימה (00) + סיכום הגדרות Auth. לא משנה כלום.
#               מספיק PRODUCTION_SUPABASE_TOKEN עם הרשאות קריאה (Auth config read + Database read): השאילתה רצה
#               דרך נקודת הקצה database/query/read-only של Supabase, בלי סיסמת מסד.
#   authcfg   — מגדיר ב-Auth: SMTP של Brevo, Site URL, Redirect URLs ותבניות מייל בעברית. לא נוגע במסד ולא במשתמשים.
#               לא מפעיל Confirm email (זה שלב נפרד אחרי המעבר).
#   migrate   — מריץ את 01_production_migration.sql ("הכול או כלום", גיבוי מלא קודם). רק אחרי אישור מפורש של הבעלים.
#   confirmon — מפעיל Confirm email. רק אחרי שהמעבר הצליח ומייל אמיתי הגיע.
#
# סודות (Environment Secrets בסביבה production בלבד, אף ערך לא מודפס):
#   PRODUCTION_DB_URL          — כתובת חיבור למסד של הפרויקט הפעיל (לבדיקה המקדימה ולמעבר)
#   PRODUCTION_SUPABASE_TOKEN  — טוקן Supabase לפרויקט הפעיל בלבד, עם auth_config_read + auth_config_write
#   BREVO_SMTP_KEY             — מפתח ה-SMTP של Brevo (רק למצב authcfg)
# =====================================================================
set -euo pipefail
PROD_REF='qtspzigjlbtckqfyaubp'
STAGING_REF='ousepgdvzammgkxkweze'
MODE="${1:-check}"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
SITE='https://shmulikhavivi-design.github.io/haim-derech-misparim/'
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
ann(){ local msg; msg=$(printf '%s' "$3" | sed -e 's/%/%25/g' -e 's/\r/%0D/g' | awk 'BEGIN{ORS="%0A"} {print}'); printf '::%s title=%s::%s\n' "$1" "$2" "$msg"; echo "$3" >> "$SUMMARY"; }
stop(){ ann error "prod-result" "⛔ $*"; exit 1; }
case "$MODE" in launchcheck|hideapply|adminpreview|hiderehearse|ownerhidecheck|adminapply|adminrehearse|incidentnine|incidenteight|incidentseven|incidentsix|incidentfive|incidentfour|incidentthree|incidenttwo|incident|stagecapply|stagecrehearse|readiness|cronnow|stagearehearse|stageaapply|ownercardsync|cardlink|paycheck|payreplay|secretfix|secretcmp|paydiag|purgerehearseleftovers|purgeapplyleftovers|purgerehearsedina|purgeapplydina|vipsoon|backupdrop|purgerehearse|purgeapply|ownerverifyfree|ownerfree|secureread|ownercheck|cronrehearse|cronapply|billingtests|billingdeploy|billingdeploycheck|billingprep|plusext|testcleanup|testcheck|advisors|confirmplan|emailfix|emailcheck|plusapply|plusplan|smoke|postcheck|check|authplan|keycheck|smtptest|supamail|maildiag|ownertest|fingerprint|export|rehearse|simulate|authcfg|migrate|confirmon) ;; *) stop "מצב לא מוכר: $MODE";; esac

DB="${PRODUCTION_DB_URL:-}"; KEY="${BREVO_SMTP_KEY:-}"
# הטוקן החדש (Claude-Production-DB-Write, Database Read-write) קודם; אם אינו מוגדר — הטוקן הישן לקריאה בלבד
OLDTOK="${PRODUCTION_SUPABASE_TOKEN:-}"   # הטוקן הישן (קריאת הגדרות Auth) — לקריאה בלבד במצב confirmplan
if [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then TOK="$SUPABASE_ACCESS_TOKEN"; TOKSRC=SUPABASE_ACCESS_TOKEN; else TOK="${PRODUCTION_SUPABASE_TOKEN:-}"; TOKSRC=PRODUCTION_SUPABASE_TOKEN; fi
unset PRODUCTION_DB_URL PRODUCTION_SUPABASE_TOKEN SUPABASE_ACCESS_TOKEN BREVO_SMTP_KEY
for v in "$DB" "$TOK" "$KEY" "$OLDTOK"; do [ -n "$v" ] && echo "::add-mask::$v"; done
ann notice "prod-secrets" "PRODUCTION_DB_URL: $([ -n "$DB" ] && echo מוגדר || echo חסר) | טוקן בשימוש: $([ -n "$TOK" ] && echo "$TOKSRC" || echo חסר) | BREVO_SMTP_KEY: $([ -n "$KEY" ] && echo מוגדר || echo חסר)"

# ---- keycheck: קריאה בלבד. מבנה המפתח (בלי ערך) + התחברות לשרת ה-SMTP של Brevo בלי לשלוח מייל. לא נוגע ב-Supabase. ----
if [ "$MODE" = "keycheck" ]; then
  [ -n "$KEY" ] || stop "BREVO_SMTP_KEY חסר"
  SHAPE=$(BK="$KEY" python3 -I - <<'PY'
import os,re
k=os.environ["BK"]; s=k.strip().strip('"').strip("'").strip()
out=[f"אורך: {len(k)}", f"רווחים/שורה חדשה בקצוות: {'כן' if k!=k.strip() else 'לא'}",
     "מרכאות סביב הערך: " + ("כן" if k.strip()[:1] in ("'", '"') else "לא"),
     f"רווח באמצע: {'כן' if re.search(r'\s', s) else 'לא'}"]
if s.startswith("xsmtpsib-"): t="מפתח SMTP של Brevo (xsmtpsib-)"
elif s.startswith("xkeysib-"): t="מפתח API של Brevo (xkeysib-) — לא מתאים ל-SMTP"
elif re.fullmatch(r"[A-Za-z0-9]{16}", s): t="16 תווים אותיות/ספרות (נראה כמו סיסמת SMTP ישנה של Brevo)"
else: t="מבנה אחר (לא xsmtpsib-/xkeysib-)"
out.append("סוג: "+t)
print(" | ".join(out))
PY
)
  ann notice "prod-keycheck-shape" "$SHAPE"
  LOGIN=$(BK="$KEY" python3 -I - <<'PY'
import os,smtplib,ssl
k=os.environ["BK"].strip().strip('"').strip("'").strip()
try:
    s=smtplib.SMTP("smtp-relay.brevo.com",587,timeout=20); s.ehlo(); s.starttls(context=ssl.create_default_context()); s.ehlo()
    s.login("be5ab9001@smtp-brevo.com",k); s.quit(); print("✅ ההתחברות ל-Brevo SMTP הצליחה (לא נשלח מייל)")
except smtplib.SMTPAuthenticationError as e: print(f"❌ Brevo דחה את ההתחברות: {e.smtp_code}")
except Exception as e: print(f"❌ שגיאת חיבור: {type(e).__name__}")
PY
)
  ann notice "prod-keycheck-login" "$LOGIN"
  PARTS=$(BK="$KEY" python3 -I - <<'PY'
import os,re,smtplib,ssl
toks=os.environ["BK"].split()
desc=[]
for i,t in enumerate(toks,1):
    kind="xsmtpsib-" if t.startswith("xsmtpsib-") else ("xkeysib-" if t.startswith("xkeysib-") else "טקסט אחר")
    r=""
    if kind=="xsmtpsib-":
        try:
            s=smtplib.SMTP("smtp-relay.brevo.com",587,timeout=20); s.ehlo(); s.starttls(context=ssl.create_default_context()); s.ehlo()
            s.login("be5ab9001@smtp-brevo.com",t); s.quit(); r=" → ✅ התחברות הצליחה"
        except smtplib.SMTPAuthenticationError as e: r=f" → ❌ נדחה {e.smtp_code}"
        except Exception as e: r=f" → ❌ {type(e).__name__}"
    desc.append(f"חלק {i}: {len(t)} תווים, {kind}{r}")
print(f"{len(toks)} חלקים | " + " | ".join(desc))
PY
)
  ann notice "prod-keycheck-parts" "$PARTS"
  ann notice "prod-result" "keycheck הסתיים — קריאה בלבד, לא שונה כלום ב-Supabase ולא נשלח מייל"
  exit 0
fi

API="https://api.supabase.com/v1/projects/$PROD_REF/config/auth"
authget(){ curl -sS -m 30 -o /tmp/cfg.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$API" || echo 000; }
authsummary(){
  jq -c '{site_url, uri_allow_list, confirm_email_on: (.mailer_autoconfirm == false), smtp_host, smtp_port, smtp_user, smtp_pass_set: ((.smtp_pass // "") != ""),
          sender: .smtp_admin_email, sender_name: .smtp_sender_name, rate_limit_email_sent,
          hebrew_templates: {recovery: ((.mailer_templates_recovery_content // "") | test("dir=\"rtl\"")),
                             confirmation: ((.mailer_templates_confirmation_content // "") | test("dir=\"rtl\""))}}' /tmp/cfg.json
}

# ---- הגנות על הטוקן: חייב לראות את Production ולא את Staging ----
if [ -n "$TOK" ]; then
  PROJ=$(curl -sS -m 20 -H "Authorization: Bearer $TOK" https://api.supabase.com/v1/projects | jq -r --arg p "$PROD_REF" --arg s "$STAGING_REF" '[.[].id] | map(if .==$p then "production" elif .==$s then "staging" else "other" end) | join(",")' 2>/dev/null || echo '?')
  ann notice "prod-token-scope" "פרויקטים שהטוקן רואה: $PROJ"
fi

# ---- הגנות על כתובת המסד ----
PSQL=()
if [ -n "$DB" ]; then
  case "$DB" in *"$STAGING_REF"*) stop "הכתובת שייכת ל-Staging. לא הורץ כלום.";; esac
  case "$DB" in *"$PROD_REF"*) ;; *) stop "הכתובת לא שייכת לפרויקט הפעיל ($PROD_REF). לא הורץ כלום.";; esac
  export PGCONNECT_TIMEOUT=20 PGAPPNAME=hdm-production-ci
  PSQL=(psql "$DB" -X -v ON_ERROR_STOP=1 --quiet)
  ID=$(env PGOPTIONS='-c default_transaction_read_only=on' "${PSQL[@]}" -At -c "select (to_regclass('public.hdm_staging_marker') is null and to_regclass('public.docs') is not null)::text" 2>&1) \
    || stop "החיבור למסד נכשל (בדקו את PRODUCTION_DB_URL)."
  [ "$ID" = "true" ] || stop "המסד אינו הפרויקט הפעיל. לא הורץ כלום."
fi

if [ "$MODE" = "check" ]; then
  if [ ${#PSQL[@]} -gt 0 ]; then
    OUT=$(env PGOPTIONS='-c default_transaction_read_only=on' "${PSQL[@]}" -f "$ROOT/supabase/production/00_production_preflight_readonly.sql" 2>&1) || { ann error "prod-preflight" "$OUT"; stop "הבדיקה המקדימה נכשלה."; }
    ann notice "prod-preflight" "$OUT"
  elif [ -n "$TOK" ]; then
    # בלי סיסמת מסד: אותה בדיקה מקדימה דרך נקודת הקצה של Supabase לשאילתות לקריאה בלבד
    Q=$(sed -e '/^begin transaction read only;/d' -e '/^rollback;/d' "$ROOT/supabase/production/00_production_preflight_readonly.sql")
    C=$(curl -sS -m 60 -o /tmp/pf.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
        "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
    if [ "$C" = 200 ] || [ "$C" = 201 ]; then
      ann notice "prod-preflight" "$(jq -r '.[] | "\(.n). \(.["תקין"]) \(.["בדיקה"]): \(.["ערך"])"' /tmp/pf.json)"
    else ann error "prod-preflight" "שאילתה לקריאה בלבד: HTTP $C $( (jq -c '.message // .' /tmp/pf.json 2>/dev/null || true) | cut -c1-300)"; fi
    # מצב ציבורי של הנתונים — ספירות בלבד
    C=$(curl -sS -m 30 -o /tmp/ct.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
        "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" \
        -d '{"query":"select (select count(*) from auth.users) as auth_users, (select count(*) from auth.users where email_confirmed_at is not null) as confirmed, (select count(*) from public.docs) as docs_rows"}' || echo 000)
    ann notice "prod-counts" "HTTP $C $(jq -c '.[0] // .' /tmp/ct.json 2>/dev/null || true)"
    Q2=$(cat "$ROOT/supabase/production/00b_production_security_readonly.sql")
    C=$(curl -sS -m 60 -o /tmp/sec.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
        "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" -d "$(jq -nc --arg q "$Q2" '{query:$q}')" || echo 000)
    ann notice "prod-security" "HTTP $C $(jq -c '.[0].report // .' /tmp/sec.json 2>/dev/null | cut -c1-6000 || true)"
    Q3=$(cat "$ROOT/supabase/production/00c_production_backup_readonly.sql")
    C=$(curl -sS -m 60 -o /tmp/bk.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
        "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" -d "$(jq -nc --arg q "$Q3" '{query:$q}')" || echo 000)
    ann notice "prod-backup" "HTTP $C $(jq -c '.[0].backup // .' /tmp/bk.json 2>/dev/null | cut -c1-4000 || true)"
    # האם הטוקן יכול לכתוב? בדיקה בלי שינוי: שאילתת קריאה דרך נקודת הקצה הרגילה מחזירה את אותו מידע, אבל לא נשלחת שום כתיבה.
    # (לא שולחים PATCH, גם לא ריק.)
  else ann warning "prod-preflight" "לא הורצה: חסר PRODUCTION_SUPABASE_TOKEN"; fi
  if [ -n "$TOK" ]; then
    C=$(authget); [ "$C" = 200 ] && ann notice "prod-auth" "$(authsummary)" || ann error "prod-auth" "קריאת הגדרות Auth: HTTP $C $(jq -r '.message // empty' /tmp/cfg.json 2>/dev/null)"
  else ann warning "prod-auth" "לא נקרא: חסר PRODUCTION_SUPABASE_TOKEN"; fi
  if [ -n "$TOK" ]; then
    # בדיקת הרשאות בלי כתיבה: select 1 דרך נקודת הקצה הרגילה (דורשת הרשאת כתיבה למסד), בלי שום שינוי
    C=$(curl -sS -m 30 -o /tmp/pq.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
        "https://api.supabase.com/v1/projects/$PROD_REF/database/query" -d '{"query":"select 1 as ok"}' || echo 000)
    ann notice "prod-perm-dbquery" "database/query (select 1 בלבד): HTTP $C $(jq -c '.message // .' /tmp/pq.json 2>/dev/null | cut -c1-300)"
    C=$(curl -sS -m 30 -o /tmp/tk.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://api.supabase.com/v1/projects/$PROD_REF/database/backups" || echo 000)
    ann notice "prod-perm-backups" "database/backups (קריאה): HTTP $C $(jq -c '{pitr_enabled, walg_enabled, n:(.backups|length? // null), last:(.backups[-1].inserted_at? // null), msg:.message}' /tmp/tk.json 2>/dev/null | cut -c1-300)"
  fi
  ann notice "prod-result" "check הסתיים — קריאה בלבד, לא שונה כלום"
  exit 0
fi

if [ "$MODE" = "authplan" ]; then
  # קריאה בלבד: מה ישתנה ב-authcfg. לא נשלחת שום כתיבה.
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  C=$(authget); [ "$C" = 200 ] || stop "קריאת הגדרות Auth: HTTP $C"
  case "$KEY" in xsmtpsib-*) KS="✅ מפתח SMTP של Brevo";; xkeysib-*) KS="❌ זה מפתח API ולא מפתח SMTP";; "") KS="❌ חסר";; *) KS="❌ מבנה לא מוכר";; esac
  TPL=$(python3 -I "$HERE/templates.py" "$ROOT/docs/email-templates.md") || stop "קריאת תבניות המייל נכשלה"
  PLAN=$(jq -c --arg s "$SITE" --argjson t "$TPL" '[
     ["Site URL", .site_url, $s],
     ["Redirect URLs", .uri_allow_list, ($s + "**")],
     ["SMTP host", .smtp_host, "smtp-relay.brevo.com"],
     ["SMTP port", .smtp_port, "587"],
     ["SMTP user", .smtp_user, "be5ab9001@smtp-brevo.com"],
     ["Sender", .smtp_admin_email, "life.through.numbers333@gmail.com"],
     ["Sender name", .smtp_sender_name, "חיים דרך מספרים"],
     ["מגבלת מיילים לשעה", .rate_limit_email_sent, 30],
     ["נושא איפוס", .mailer_subjects_recovery, $t.mailer_subjects_recovery],
     ["נושא אישור הרשמה", .mailer_subjects_confirmation, $t.mailer_subjects_confirmation]
   ] | map({"שדה": .[0], "עכשיו": .[1], "יהיה": .[2], "משתנה": (.[1] != .[2])})' /tmp/cfg.json)
  ann notice "prod-authplan" "מפתח Brevo בסוד: $KS | Confirm email: לא משתנה בשלב הזה | $PLAN"
  ann notice "prod-result" "authplan הסתיים — קריאה בלבד, לא שונה כלום"
  exit 0
fi

if [ "$MODE" = "authcfg" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"; [ -n "$KEY" ] || stop "חסר BREVO_SMTP_KEY"
  case "$KEY" in xsmtpsib-*) ;; xkeysib-*) stop "BREVO_SMTP_KEY הוא מפתח API (xkeysib-) ולא מפתח SMTP (xsmtpsib-). לא שונה כלום.";; *) stop "BREVO_SMTP_KEY לא במבנה של מפתח SMTP של Brevo. לא שונה כלום.";; esac
  TPL=$(python3 -I "$HERE/templates.py" "$ROOT/docs/email-templates.md") || stop "קריאת תבניות המייל נכשלה"
  BODY=$(jq -nc --arg s "$SITE" --arg k "$KEY" --argjson t "$TPL" '{
      site_url:$s, uri_allow_list:($s + "**"), external_email_enabled:true,
      smtp_host:"smtp-relay.brevo.com", smtp_port:"587", smtp_user:"be5ab9001@smtp-brevo.com", smtp_pass:$k,
      smtp_admin_email:"life.through.numbers333@gmail.com", smtp_sender_name:"חיים דרך מספרים", smtp_max_frequency:60, rate_limit_email_sent:30 } + $t')
  PC=$(curl -sS -m 30 -o /tmp/patch.json -w '%{http_code}' -X PATCH -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$API" -d "$BODY" || echo 000)
  unset BODY KEY
  [ "$PC" = 200 ] || stop "עדכון Auth נכשל: HTTP $PC $(jq -r '.message // empty' /tmp/patch.json 2>/dev/null | cut -c1-300)"
  C=$(authget); ann notice "prod-auth" "$(authsummary)"
  ann notice "prod-result" "✅ authcfg: SMTP של Brevo, כתובת האתר, ההפניות ותבניות המייל בעברית הוגדרו. Confirm email לא שונה. המסד לא שונה."
  exit 0
fi

# ---- rehearse: חזרה גנרלית על הנתונים האמיתיים — כל קובץ המעבר רץ בטרנזקציה אחת, ובסוף נזרקת שגיאה מכוונת
#      שמבטלת הכול (במקום commit). שום דבר לא נשמר. הדוח מוחזר בהודעת השגיאה.
# ---- smtptest: קריאת הגדרות Auth בלבד + מייל בדיקה אחד דרך Brevo לתיבת האפליקציה. לא נוגע במשתמשים או בהגדרות.
if [ "$MODE" = "smtptest" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  C=$(authget); [ "$C" = 200 ] || stop "קריאת הגדרות Auth: HTTP $C"
  ann notice "prod-auth" "$(authsummary)"
  CMP=$(BK="$KEY" python3 -I - /tmp/cfg.json <<'PY'
import json,os,sys
c=json.load(open(sys.argv[1])); k=os.environ.get("BK","")
exp={"smtp_host":"smtp-relay.brevo.com","smtp_port":"587","smtp_user":"be5ab9001@smtp-brevo.com","smtp_admin_email":"life.through.numbers333@gmail.com","smtp_sender_name":"חיים דרך מספרים"}
out=[]
for f,v in exp.items():
    got=c.get(f); out.append(("✅" if str(got)==v else "❌")+f" {f}" + ("" if str(got)==v else f" (עכשיו: {got})"))
p=c.get("smtp_pass") or ""
if not p: out.append("❌ סיסמת SMTP לא מוגדרת")
elif p==k: out.append("✅ סיסמת SMTP זהה למפתח שנבדק")
elif p==k.strip(): out.append("✅ סיסמת SMTP זהה למפתח שנבדק")
else: out.append(f"ℹ️ סיסמת SMTP מוגדרת (Supabase מחזיר אותה מוסתרת, אורך {len(p)}) — אי אפשר להשוות ישירות")
out.append(f"ℹ️ smtp_max_frequency={c.get('smtp_max_frequency')} rate_limit_email_sent={c.get('rate_limit_email_sent')} confirm_email_on={c.get('mailer_autoconfirm') is False}")
print(" | ".join(out))
PY
)
  ann notice "prod-smtp-compare" "$CMP"
  SEND=$(BK="$KEY" python3 -I - <<'PY'
import os,smtplib,ssl,email.utils
from email.message import EmailMessage
k=os.environ["BK"].strip()
m=EmailMessage(); m["From"]=email.utils.formataddr(("חיים דרך מספרים","life.through.numbers333@gmail.com"))
m["To"]="life.through.numbers333@gmail.com"; m["Subject"]="בדיקת מייל — חיים דרך מספרים (Production)"
m["Date"]=email.utils.formatdate(localtime=True); m["Message-ID"]=email.utils.make_msgid(domain="smtp-brevo.com")
m.set_content("זהו מייל בדיקה מהגדרות ההשקה. אין צורך לעשות דבר.\nנשלח דרך Brevo SMTP עם אותם פרטים שהוגדרו ב-Supabase Production.")
try:
    s=smtplib.SMTP("smtp-relay.brevo.com",587,timeout=30); s.ehlo(); s.starttls(context=ssl.create_default_context()); s.ehlo()
    s.login("be5ab9001@smtp-brevo.com",k); r=s.send_message(m); s.quit()
    print("✅ Brevo קיבל את המייל לשליחה" + (f" (נדחו: {list(r)})" if r else ""))
except Exception as e: print(f"❌ {type(e).__name__}: {getattr(e,'smtp_code','')} {str(getattr(e,'smtp_error',''))[:200]}")
PY
)
  ann notice "prod-smtp-send" "$SEND"
  ann notice "prod-result" "smtptest הסתיים — לא שונו הגדרות, משתמשים או נתונים"
  exit 0
fi

# ---- supamail: מייל אמיתי דרך Supabase — בקשת "שכחתי סיסמה" לחשבון של הבעלים בלבד (מזוהה לפי md5 של האימייל, האימייל לא כתוב בריפו).
#      הסיסמה לא משתנה; Supabase רק שולח קישור איפוס. לא נוגע בפרופילים, בנתונים או בהגדרות.
if [ "$MODE" = "supamail" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  C=$(authget); [ "$C" = 200 ] || stop "קריאת הגדרות Auth: HTTP $C"
  SN=$(jq -r '.smtp_sender_name // ""' /tmp/cfg.json)
  [ "$SN" = "חיים דרך מספרים" ] && ann notice "prod-sender-name" "✅ Sender name בדיוק: חיים דרך מספרים" || ann error "prod-sender-name" "❌ Sender name: $SN"
  ann notice "prod-auth" "$(authsummary)"
  OWNER_MD5='162e004328485070b0af8b256ad2e798'
  C=$(curl -sS -m 30 -o /tmp/ow.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" \
      -d "$(jq -nc --arg h "$OWNER_MD5" '{query:("select email, recovery_sent_at from auth.users where md5(lower(email)) = '"'"'" + $h + "'"'"'")}')" || echo 000)
  OE=$(jq -r '.[0].email // empty' /tmp/ow.json 2>/dev/null); BEFORE_RS=$(jq -r '.[0].recovery_sent_at // "null"' /tmp/ow.json 2>/dev/null)
  [ -n "$OE" ] || stop "לא נמצא חשבון Auth לאימייל של הבעלים (HTTP $C). לא נשלח מייל."
  echo "::add-mask::$OE"; ann notice "prod-owner" "✅ נמצא חשבון הבעלים (האימייל לא מודפס)"
  PUB='sb_publishable_wwoXFH3xChSfQxHKZEbTKA_t_u5aGMP'
  RC=$(curl -sS -m 40 -o /tmp/rc.json -w '%{http_code}' -X POST -H "apikey: $PUB" -H 'Content-Type: application/json' \
       "https://$PROD_REF.supabase.co/auth/v1/recover?redirect_to=$(jq -rn --arg s "$SITE" '$s|@uri')" -d "$(jq -nc --arg e "$OE" '{email:$e}')" || echo 000)
  RM=$(jq -r '.msg // .message // .error_description // .error // empty' /tmp/rc.json 2>/dev/null | cut -c1-300)
  sleep 5
  curl -sS -m 30 -o /tmp/ow2.json -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" \
      -d "$(jq -nc --arg h "$OWNER_MD5" '{query:("select recovery_sent_at, (recovery_sent_at > now() - interval '"'"'3 minutes'"'"') as just_sent from auth.users where md5(lower(email)) = '"'"'" + $h + "'"'"'")}')" || true
  JS=$(jq -r '.[0].just_sent // "?"' /tmp/ow2.json 2>/dev/null)
  if [ "$RC" = 200 ] && [ "$JS" = "true" ]; then ann notice "prod-supamail" "✅ Supabase שלח מייל איפוס דרך Brevo (HTTP 200, נרשם זמן שליחה עכשיו). הסיסמה לא שונתה."
  else ann error "prod-supamail" "❌ שליחה דרך Supabase: HTTP $RC $RM | נרשם עכשיו: $JS"; fi
  ann notice "prod-result" "supamail הסתיים — לא שונו סיסמאות, נתונים או הגדרות"
  exit 0
fi

if [ "$MODE" = "export" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/export.sh"; exit 0
fi

# ---- maildiag: אבחון מיילים — קריאה בלבד. יומני Auth של Supabase, יומן הפעולות, מדיניות DMARC של Gmail, ותשובת Brevo המלאה.
if [ "$MODE" = "maildiag" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  scrub(){ sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g'; }
  S=$(date -u -d '-8 hours' +%Y-%m-%dT%H:%M:%SZ); E=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  C=$(curl -sS -m 60 -G -o /tmp/lg.json -w '%{http_code}' -H "Authorization: Bearer $TOK" \
      "https://api.supabase.com/v1/projects/$PROD_REF/analytics/endpoints/logs.all" \
      --data-urlencode "iso_timestamp_start=$S" --data-urlencode "iso_timestamp_end=$E" \
      --data-urlencode "sql=select timestamp, event_message from auth_logs where regexp_contains(lower(event_message), 'mail|smtp|recover|send') order by timestamp desc limit 40" || echo 000)
  ann notice "prod-authlogs" "HTTP $C $( (jq -r '(.result // [])[] | ((.timestamp|tostring) + " " + (.event_message|tostring))' /tmp/lg.json 2>/dev/null || cat /tmp/lg.json) | scrub | cut -c1-400 | head -40)"
  C=$(curl -sS -m 30 -o /tmp/au.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" \
      -d '{"query":"select to_char(created_at at time zone '"'"'Asia/Jerusalem'"'"','"'"'HH24:MI:SS'"'"') as t, payload->>'"'"'action'"'"' as action, payload->>'"'"'log_type'"'"' as type from auth.audit_log_entries where created_at > now() - interval '"'"'10 hours'"'"' order by created_at desc limit 25"}' || echo 000)
  ann notice "prod-audit" "HTTP $C $(jq -c '.' /tmp/au.json 2>/dev/null | cut -c1-2000)"
  ann notice "prod-dmarc" "gmail.com: $(dig +short TXT _dmarc.gmail.com | tr -d '\n') | brevo SPF include: $(dig +short TXT spf.brevo.com | head -1)"
  SEND=$(BK="$KEY" python3 -I - <<'PY'
import os,smtplib,ssl,email.utils
from email.message import EmailMessage
k=os.environ["BK"].strip(); out=[]
m=EmailMessage(); m["From"]=email.utils.formataddr(("חיים דרך מספרים","life.through.numbers333@gmail.com"))
m["To"]="life.through.numbers333@gmail.com"; m["Subject"]="אבחון משלוח — חיים דרך מספרים"
m["Date"]=email.utils.formatdate(localtime=True); m["Message-ID"]=email.utils.make_msgid(domain="smtp-brevo.com")
m.set_content("מייל אבחון. אין צורך לעשות דבר.")
try:
    s=smtplib.SMTP("smtp-relay.brevo.com",587,timeout=30); s.ehlo(); s.starttls(context=ssl.create_default_context()); s.ehlo()
    s.login("be5ab9001@smtp-brevo.com",k)
    c,msg=s.mail("life.through.numbers333@gmail.com"); out.append(f"MAIL FROM {c} {msg.decode(errors='replace')[:120]}")
    c,msg=s.rcpt("life.through.numbers333@gmail.com"); out.append(f"RCPT {c} {msg.decode(errors='replace')[:120]}")
    c,msg=s.data(m.as_bytes()); out.append(f"DATA {c} {msg.decode(errors='replace')[:200]}")
    s.quit()
except Exception as e: out.append(f"ERR {type(e).__name__} {getattr(e,'smtp_code','')} {str(getattr(e,'smtp_error',e))[:200]}")
print(" | ".join(out))
PY
)
  ann notice "prod-brevo-smtp" "$SEND"
  ann notice "prod-result" "maildiag הסתיים — קריאה בלבד + מייל אבחון אחד לתיבת האפליקציה"
  exit 0
fi

# ---- ownertest: מייל ישיר דרך Brevo (בלי Supabase) לכתובת של חשבון הבעלים + הגדרות האיפוס. קריאה בלבד מלבד המייל.
if [ "$MODE" = "ownertest" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  OWNER_MD5='162e004328485070b0af8b256ad2e798'
  curl -sS -m 30 -o /tmp/ow.json -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" \
      -d "$(jq -nc --arg h "$OWNER_MD5" '{query:("select email, to_char(recovery_sent_at at time zone '"'"'Asia/Jerusalem'"'"','"'"'HH24:MI:SS'"'"') as rs, email_confirmed_at is not null as confirmed, banned_until, (raw_app_meta_data->>'"'"'provider'"'"') as provider from auth.users where md5(lower(email)) = '"'"'" + $h + "'"'"'")}')" || true
  OE=$(jq -r '.[0].email // empty' /tmp/ow.json); [ -n "$OE" ] || stop "חשבון הבעלים לא נמצא"
  echo "::add-mask::$OE"
  ann notice "prod-owner-auth" "$(jq -c '.[0] | del(.email)' /tmp/ow.json) | domain=$(printf '%s' "$OE" | sed 's/.*@//')"
  C=$(authget); ann notice "prod-recovery-cfg" "$(jq -c '{site_url, uri_allow_list, mailer_subjects_recovery, recovery_template_custom: ((.mailer_templates_recovery_content // "") != ""), smtp_max_frequency, rate_limit_email_sent, mailer_secure_email_change_enabled}' /tmp/cfg.json)"
  SEND=$(BK="$KEY" OE="$OE" python3 -I - <<'PY'
import os,smtplib,ssl,email.utils
from email.message import EmailMessage
k=os.environ["BK"].strip(); to=os.environ["OE"]; out=[]
m=EmailMessage(); m["From"]=email.utils.formataddr(("חיים דרך מספרים","life.through.numbers333@gmail.com"))
m["To"]=to; m["Subject"]="בדיקת משלוח לכתובת החשבון — חיים דרך מספרים"
m["Date"]=email.utils.formatdate(localtime=True); m["Message-ID"]=email.utils.make_msgid(domain="smtp-brevo.com")
m.set_content("מייל בדיקה ישיר דרך Brevo לכתובת שאיתה את/ה מתחבר/ת לאפליקציה. אין צורך לעשות דבר.")
try:
    s=smtplib.SMTP("smtp-relay.brevo.com",587,timeout=30); s.ehlo(); s.starttls(context=ssl.create_default_context()); s.ehlo()
    s.login("be5ab9001@smtp-brevo.com",k)
    c,msg=s.mail("life.through.numbers333@gmail.com"); out.append(f"MAIL {c}")
    c,msg=s.rcpt(to); out.append(f"RCPT {c} {msg.decode(errors='replace')[:60].replace(to,'<owner>')}")
    c,msg=s.data(m.as_bytes()); out.append(f"DATA {c} {msg.decode(errors='replace')[:120]}")
    s.quit()
except Exception as e: out.append(f"ERR {type(e).__name__} {getattr(e,'smtp_code','')}")
print(" | ".join(out))
PY
)
  ann notice "prod-owner-direct" "$SEND"
  ann notice "prod-result" "ownertest הסתיים — מייל ישיר אחד לכתובת החשבון, בלי שינוי בהגדרות או בנתונים"
  exit 0
fi

# ---- fingerprint: קריאה בלבד — זהות הפרויקט, האם המעבר כבר רץ, וטביעת אצבע של docs להשוואה לגיבוי
if [ "$MODE" = "fingerprint" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  C=$(curl -sS -m 30 -o /tmp/fp.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" \
      -d '{"query":"select current_setting('"'"'cluster_name'"'"', true) as cluster, (to_regclass('"'"'public.hdm_staging_marker'"'"') is null) as not_staging, (to_regclass('"'"'public.hdm_release_marker'"'"') is null and to_regclass('"'"'hdm_backup.docs_before_migration'"'"') is null) as not_migrated, (select md5(string_agg(collection||'"'"'|'"'"'||id||'"'"'|'"'"'||data::text, '"'"','"'"' order by collection, id)) from public.docs) as docs_md5, (select count(*) from public.docs) as n, (select count(*) from auth.users) as auth_users"}' || echo 000)
  ann notice "prod-fingerprint" "HTTP $C project=$PROD_REF $(jq -c '.[0]' /tmp/fp.json 2>/dev/null)"
  ann notice "prod-result" "fingerprint הסתיים — קריאה בלבד"
  exit 0
fi

if [ "$MODE" = "billingdeploy" ] || [ "$MODE" = "billingdeploycheck" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/billing_deploy.sh"; exit 0
fi

if [ "$MODE" = "cronnow" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/cron_now.sh"; exit 0
fi

if [ "$MODE" = "stagearehearse" ] || [ "$MODE" = "stageaapply" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/stage_a.sh"; exit 0
fi

if [ "$MODE" = "ownercardsync" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/owner_card_link_sub.sh"; exit 0
fi

if [ "$MODE" = "cardlink" ]; then
  source "$HERE/card_link.sh"; exit 0
fi

if [ "$MODE" = "paycheck" ] || [ "$MODE" = "payreplay" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/pay_replay.sh"; exit 0
fi

if [ "$MODE" = "secretfix" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/secret_fix.sh"; exit 0
fi

if [ "$MODE" = "launchcheck" ]; then
  source "$HERE/launch_check.sh"; exit 0
fi
if [ "$MODE" = "hideapply" ]; then
  source "$HERE/hide_apply.sh"; exit 0
fi
if [ "$MODE" = "adminpreview" ]; then
  source "$HERE/admin_preview.sh"; exit 0
fi
if [ "$MODE" = "hiderehearse" ]; then
  source "$HERE/hide_rehearse.sh"; exit 0
fi
if [ "$MODE" = "ownerhidecheck" ]; then
  source "$HERE/owner_hide_check.sh"; exit 0
fi
if [ "$MODE" = "adminapply" ]; then
  source "$HERE/admin_apply.sh"; exit 0
fi
if [ "$MODE" = "adminrehearse" ]; then
  source "$HERE/admin_rehearse.sh"; exit 0
fi
if [ "$MODE" = "incidentnine" ]; then
  source "$HERE/incident9.sh"; exit 0
fi
if [ "$MODE" = "incidenteight" ]; then
  source "$HERE/incident8.sh"; exit 0
fi
if [ "$MODE" = "incidentseven" ]; then
  source "$HERE/incident7.sh"; exit 0
fi
if [ "$MODE" = "incidentsix" ]; then
  source "$HERE/incident6.sh"; exit 0
fi
if [ "$MODE" = "incidentfive" ]; then
  source "$HERE/incident5.sh"; exit 0
fi
if [ "$MODE" = "incidentfour" ]; then
  source "$HERE/readiness_brevo.sh" 2>/dev/null || true
  source "$HERE/incident4.sh"; exit 0
fi
if [ "$MODE" = "incidentthree" ]; then
  source "$HERE/incident3.sh"; exit 0
fi
if [ "$MODE" = "incidenttwo" ]; then
  source "$HERE/incident2.sh"; exit 0
fi
if [ "$MODE" = "incident" ]; then
  source "$HERE/incident.sh"; exit 0
fi
if [ "$MODE" = "stagecapply" ]; then
  source "$HERE/stage_c_apply.sh"; exit 0
fi
if [ "$MODE" = "stagecrehearse" ]; then
  source "$HERE/stage_c_rehearse.sh"; exit 0
fi
if [ "$MODE" = "readiness" ]; then
  source "$HERE/readiness.sh"; exit 0
fi
if [ "$MODE" = "secretcmp" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/secret_cmp.sh"; exit 0
fi

if [ "$MODE" = "paydiag" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/pay_diag.sh"; exit 0
fi

if [ "$MODE" = "vipsoon" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/vip_soon.sh"; exit 0
fi

if [ "$MODE" = "backupdrop" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/backup_drop.sh"; exit 0
fi

if [ "$MODE" = "purgerehearse" ] || [ "$MODE" = "purgeapply" ] || [ "$MODE" = "purgerehearsedina" ] || [ "$MODE" = "purgerehearseleftovers" ] || [ "$MODE" = "purgeapplyleftovers" ] || [ "$MODE" = "purgeapplydina" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/purge.sh"; exit 0
fi

if [ "$MODE" = "ownerverifyfree" ]; then
  REVERIFY=1 source "$HERE/owner_free.sh"; exit 0
fi

if [ "$MODE" = "ownerfree" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/owner_free.sh"; exit 0
fi

if [ "$MODE" = "secureread" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/secure_read.sh"; exit 0
fi

if [ "$MODE" = "ownercheck" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/owner_check.sh"; exit 0
fi

if [ "$MODE" = "cronrehearse" ] || [ "$MODE" = "cronapply" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/billing_cron.sh"; exit 0
fi

if [ "$MODE" = "billingtests" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/billing_tests.sh"; exit 0
fi

if [ "$MODE" = "billingprep" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/billing_prep.sh"; exit 0
fi

if [ "$MODE" = "simulate" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  source "$HERE/simulate.sh"; exit 0
fi

if [ "$MODE" = "rehearse" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  Q=$(python3 -I - "$ROOT/supabase/production/01_production_migration.sql" <<'PY'
import sys
src=open(sys.argv[1],encoding='utf-8').read()
head,sep,_=src.partition('\ncommit;\n')
assert sep, 'no commit'
print(head + r"""
do $hdm$ begin
  raise exception 'HDM_REHEARSAL_OK profiles=% private=% no_birthdate=% legacy=% review=% legacy_chats=% subs=% policies=% backup_rows=%',
    (select count(*) from public.docs where collection='profiles'),
    (select count(*) from public.hdm_profile_private),
    (select count(*) from public.hdm_profile_private where birthdate is null),
    (select count(*) from public.hdm_legacy_accounts),
    (select count(distinct profile_id) from public.hdm_legacy_review),
    (select count(*) from public.hdm_chat_openings where plan='legacy'),
    (select count(*) from public.hdm_subscriptions),
    (select count(*) from pg_policies where schemaname='public'),
    (select count(*) from hdm_backup.docs_before_migration);
end $hdm$;
rollback;
""")
PY
) || stop "בניית החזרה נכשלה"
  C=$(curl -sS -m 120 -o /tmp/rh.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
      "https://api.supabase.com/v1/projects/$PROD_REF/database/query" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
  MSG=$(jq -r '.message // tostring' /tmp/rh.json 2>/dev/null | cut -c1-1500)
  case "$MSG" in *HDM_REHEARSAL_OK*) ann notice "prod-rehearse" "✅ החזרה הצליחה (בוטלה, לא נשמר כלום): $(printf '%s' "$MSG" | grep -o 'HDM_REHEARSAL_OK[^"]*' | head -1)";;
                 *) ann error "prod-rehearse" "❌ החזרה נעצרה לפני הסוף (לא נשמר כלום): HTTP $C $MSG";; esac
  C=$(curl -sS -m 30 -o /tmp/mk.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
      "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" \
      -d '{"query":"select (to_regclass('"'"'public.hdm_release_marker'"'"') is null) as not_migrated, (to_regclass('"'"'hdm_backup.docs_before_migration'"'"') is null) as no_new_backup, (select count(*) from public.docs) as docs_rows, (select count(*) from auth.users) as auth_users, (to_regclass(\u0027public.hdm_profile_private\u0027) is null) as no_new_tables, (select count(*) from pg_policies where schemaname=\u0027public\u0027 and tablename=\u0027docs\u0027) as docs_policies, (select md5(string_agg(collection||\u0027|\u0027||id||\u0027|\u0027||data::text, \u0027,\u0027 order by collection, id)) from public.docs) as docs_md5"}' || echo 000)
  ann notice "prod-rehearse-after" "אימות שלא נשמר כלום: HTTP $C $(jq -c '.[0] // .' /tmp/mk.json 2>/dev/null)"
  ann notice "prod-result" "rehearse הסתיים — שום שינוי לא נשמר"
  exit 0
fi

# ---- smoke: בדיקת עשן לאתר החי בדפדפן. לא יוצרת חשבון ולא כותבת נתונים (בקשות הרשמה נחסמות בדפדפן).
if [ "$MODE" = "smoke" ]; then
  python3 -m pip install -q playwright >/dev/null && python3 -m playwright install --with-deps chromium >/dev/null 2>&1 || stop "התקנת הדפדפן נכשלה"
  export SMOKE_OUT="${RUNNER_TEMP:-/tmp}/smoke"
  set +e; OUT=$(python3 "$HERE/smoke.py" 2>&1); RC=$?; set -e
  ann notice "prod-smoke" "$(printf '%s' "$OUT" | tail -c 3500)"
  [ $RC = 0 ] && ann notice "prod-result" "✅ smoke: כל הבדיקות עברו (לא נוצר חשבון, לא נכתבו נתונים)" || stop "smoke: בדיקה אחת או יותר נכשלה (לא נוצר חשבון)"
  exit 0
fi

# ---- plusext: מריץ את 07 (פלוס בלי ניתוח מורחב) — אותו קובץ שרץ ב-Staging. משנה את Production — רק באישור הבעלים.
if [ "$MODE" = "plusext" ]; then
  F07="$ROOT/supabase/production/07_production_plus_no_extended.sql"
  ann notice "prod-plusext-file" "sha256 $(sha256sum "$F07" | cut -c1-16)"
  Q=$(cat "$F07")
  C=$(curl -sS -m 60 -o /tmp/px.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
  ann notice "prod-plusext" "HTTP $C $(jq -c '.' /tmp/px.json 2>/dev/null | cut -c1-600)"
  { [ "$C" = 200 ] || [ "$C" = 201 ]; } || stop "07 נכשל — שום דבר לא נשמר (הכול או כלום). HTTP $C"
  V="select jsonb_build_object('plans', (select jsonb_agg(jsonb_build_object('plan',plan,'price',price_agorot,'rate',can_rate,'details',rating_details,'chats',monthly_new_chats,'extended',extended_analysis,'discount',limor_discount_pct) order by sort_order) from public.hdm_plans)) as r"
  C=$(curl -sS -m 60 -o /tmp/pv.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" -d "$(jq -nc --arg q "$V" '{query:$q}')" || echo 000)
  ann notice "prod-plusext-verify" "HTTP $C $(jq -c 'if type=="array" then .[0].r else . end' /tmp/pv.json 2>/dev/null)"
  ann notice "prod-result" "✅ plusext הסתיים"
  exit 0
fi

# ---- testcleanup: מוחק רק את חשבון הבדיקה הלא מאומת שנשאר מבדיקת הקצה (05). אחריו testcheck לקריאה בלבד.
if [ "$MODE" = "testcleanup" ]; then
  Q=$(cat "$ROOT/supabase/production/05_cleanup_e2e_test_user.sql")
  C=$(curl -sS -m 60 -o /tmp/tc.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
  ann notice "prod-testcleanup" "HTTP $C $(jq -c '.' /tmp/tc.json 2>/dev/null | cut -c1-600)"
  { [ "$C" = 200 ] || [ "$C" = 201 ]; } || stop "testcleanup נכשל — שום דבר לא נשמר. HTTP $C"
  MODE=testcheck
fi

# ---- testcheck: קריאה בלבד — מה נשאר מחשבונות בדיקת הקצה (דומיין זמני), והאם תאריך לידה חשוף בפרופיל ציבורי
if [ "$MODE" = "testcheck" ]; then
  Q=$(cat <<'SQL'
select jsonb_build_object(
 'auth_users_total', (select count(*) from auth.users),
 'test_auth_users', (select coalesce(jsonb_agg(jsonb_build_object('domain', split_part(email,'@',2), 'confirmed', email_confirmed_at is not null, 'created', created_at, 'profile', raw_app_meta_data->>'profile_id', 'meta_profile', raw_user_meta_data->>'profileId')), '[]') from auth.users where email like 'hdmtest%'),
 'test_profiles', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', data->>'currentName', 'public_keys', (select jsonb_agg(k) from jsonb_object_keys(data) k))), '[]') from public.docs where collection='profiles' and data->>'currentName'='בדיקת מערכת'),
 'test_private', (select count(*) from public.hdm_profile_private p join public.docs d on d.id=p.profile_id and d.collection='profiles' where d.data->>'currentName'='בדיקת מערכת'),
 'any_public_profile_with_birth', (select count(*) from public.docs where collection='profiles' and data ?| array['birthdate','birthFirstName','birthLastName']),
 'profiles_total', (select count(*) from public.docs where collection='profiles'),
 'subs_total', (select count(*) from public.hdm_subscriptions)
) as r
SQL
)
  C=$(curl -sS -m 60 -o /tmp/e2.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
  ann notice "prod-testcheck" "HTTP $C $(jq -c 'if type=="array" then .[0].r else . end' /tmp/e2.json 2>/dev/null | cut -c1-3500)"
  ann notice "prod-result" "testcheck הסתיים — קריאה בלבד"
  exit 0
fi

# ---- advisors: קריאה בלבד — יועץ האבטחה והביצועים של Supabase + זיהוי איזה טוקן מה מותר לו. לא משנה כלום.
if [ "$MODE" = "advisors" ]; then
  for nm in TOK OLDTOK; do t="${!nm}"; [ -n "$t" ] || continue
    for kind in security performance; do
      C=$(curl -sS -m 60 -o /tmp/adv.json -w '%{http_code}' -H "Authorization: Bearer $t" "https://api.supabase.com/v1/projects/$PROD_REF/advisors/$kind" || echo 000)
      if [ "$C" = 200 ]; then
        ann notice "prod-advisors-$kind" "($nm) $(jq -c '[.lints[]? | {level, name}] | group_by(.level+"|"+.name) | map({level: .[0].level, name: .[0].name, count: length})' /tmp/adv.json | cut -c1-3000) || WARN/ERROR non-function details: $(jq -c '[.lints[]? | select(.level!="INFO" and .name!="authenticated_security_definer_function_executable") | {level, name, detail: (.detail|tostring|.[0:220])}]' /tmp/adv.json | cut -c1-3000)"
        break 2
      else ann notice "prod-advisors-$kind-$nm" "HTTP $C $(jq -r '.message // empty' /tmp/adv.json 2>/dev/null | cut -c1-200)"; fi
    done
  done
  C=$(curl -sS -m 30 -o /tmp/adv2.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "https://api.supabase.com/v1/projects/$PROD_REF/advisors/performance" || echo 000)
  ann notice "prod-advisors-performance" "HTTP $C $(jq -c '[.lints[]? | select(.level!="INFO") | {level, name, title}] | unique' /tmp/adv2.json 2>/dev/null | cut -c1-2000)"
  ann notice "prod-result" "advisors הסתיים — קריאה בלבד"
  exit 0
fi

# ---- confirmplan: קריאה בלבד — מוכנות להפעלת Confirm email. לא משנה הגדרות, לא שולח מייל.
if [ "$MODE" = "confirmplan" ]; then
  # 1) הגדרות Auth (בטוקן הישן, שיש לו auth_config_read)
  if [ -n "$OLDTOK" ]; then
    C=$(curl -sS -m 30 -o /tmp/cfg.json -w '%{http_code}' -H "Authorization: Bearer $OLDTOK" "$API" || echo 000)
    if [ "$C" = 200 ]; then
      ann notice "prod-confirm-auth" "$(authsummary)"
      ann notice "prod-confirm-mail" "$(jq -c '{mailer_subjects_confirmation, confirmation_template_custom: ((.mailer_templates_confirmation_content // "") != ""), confirmation_has_link: ((.mailer_templates_confirmation_content // "") | test("ConfirmationURL|TokenHash|\\.Token")), recovery_template_custom: ((.mailer_templates_recovery_content // "") != ""), mailer_otp_exp, smtp_max_frequency, external_email_enabled, disable_signup, mailer_secure_email_change_enabled, rate_limit_email_sent}' /tmp/cfg.json)"
    else ann error "prod-confirm-auth" "קריאת הגדרות Auth: HTTP $C $(jq -r '.message // empty' /tmp/cfg.json 2>/dev/null)"; fi
  else ann warning "prod-confirm-auth" "אין טוקן לקריאת הגדרות Auth"; fi
  # 2) התחברות ל-Brevo SMTP בלי לשלוח מייל
  if [ -n "$KEY" ]; then
    L=$(BK="$KEY" python3 -I - <<'PY2'
import os,smtplib,ssl
k=os.environ["BK"].strip()
try:
    s=smtplib.SMTP("smtp-relay.brevo.com",587,timeout=20); s.ehlo(); s.starttls(context=ssl.create_default_context()); s.ehlo()
    s.login("be5ab9001@smtp-brevo.com",k); s.quit(); print("✅ ההתחברות ל-Brevo SMTP הצליחה (לא נשלח מייל)")
except smtplib.SMTPAuthenticationError as e: print(f"❌ Brevo דחה את ההתחברות: {e.smtp_code}")
except Exception as e: print(f"❌ שגיאת חיבור: {type(e).__name__}")
PY2
)
    ann notice "prod-confirm-smtp" "$L"
  fi
  # 3) האם 4 המשתמשים הקיימים מאומתים (Confirm email חוסם רק משתמשים לא מאומתים)
  Q=$(cat <<'SQL'
select jsonb_build_object(
 'auth_users', (select count(*) from auth.users),
 'confirmed', (select count(*) from auth.users where email_confirmed_at is not null),
 'unconfirmed', (select count(*) from auth.users where email_confirmed_at is null),
 'banned', (select count(*) from auth.users where banned_until is not null and banned_until > now()),
 'per_user', (select jsonb_agg(jsonb_build_object('name', d.data->>'currentName', 'confirmed', u.email_confirmed_at is not null, 'domain', split_part(u.email,'@',2), 'last_sign_in', u.last_sign_in_at) order by d.data->>'currentName')
               from auth.users u left join public.hdm_legacy_accounts l on l.email = lower(u.email) left join public.docs d on d.collection='profiles' and d.id=l.profile_id)
) as r
SQL
)
  C=$(curl -sS -m 60 -o /tmp/cu.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
  ann notice "prod-confirm-users" "HTTP $C $(jq -c 'if type=="array" then .[0].r else . end' /tmp/cu.json 2>/dev/null)"
  ann notice "prod-result" "confirmplan הסתיים — קריאה בלבד, לא נשלח מייל ולא שונו הגדרות"
  exit 0
fi

# ---- emailfix: תיקון .con → .com לפרופיל נועה בלבד (04). משנה את Production — רק באישור הבעלים. אחריו אימות לקריאה בלבד.
if [ "$MODE" = "emailfix" ]; then
  [ -n "$TOK" ] || stop "חסר טוקן"
  Q=$(cat "$ROOT/supabase/production/04_fix_noa_email_domain.sql")
  C=$(curl -sS -m 60 -o /tmp/ef.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
  ann notice "prod-emailfix" "HTTP $C $(jq -c '.' /tmp/ef.json 2>/dev/null | cut -c1-1000)"
  { [ "$C" = 200 ] || [ "$C" = 201 ]; } || stop "emailfix נכשל — שום דבר לא נשמר (הכול או כלום). HTTP $C"
  V=$(cat <<'SQL'
select jsonb_build_object(
 'legacy_masked', (select left(email,2)||'***@'||split_part(email,'@',2) from public.hdm_legacy_accounts where profile_id='reg_muv7ffi3345nmx'),
 'auth_users_total', (select count(*) from auth.users),
 'auth_users_with_con', (select count(*) from auth.users where email ~ '\.con$'),
 'identities_with_con', (select count(*) from auth.identities where identity_data->>'email' ~ '\.con$'),
 'legacy_with_con', (select count(*) from public.hdm_legacy_accounts where email ~ '\.con$'),
 'noa_auth_users_matching_legacy', (select count(*) from public.hdm_legacy_accounts l join auth.users u on lower(u.email)=l.email where l.profile_id='reg_muv7ffi3345nmx'),
 'noa_identity_matches', (select count(*) from public.hdm_legacy_accounts l join auth.users u on lower(u.email)=l.email join auth.identities i on i.user_id=u.id and i.provider='email' and lower(i.identity_data->>'email')=l.email where l.profile_id='reg_muv7ffi3345nmx'),
 'noa_confirmed', (select u.email_confirmed_at is not null from public.hdm_legacy_accounts l join auth.users u on lower(u.email)=l.email where l.profile_id='reg_muv7ffi3345nmx'),
 'noa_plus', (select plan||'/'||status||'/'||coalesce(current_period_end::text,'never') from public.hdm_subscriptions where profile_id='reg_muv7ffi3345nmx')
) as r
SQL
)
  C=$(curl -sS -m 60 -o /tmp/ev.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" -d "$(jq -nc --arg q "$V" '{query:$q}')" || echo 000)
  ann notice "prod-emailfix-verify" "HTTP $C $(jq -c 'if type=="array" then .[0].r else . end' /tmp/ev.json 2>/dev/null)"
  ann notice "prod-result" "✅ emailfix הסתיים"
  exit 0
fi

# ---- emailcheck: קריאה בלבד — איפה מופיע האימייל השגוי (.con) של פרופיל נועה, והאם הכתובת המתוקנת תפוסה. כתובות מוסתרות.
if [ "$MODE" = "emailcheck" ]; then
  [ -n "$TOK" ] || stop "חסר טוקן"
  Q=$(cat <<'SQL'
with t as (select 'reg_muv7ffi3345nmx'::text as pid),
 a as (select l.email as bad, regexp_replace(l.email, '\.con$', '.com') as good from public.hdm_legacy_accounts l, t where l.profile_id = t.pid)
select jsonb_build_object(
 'profile_name', (select d.data->>'currentName' from public.docs d, t where d.collection='profiles' and d.id=t.pid),
 'legacy_email_ends_con', (select bad ~ '\.con$' from a),
 'legacy_masked', (select left(bad,2)||'***@'||split_part(bad,'@',2) from a),
 'auth_users_with_bad', (select count(*) from auth.users u, a where lower(u.email)=lower(a.bad)),
 'auth_user_meta_profile', (select jsonb_build_object('app', u.raw_app_meta_data - 'provider' - 'providers', 'user_profile', u.raw_user_meta_data->>'profile_id', 'confirmed', u.email_confirmed_at is not null, 'last_sign_in', u.last_sign_in_at) from auth.users u, a where lower(u.email)=lower(a.bad)),
 'identities_with_bad', (select count(*) from auth.identities i, a where lower(i.identity_data->>'email')=lower(a.bad)),
 'identities_provider', (select jsonb_agg(jsonb_build_object('provider', i.provider, 'provider_id_is_email', lower(i.provider_id)=lower(a.bad))) from auth.identities i, a where lower(i.identity_data->>'email')=lower(a.bad)),
 'docs_rows_containing_bad', (select jsonb_agg(jsonb_build_object('collection', d.collection, 'id_contains', position(lower(a.bad) in lower(d.id))>0)) from public.docs d, a where position(lower(a.bad) in lower(d.data::text))>0 or position(lower(a.bad) in lower(d.id))>0),
 'private_rows_containing_bad', (select count(*) from public.hdm_profile_private p, a where position(lower(a.bad) in lower(to_jsonb(p)::text))>0),
 'other_hdm_tables_containing_bad', (select count(*) from public.hdm_legacy_review r, a where position(lower(a.bad) in lower(to_jsonb(r)::text))>0),
 'conflict_auth_users_with_good', (select count(*) from auth.users u, a where lower(u.email)=lower(a.good)),
 'conflict_identities_with_good', (select count(*) from auth.identities i, a where lower(i.identity_data->>'email')=lower(a.good)),
 'conflict_legacy_with_good', (select count(*) from public.hdm_legacy_accounts l, a where lower(l.email)=lower(a.good)),
 'conflict_docs_with_good', (select count(*) from public.docs d, a where position(lower(a.good) in lower(d.data::text))>0 or position(lower(a.good) in lower(d.id))>0),
 'all_emails_ending_con', (select count(*) from auth.users where email ~ '\.con$')
) as r
SQL
)
  C=$(curl -sS -m 60 -o /tmp/ec.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
  ann notice "prod-emailcheck" "HTTP $C $(jq -c 'if type=="array" then .[0].r else . end' /tmp/ec.json 2>/dev/null | cut -c1-3500)"
  ann notice "prod-result" "emailcheck הסתיים — קריאה בלבד"
  exit 0
fi

# ---- plusapply: Plus ללא הגבלה ל-4 החשבונות הקיימים בלבד (03b). משנה את Production — רק באישור הבעלים.
if [ "$MODE" = "plusapply" ]; then
  [ -n "$TOK" ] || stop "חסר טוקן"
  Q=$(cat "$ROOT/supabase/production/03b_existing_accounts_plus_unlimited.sql")
  C=$(curl -sS -m 60 -o /tmp/pa.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
  ann notice "prod-plusapply" "HTTP $C $(jq -c '.' /tmp/pa.json 2>/dev/null | cut -c1-1500)"
  { [ "$C" = 200 ] || [ "$C" = 201 ]; } || stop "plusapply נכשל — שום דבר לא נשמר (הכול או כלום). HTTP $C"
  ann notice "prod-result" "✅ plusapply הסתיים"
  exit 0
fi

# ---- plusplan: קריאה בלבד — מצב 4 החשבונות הקיימים ומה ש-03_existing_accounts_plus.sql היה עושה. לא משנה כלום.
if [ "$MODE" = "plusplan" ]; then
  [ -n "$TOK" ] || stop "חסר טוקן"
  Q=$(cat <<'SQL'
select jsonb_build_object(
 'plus_plan', (select to_jsonb(p) from public.hdm_plans p where plan='plus'),
 'subscriptions_total', (select count(*) from public.hdm_subscriptions),
 'subscription_events_total', (select count(*) from public.hdm_subscription_events),
 'accounts', (select jsonb_agg(jsonb_build_object(
    'profile_id', a.profile_id,
    'name', d.data->>'currentName',
    'email_masked', left(a.email,2)||'***@'||split_part(a.email,'@',2),
    'profile_exists', d.id is not null,
    'auth_user_exists', exists(select 1 from auth.users u where lower(u.email)=lower(a.email)),
    'linked_at', a.linked_at,
    'current_plan', coalesce((select s.plan||' ('||s.status||')' from public.hdm_subscriptions s where s.profile_id=a.profile_id), 'free (no subscription row)'),
    'has_subscription_row', exists(select 1 from public.hdm_subscriptions s where s.profile_id=a.profile_id),
    'expires', (select coalesce(s.current_period_end::text,'never') from public.hdm_subscriptions s where s.profile_id=a.profile_id),
    'source', (select s.source from public.hdm_subscriptions s where s.profile_id=a.profile_id),
    'consent_given', exists(select 1 from public.hdm_consents c join auth.users u on u.id=c.user_id where lower(u.email)=lower(a.email)),
    'would_get_plus', (d.id is not null and not exists(select 1 from public.hdm_subscriptions s where s.profile_id=a.profile_id))
   ) order by d.data->>'currentName') from public.hdm_legacy_accounts a left join public.docs d on d.collection='profiles' and d.id=a.profile_id),
 'profiles_without_legacy_account', (select coalesce(jsonb_agg(d.id), '[]') from public.docs d where d.collection='profiles' and not exists(select 1 from public.hdm_legacy_accounts a where a.profile_id=d.id))
) as r
SQL
)
  C=$(curl -sS -m 60 -o /tmp/pp.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
  ann notice "prod-plusplan" "HTTP $C $(jq -c 'if type=="array" then .[0].r else . end' /tmp/pp.json 2>/dev/null | cut -c1-3500)"
  ann notice "prod-result" "plusplan הסתיים — קריאה בלבד"
  exit 0
fi

# ---- postcheck: קריאה בלבד — אימות אחרי המעבר מול הגיבוי הפנימי (hdm_backup.docs_before_migration)
if [ "$MODE" = "postcheck" ]; then
  [ -n "$TOK" ] || stop "חסר טוקן"
  Q=$(cat <<'SQL'
select
 (to_regclass('public.hdm_release_marker') is not null) as migrated,
 (select jsonb_object_agg(collection, n) from (select collection, count(*) n from public.docs group by 1) x) as by_collection_now,
 (select jsonb_object_agg(collection, n) from (select collection, count(*) n from hdm_backup.docs_before_migration group by 1) x) as by_collection_before,
 (select count(*) from hdm_backup.docs_before_migration b where not exists (select 1 from public.docs d where d.collection=b.collection and d.id=b.id)) as missing_rows,
 (select count(*) from hdm_backup.docs_before_migration b join public.docs d using (collection, id) where b.collection in ('chats','matches','chatReads','reports') and d.data is distinct from b.data) as changed_chats_matches,
 (select count(*) from auth.users) as auth_users,
 (select md5(string_agg(id::text, ',' order by id::text collate "C")) from auth.users) as auth_ids_md5,
 (select md5(string_agg(collection||'|'||id, ',' order by (collection||'|'||id) collate "C")) from public.docs where collection <> 'interests') as ids_md5_non_interests,
 (select count(*) from public.hdm_profile_private) as private_rows,
 (select count(*) from public.hdm_profile_private where birthdate is null) as private_no_birthdate,
 (select count(*) from public.hdm_legacy_accounts) as legacy_accounts,
 (select count(*) from pg_policies where schemaname='public') as policies,
 (select count(*) from public.docs where collection='profiles' and data ?| array['birthdate','birthFirstName','birthLastName']) as visible_birth_data
SQL
)
  C=$(curl -sS -m 60 -o /tmp/pc.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
  ann notice "prod-postcheck" "HTTP $C $(jq -c '.[0] // .' /tmp/pc.json 2>/dev/null | cut -c1-3000)"
  ann notice "prod-result" "postcheck הסתיים — קריאה בלבד"
  exit 0
fi

if [ "$MODE" = "migrate" ]; then
  if [ ${#PSQL[@]} -gt 0 ]; then
    OUT=$("${PSQL[@]}" -f "$ROOT/supabase/production/01_production_migration.sql" 2>&1) || { ann error "prod-migrate" "$(printf '%s' "$OUT" | tail -20)"; stop "המעבר נכשל — שום דבר לא נשמר (הכול או כלום)."; }
    ann notice "prod-migrate" "$(printf '%s' "$OUT" | tail -40)"
  else
    [ -n "$TOK" ] || stop "חסר PRODUCTION_DB_URL וגם PRODUCTION_SUPABASE_TOKEN"
    Q=$(cat "$ROOT/supabase/production/01_production_migration.sql")
    C=$(curl -sS -m 180 -o /tmp/mg.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
        "https://api.supabase.com/v1/projects/$PROD_REF/database/query" -d "$(jq -nc --arg q "$Q" '{query:$q}')" || echo 000)
    ann notice "prod-migrate" "HTTP $C $(jq -c '.' /tmp/mg.json 2>/dev/null | cut -c1-1500)"
    C2=$(curl -sS -m 30 -o /tmp/mk.json -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
        "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" -d '{"query":"select (to_regclass(\u0027public.hdm_release_marker\u0027) is not null) as migrated"}' || echo 000)
    [ "$(jq -r '.[0].migrated // empty' /tmp/mk.json 2>/dev/null)" = "true" ] || stop "המעבר לא הושלם — שום דבר לא נשמר (הכול או כלום). HTTP $C"
  fi
  ann notice "prod-result" "✅ migrate: המעבר הושלם. השלב הבא: מיזוג PR #21 (באישור)."
  exit 0
fi

if [ "$MODE" = "confirmon" ]; then
  [ -n "$TOK" ] || stop "חסר PRODUCTION_SUPABASE_TOKEN"
  PC=$(curl -sS -m 30 -o /tmp/patch.json -w '%{http_code}' -X PATCH -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$API" -d '{"mailer_autoconfirm":false}' || echo 000)
  [ "$PC" = 200 ] || stop "הפעלת Confirm email נכשלה: HTTP $PC"
  C=$(authget); ann notice "prod-auth" "$(authsummary)"; ann notice "prod-result" "✅ confirmon: Confirm email הופעל"
fi
