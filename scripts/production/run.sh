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
case "$MODE" in check|authplan|keycheck|smtptest|supamail|maildiag|ownertest|fingerprint|export|rehearse|simulate|authcfg|migrate|confirmon) ;; *) stop "מצב לא מוכר: $MODE";; esac

DB="${PRODUCTION_DB_URL:-}"; KEY="${BREVO_SMTP_KEY:-}"
# הטוקן החדש (Claude-Production-DB-Write, Database Read-write) קודם; אם אינו מוגדר — הטוקן הישן לקריאה בלבד
if [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then TOK="$SUPABASE_ACCESS_TOKEN"; TOKSRC=SUPABASE_ACCESS_TOKEN; else TOK="${PRODUCTION_SUPABASE_TOKEN:-}"; TOKSRC=PRODUCTION_SUPABASE_TOKEN; fi
unset PRODUCTION_DB_URL PRODUCTION_SUPABASE_TOKEN SUPABASE_ACCESS_TOKEN BREVO_SMTP_KEY
for v in "$DB" "$TOK" "$KEY"; do [ -n "$v" ] && echo "::add-mask::$v"; done
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
