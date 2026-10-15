#!/usr/bin/env bash
# =====================================================================
# חיים דרך מספרים — הרצת בדיקות SQL על פרויקט Staging בלבד
#
# שימוש:  STAGING_DB_URL=... scripts/staging_db/run.sh <mode>
#   check    — (ברירת מחדל) בדיקת מצב לקריאה בלבד. לא משנה כלום.
#   install03 — מריץ את 03_staging_fixes.sql (כללי הרשאה בלבד; נעצר אם כבר הותקן)
#   install04 — מריץ את 04_staging_profile_id_fix.sql (נעצר אם כבר הותקן)
#   install05 — מריץ את 05_staging_profile_hardening.sql (נעצר אם כבר הותקן)
#   tests02  — מריץ את 02_staging_tests.sql (74 בדיקות; הכול מתבטל בסוף — לא נשמר כלום)
#   e2e      — בדיקת דפדפן של staging.html מול Staging (משתמשי בדיקה זמניים שנמחקים בסוף). דורש STAGING_PUBLISHABLE_KEY
#
# הגנות, לפני כל חיבור ובכל מצב:
#   1. כתובת החיבור חייבת לכלול את מזהה פרויקט Staging, ואסור שתכלול את מזהה הפרויקט הפעיל.
#   2. בדיקה לקריאה בלבד שהמסד מכיל hdm_staging_marker (בפרויקט הפעיל אין). אחרת — עצירה.
#   3. כל מצב שאינו check דורש ש-check עבר באותה הרצה.
# הכתובת עצמה (כולל הסיסמה) מגיעה רק ממשתנה סביבה / GitHub Secret ולא מודפסת לעולם.
# =====================================================================
set -euo pipefail

STAGING_REF='ousepgdvzammgkxkweze'
PRODUCTION_REF='qtspzigjlbtckqfyaubp'
MODE="${1:-check}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SQLDIR="$ROOT/supabase/staging_secure"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

say(){ echo "$*"; echo "$*" >> "$SUMMARY"; }
# ב-GitHub Actions: התוצאה נשמרת גם כ-annotation, כדי שאפשר יהיה לקרוא אותה דרך ה-API (בלי להוריד יומנים)
ann(){ # $1 = notice|error, $2 = כותרת, $3 = טקסט
  [ -n "${GITHUB_ACTIONS:-}" ] || return 0
  local msg; msg=$(printf '%s' "$3" | sed -e 's/%/%25/g' -e 's/\r/%0D/g' | awk 'BEGIN{ORS="%0A"} {print}')
  printf '::%s title=%s::%s\n' "$1" "$2" "$msg"
}
stop(){ say "⛔ עצירה: $*"; ann error "staging-db" "⛔ עצירה: $*"; exit 1; }

case "$MODE" in check|install03|install04|install05|tests02|e2e|smtp|smtpfix|authflow|advisors|sslfix|install06|tests07|install08|tests09|install10|tests11|e2eadmin|audit|install12|tests13|mailnet|hookwire|authcfg|perms) ;; *) stop "מצב לא מוכר: $MODE";; esac

# ---- הגנה 1: כתובת החיבור ----
URL="${STAGING_DB_URL:-}"
unset STAGING_DB_URL                      # לא נשאר במשתני הסביבה של פקודות שרצות מכאן
[ -n "$URL" ] || stop "חסר STAGING_DB_URL (Environment Secret בסביבה staging)."
# אפשר לשמור בסוד רק את הסיסמה: אז הכתובת נבנית כאן, תמיד לפרויקט Staging בלבד (דרך ה-Pooler שלו)
STAGING_POOLER_HOST='aws-0-eu-west-1.pooler.supabase.com'
case "$URL" in
  *://*) ;;
  *) PWONLY=$(printf '%s' "$URL" | tr -d ' \t\r\n')
     [ -n "${GITHUB_ACTIONS:-}" ] && [ -n "$PWONLY" ] && echo "::add-mask::$PWONLY"
     URL="postgresql://postgres.$STAGING_REF:$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$PWONLY")@$STAGING_POOLER_HOST:5432/postgres?sslmode=require"
     unset PWONLY
     say "ℹ️ בסוד נשמרה סיסמה בלבד — הכתובת נבנתה לפרויקט Staging." ;;
esac
if [ -n "${GITHUB_ACTIONS:-}" ]; then     # הסתרה ביומן: הכתובת כולה והסיסמה לבד, גם אם יופיעו בהודעת שגיאה
  echo "::add-mask::$URL"
  PW=$(printf '%s' "$URL" | sed -n 's#^[a-z]*://[^:/@]*:\([^@]*\)@.*#\1#p')
  [ -n "$PW" ] && echo "::add-mask::$PW"
  unset PW
fi
case "$URL" in *"$PRODUCTION_REF"*) stop "כתובת החיבור שייכת לפרויקט הפעיל. שום דבר לא הורץ.";; esac
case "$URL" in *"$STAGING_REF"*) ;; *) stop "כתובת החיבור לא שייכת לפרויקט Staging ($STAGING_REF). שום דבר לא הורץ.";; esac

export PGCONNECT_TIMEOUT=20 PGAPPNAME=hdm-staging-ci

# ---- ניקוי טעויות הדבקה בכתובת + מעבר אוטומטי ל-Pooler אם אין IPv6 ----
# הכתובת המתוקנת קיימת רק בזיכרון של ההרצה הזו. הסוד ב-GitHub לא משתנה.
if NORM=$(HDM_RAW_URL="$URL" python3 -I "$HERE/normalize_url.py"); then
  NPW=$(printf '%s\n' "$NORM" | sed -n 1p)
  [ -n "${GITHUB_ACTIONS:-}" ] && [ -n "$NPW" ] && { echo "::add-mask::$NPW"; echo "::add-mask::$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$NPW")"; }
  unset NPW
  META=$(printf '%s\n' "$NORM" | sed -n 2p)
  case "$META" in *repaired=1*) say "ℹ️ בכתובת היו טעויות הדבקה — תוקנו אוטומטית לצורך ההרצה בלבד.";; esac
  case "$META" in *leaked=1*) say "⚠️ הסיסמה בסוד היא אותה סיסמה שנחשפה קודם — יש לאפס אותה ב-Supabase.";; *) say "✔ הסיסמה אינה הסיסמה שנחשפה קודם.";; esac
  CONNECTED=""; LASTERR=""
  while IFS=$'\t' read -r LABEL CAND; do
    [ -n "$CAND" ] || continue
    case "$CAND" in *"$PRODUCTION_REF"*) continue;; esac
    OUTC=$(PGCONNECT_TIMEOUT=8 env PGOPTIONS='-c default_transaction_read_only=on' psql "$CAND" -X --quiet -At \
      -c "select to_regclass('public.hdm_staging_marker') is not null" 2>&1) && { URL="$CAND"; CONNECTED="$LABEL"; break; }
    case "$OUTC" in *"password authentication failed"*) LASTERR="$OUTC"; [ "$LABEL" = given ] && break;;
                    *"Tenant or user not found"*|*"translate host name"*) ;; *) [ "$LABEL" = given ] && LASTERR="$OUTC";; esac
  done < <(printf '%s\n' "$NORM" | sed -n '3,$p')
  unset NORM CAND OUTC
  if [ -n "$CONNECTED" ]; then
    say "✔ נתיב החיבור שעבד: $CONNECTED"
    ann notice "staging-conn" "נתיב: $CONNECTED | $(case "$META" in *leaked=1*) echo 'סיסמה: זהה לזו שנחשפה';; *) echo 'סיסמה: לא זו שנחשפה';; esac) | $(case "$META" in *repaired=1*) echo 'תוקנה טעות הדבקה';; *) echo 'כתובת תקינה';; esac)"
  else
    say "⚠️ אף נתיב חיבור לא עבד (Direct וכל כתובות ה-Pooler). סוג השגיאה האחרונה: $(case "$LASTERR" in *"password authentication failed"*) echo סיסמה שגויה;; *"unreachable"*|*"Cannot assign"*) echo "אין רשת (IPv6)";; *timeout*) echo "תם הזמן";; *) echo אחרת;; esac)"
  fi
  unset LASTERR
fi
PSQL=(psql "$URL" -X -v ON_ERROR_STOP=1 --quiet)

# ---- הגנה 2: זהות המסד, בטרנזקציה לקריאה בלבד ----
RO=(env PGOPTIONS='-c default_transaction_read_only=on')
# אבחון בטוח של כתובת החיבור — מסווג בלבד. לעולם לא מדפיס חלק מהכתובת, מהסיסמה או מהשגיאה הגולמית
diag_url(){
  local rest userinfo hostpart pw host
  rest="${URL#*://}"; userinfo="${rest%%@*}"; hostpart="${rest#*@}"
  pw="${userinfo#*:}"; [ "$pw" = "$userinfo" ] && pw=""
  host="${hostpart%%[:/?]*}"
  case "$URL" in postgres://*|postgresql://*) say "✔ פורמט: postgresql://";; *) say "⚠️ הכתובת לא מתחילה ב-postgresql://";; esac
  case "$URL" in *'[YOUR-PASSWORD]'*|*'YOUR-PASSWORD'*|*'YOUR_PASSWORD'*) say "⚠️ נשאר בכתובת מציין-המקום [YOUR-PASSWORD] — צריך להחליף אותו בסיסמה עצמה";; esac
  case "$URL" in *' '*|*$'\n'*|*$'\t'*) say "⚠️ יש בכתובת רווח או ירידת שורה";; esac
  case "$host" in db.$STAGING_REF.supabase.co) say "✔ שרת: חיבור ישיר (Direct) של Staging — ייתכן שדורש IPv6";; *.pooler.supabase.com) say "✔ שרת: Pooler של Supabase";; *) say "⚠️ שם השרת לא בפורמט צפוי";; esac
  [ "${#pw}" -ge 8 ] && say "✔ יש סיסמה" || say "⚠️ סיסמה חסרה או קצרה מדי"
  # מבנה בלבד — מספרים וקטגוריות, אף תו מהתוכן
  local u="${userinfo%%:*}" ats colons sp_user sp_pw sp_host lead trail
  ats=$(printf '%s' "$URL" | tr -cd '@' | wc -c); colons=$(printf '%s' "$rest" | tr -cd ':' | wc -c)
  sp_user=$(printf '%s' "$u" | tr -cd ' \t\n' | wc -c); sp_pw=$(printf '%s' "$pw" | tr -cd ' \t\n' | wc -c); sp_host=$(printf '%s' "$hostpart" | tr -cd ' \t\n' | wc -c)
  case "$URL" in [[:space:]]*) lead=כן;; *) lead=לא;; esac; case "$URL" in *[[:space:]]) trail=כן;; *) trail=לא;; esac
  case "$u" in postgres) say "משתמש: postgres (מתאים לחיבור ישיר)";; postgres.$STAGING_REF) say "משתמש: postgres.<staging> (מתאים ל-Pooler)";; *) say "⚠️ שם המשתמש לא בפורמט צפוי (אורך ${#u})";; esac
  say "מבנה: אורך כולל ${#URL}, '@'=$ats, ':' אחרי :// =$colons, רווחים במשתמש=$sp_user בסיסמה=$sp_pw בשרת=$sp_host, רווח בהתחלה=$lead בסוף=$trail, אורך סיסמה=${#pw}"
}
classify_err(){
  case "$1" in
    *"unexpected spaces"*) echo "רווח בכתובת החיבור";;
    *"password authentication failed"*) echo "סיסמה שגויה";;
    *"translate host name"*|*"Name or service not known"*) echo "שם שרת לא נמצא (DNS)";;
    *"Network is unreachable"*|*"Cannot assign requested address"*) echo "אין גישת רשת לשרת (כנראה IPv6 בלבד — צריך כתובת Pooler)";;
    *"timeout expired"*) echo "תם הזמן להתחברות";;
    *"Tenant or user not found"*) echo "שם משתמש ל-Pooler שגוי";;
    *"SSL"*) echo "בעיית SSL";;
    *) echo "שגיאה אחרת (לא מוצגת כדי לא לחשוף פרטים)";;
  esac
}
HAS=$("${RO[@]}" "${PSQL[@]}" -At -c "select to_regclass('public.hdm_staging_marker') is not null" 2>&1) || {
  DIAG=$(diag_url)
  ERRTXT=$(classify_err "$HAS")
  say "סוג השגיאה: $ERRTXT"
  ann error "staging-conn" "$(printf '%s
סוג השגיאה: %s' "$DIAG" "$ERRTXT")"
  stop "החיבור נכשל (בדקו את הסוד STAGING_DB_URL)."
}
[ "$HAS" = "t" ] || stop "המסד אינו פרויקט הניסוי (אין hdm_staging_marker). שום דבר לא הורץ."
IDENT=$("${RO[@]}" "${PSQL[@]}" -At -c \
  "select exists (select 1 from public.hdm_staging_marker where version = 'staging_secure_v1')" 2>&1) \
  || stop "בדיקת הזהות נכשלה. שום דבר לא הורץ."
[ "$IDENT" = "t" ] || stop "המסד אינו פרויקט הניסוי (לא נמצאה התקנת staging_secure_v1). שום דבר לא הורץ."
say "✅ מחובר לפרויקט Staging ($STAGING_REF), מזוהה לפי hdm_staging_marker."

# ---- בדיקת מצב (תמיד, לקריאה בלבד) ----
say ""; say "### בדיקת מצב (קריאה בלבד)"
STATUS=$("${RO[@]}" "${PSQL[@]}" -f "$HERE/status_readonly.sql" 2>&1) || { echo "$STATUS"; stop "בדיקת המצב נכשלה."; }
echo "$STATUS"; { echo '```'; echo "$STATUS"; echo '```'; } >> "$SUMMARY"
ann notice "staging-status" "$STATUS"
[ "$MODE" = "check" ] && { say "✅ הסתיים (קריאה בלבד — לא שונה כלום)."; ann notice "staging-result" "✅ check: מחובר ל-Staging, קריאה בלבד, לא שונה כלום"; exit 0; }

# ---- אבחון שליחת מיילים: משתמש בדיקה מאושר זמני, איפוס סיסמה + קישור כניסה, ומחיקה ----
if [ "$MODE" = "smtp" ] || [ "$MODE" = "smtpfix" ]; then
  KEYP=$(sed -n "s/^ *var STAGING_PUBLISHABLE_KEY = '\(sb_publishable_[A-Za-z0-9_-]*\)'.*/\1/p" "$ROOT/staging.html" | head -1)
  [ -n "$KEYP" ] || stop "חסר המפתח הציבורי של Staging."
  AUTH="https://$STAGING_REF.supabase.co/auth/v1"
  EM="life.through.numbers333+smtp-diag-${GITHUB_RUN_ID:-local}@gmail.com"
  # ---- Management API (Staging בלבד): קריאת הגדרות, ובמצב smtpfix תיקון שם השולח בלבד ----
  SBT="${SUPABASE_ACCESS_TOKEN:-}"; unset SUPABASE_ACCESS_TOKEN
  API="https://api.supabase.com/v1/projects/$STAGING_REF"
  case "$API" in *"$PRODUCTION_REF"*) stop "Production ref";; esac
  if [ -n "$SBT" ]; then
    [ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$SBT"
    CODE=$(curl -sS -m 20 -o /tmp/cfg.json -w '%{http_code}' -H "Authorization: Bearer $SBT" "$API/config/auth" || echo 000)
    if [ "$CODE" = "200" ]; then
      SN=$(jq -r '.smtp_sender_name // ""' /tmp/cfg.json)
      INFO=$(jq -c '{mailer_autoconfirm, smtp_host, smtp_port, smtp_user_is_admin: (.smtp_user == .smtp_admin_email), smtp_pass_set: ((.smtp_pass // "") != ""), smtp_max_frequency, rate_limit_email_sent, sender_name_len: ((.smtp_sender_name // "")|length), sender_name_has_newline: ((.smtp_sender_name // "")|test("\n"))}' /tmp/cfg.json)
      ann notice "smtp-config" "$INFO"
      UCHK=$(jq -r '.smtp_user // ""' /tmp/cfg.json | python3 -I -c 'import sys
u=sys.stdin.read().rstrip("\n"); k=["life.through.numbers333@gmail.com","shmulikhavivi@gmail.com"]
m=[x for x in k if u==x]; ml=[x for x in k if u.strip().lower()==x]
print(f"user_len={len(u)} exact_match={m[0].split(chr(64))[0] if m else None} match_ignoring_case_space={ml[0].split(chr(64))[0] if ml else None} has_space={chr(32) in u} has_upper={u!=u.lower()} domain={u.rsplit(chr(64),1)[-1] if chr(64) in u else None}")')
      ann notice "smtp-user-check" "$UCHK"
      ann notice "smtp-brevo-user" "$(python3 -I "$HERE/smtp_user_check.py" < /tmp/cfg.json 2>&1)"
      PCHK=$(jq -r '.smtp_pass // ""' /tmp/cfg.json | python3 -I -c 'import sys,re
p=sys.stdin.read().rstrip("\n"); s=p.replace(" ","")
print(f"pass_len={len(p)} len_without_spaces={len(s)} has_space={chr(32) in p} has_tab_or_newline={bool(re.search(r"[\t\r\n]",p))} only_lowercase_letters={bool(re.fullmatch(r"[a-z]+",s))} looks_masked={bool(re.fullmatch(r"[*•]+",s))} gmail_app_password_shape={bool(re.fullmatch(r"[a-z]{16}",s))}")')
      ann notice "smtp-pass-shape" "$PCHK"
      PFP=$(jq -r '.smtp_pass // ""' /tmp/cfg.json | python3 -I -c 'import sys,hashlib
v=sys.stdin.read().rstrip("\n"); print("hex64" if len(v)==64 and all(c in "0123456789abcdef" for c in v) else "other", hashlib.sha256(v.encode()).hexdigest()[:8])')
      ann notice "smtp-pass-fingerprint" "מזהה הערך השמור (משתנה רק כשנשמרת סיסמה אחרת): $PFP"
      CLEAN='חיים דרך מספרים'
      if [ "$MODE" = "smtpfix" ] && [ "$SN" != "$CLEAN" ]; then
        PC=$(curl -sS -m 20 -o /tmp/patch.json -w '%{http_code}' -X PATCH -H "Authorization: Bearer $SBT" -H 'Content-Type: application/json' "$API/config/auth" -d "$(jq -nc --arg n "$CLEAN" '{smtp_sender_name:$n}')" || echo 000)
        NEW=$(jq -r '.smtp_sender_name // "?"' /tmp/patch.json 2>/dev/null)
        ann notice "smtp-fix" "תיקון שם השולח ב-Staging: HTTP $PC | שם חדש: $NEW | אורך קודם: ${#SN}"
        sleep 20
      fi
    else
      ann error "smtp-config" "קריאת הגדרות Auth של Staging נכשלה: HTTP $CODE"
    fi
    PROJ=$(curl -sS -m 20 -H "Authorization: Bearer $SBT" "https://api.supabase.com/v1/projects" | jq -r '[.[].id] | map(if . == "'"$STAGING_REF"'" then "staging" elif . == "'"$PRODUCTION_REF"'" then "PRODUCTION" else "other" end) | join(",")' 2>/dev/null || echo "?")
    ann notice "token-scope" "פרויקטים שהטוקן רואה: $PROJ"
  fi
  say ""; say "### אבחון SMTP (משתמש זמני: $EM)"
  "${PSQL[@]}" -At -c "with u as (insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
      values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', '$EM', '', now(), '{\"provider\":\"email\",\"providers\":[\"email\"]}', '{}', now(), now(), '', '', '', '') returning id)
    insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
      select gen_random_uuid(), u.id::text, u.id, jsonb_build_object('sub', u.id::text, 'email', '$EM', 'email_verified', true), 'email', now(), now(), now() from u" >/dev/null \
    || stop "יצירת משתמש הבדיקה נכשלה."
  call(){ curl -sS -m 60 -o /tmp/r.json -w '%{http_code} %{time_total}' -H "apikey: $KEYP" -H 'Content-Type: application/json' -X POST "$AUTH/$1" -d "$2"; }
  R1=$(call recover "{\"email\":\"$EM\"}"); M1=$(jq -r '(.msg // .error_description // .message // "")' /tmp/r.json 2>/dev/null)
  sleep 65
  R2=$(call otp "{\"email\":\"$EM\",\"create_user\":false}"); M2=$(jq -r '(.msg // .error_description // .message // "")' /tmp/r.json 2>/dev/null)
  sleep 65
  # הרשמה חדשה (מייל אישור הרשמה) — משתמש זמני נוסף שנמחק מיד
  EM3="life.through.numbers333+smtp-signup-${GITHUB_RUN_ID:-local}@gmail.com"
  PW3="Tst-$(openssl rand -hex 12)"
  R3=$(call signup "{\"email\":\"$EM3\",\"password\":\"$PW3\"}"); M3=$(jq -r '(.msg // .error_description // .message // (if .confirmation_sent_at then "confirmation_sent_at=" + .confirmation_sent_at else "" end))' /tmp/r.json 2>/dev/null)
  CS3=$("${RO[@]}" "${PSQL[@]}" -At -c "select coalesce(confirmation_sent_at::text,'none') from auth.users where email = '$EM3'" 2>/dev/null || echo '?')
  "${PSQL[@]}" -At -c "delete from public.docs where data->>'email' = '$EM3'; delete from auth.users where email in ('$EM', '$EM3')" >/dev/null || say "⚠️ מחיקת משתמשי הבדיקה נכשלה"
  LEFT=$("${RO[@]}" "${PSQL[@]}" -At -c "select count(*) from auth.users where email like 'life.through.numbers333+smtp-%'")
  RES="איפוס סיסמה (משתמש קיים): HTTP $R1 ${M1:+| $M1} ;; קישור כניסה (משתמש קיים): HTTP $R2 ${M2:+| $M2} ;; הרשמה חדשה (מייל אישור): HTTP $R3 ${M3:+| $M3} | נשלח אישור: $CS3 ;; משתמשי בדיקה שנשארו: $LEFT"
  say "$RES"; ann notice "smtp-diag" "$RES"
  if [ -n "$SBT" ]; then
    LC=$(curl -sS -m 30 -o /tmp/logs.json -w '%{http_code}' -G -H "Authorization: Bearer $SBT" "$API/analytics/endpoints/logs" \
      --data-urlencode "sql=SELECT timestamp, event_message FROM logs WHERE source = 'auth_logs' ORDER BY timestamp DESC LIMIT 300" \
      --data-urlencode "iso_timestamp_start=$(date -u -d '-30 minutes' +%Y-%m-%dT%H:%M:%SZ)" \
      --data-urlencode "iso_timestamp_end=$(date -u +%Y-%m-%dT%H:%M:%SZ)" || echo 000)
    sleep 45
    LC=$(curl -sS -m 30 -o /tmp/logs.json -w '%{http_code}' -G -H "Authorization: Bearer $SBT" "$API/analytics/endpoints/logs" \
      --data-urlencode "sql=SELECT timestamp, event_message FROM logs WHERE source = 'auth_logs' ORDER BY timestamp DESC LIMIT 200" \
      --data-urlencode "iso_timestamp_start=$(date -u -d '-6 hours' +%Y-%m-%dT%H:%M:%SZ)" \
      --data-urlencode "iso_timestamp_end=$(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ)" || echo 000)
    NROWS=$(jq '.result|length' /tmp/logs.json 2>/dev/null || echo '?')
    ann notice "smtp-log-rows" "יומן Auth (6 שעות): HTTP $LC | שורות: $NROWS | $(jq -r '.error // empty' /tmp/logs.json 2>/dev/null | cut -c1-200)"
    ERRS=$( { jq -r '.result[]? | .event_message' /tmp/logs.json 2>/dev/null || true; } | grep -iE 'error|smtp|mail|535|534|dial|tls|sender|eof|timeout' \
      | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/<email>/g' | cut -c1-600 | head -6 || true)
    ann notice "smtp-log-errors" "${ERRS:-(אין שורות שגיאה)}"
    ann notice "smtp-log-http" "יומן Auth: HTTP $LC | שורות: $(jq '.result|length' /tmp/logs.json 2>/dev/null) | $(jq -r '.error.message // .message // empty' /tmp/logs.json 2>/dev/null | cut -c1-200)"
    LOGS=$( { curl -sS -m 30 -G -H "Authorization: Bearer $SBT" "$API/analytics/endpoints/logs" \
      --data-urlencode "sql=SELECT timestamp, event_message FROM logs WHERE source = 'auth_logs' ORDER BY timestamp DESC LIMIT 300" \
      --data-urlencode "iso_timestamp_start=$(date -u -d '-30 minutes' +%Y-%m-%dT%H:%M:%SZ)" \
      --data-urlencode "iso_timestamp_end=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      | jq -r '.result[]? | .event_message' | grep -iE 'smtp|mail|535|534|tls|dial|auth' \
      | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/<email>/g' | cut -c1-300 | head -8; } 2>&1 || true)
    PROBE=$(SBT="$SBT" API="$API" timeout 150 python3 -I "$HERE/auth_log_probe.py" 2>&1 || true)
    ann notice "smtp-log-probe" "${PROBE:-(אין תוצאה)}"
    ann notice "smtp-auth-log" "${LOGS:-(לא נמצאו שורות מייל ביומן)}"
  else
    ann notice "smtp-auth-log" "אין SUPABASE_ACCESS_TOKEN בסביבה staging — היומן לא נקרא"
  fi
  unset SBT
  case "${R1%% *}${R2%% *}${R3%% *}" in
    200200200) ann notice "staging-result" "✅ smtp: איפוס סיסמה, קישור כניסה ומייל אישור הרשמה — כולם נשלחו";;
    200200*)   ann error "staging-result" "⚠️ smtp: מיילים למשתמש קיים נשלחים, אבל מייל אישור ההרשמה נכשל (התבנית / ההגדרה)";;
    *)         ann error "staging-result" "❌ smtp: מיילים למשתמש קיים נכשלים — הבעיה בהתחברות לשרת המייל (SMTP)";;
  esac
  exit 0
fi

# ---- זרימות Auth בלי תלות במשלוח מייל: אימות כתובת, איפוס סיסמה, הגדרות כתובות ותבניות ----
# האסימונים נכתבים ישירות למסד (כמו שהמייל היה מכיל), כדי לבדוק את מה שקורה כשהמשתמש לוחץ על הקישור.
if [ "$MODE" = "authflow" ]; then
  KEYP=$(sed -n "s/^ *var STAGING_PUBLISHABLE_KEY = '\(sb_publishable_[A-Za-z0-9_-]*\)'.*/\1/p" "$ROOT/staging.html" | head -1)
  [ -n "$KEYP" ] || stop "חסר המפתח הציבורי של Staging."
  AUTH="https://$STAGING_REF.supabase.co/auth/v1"
  TAG="${GITHUB_RUN_ID:-local}"
  EV="life.through.numbers333+flow-verify-$TAG@gmail.com"; ER="life.through.numbers333+flow-reset-$TAG@gmail.com"
  P1="Flow-$(openssl rand -hex 10)"; P2="New-$(openssl rand -hex 10)"
  TV=$(openssl rand -hex 28); TR=$(openssl rand -hex 28)
  RESULTS=""; OKN=0; ALLN=0
  chk(){ ALLN=$((ALLN+1)); if [ "$2" = ok ]; then OKN=$((OKN+1)); RESULTS="$RESULTS
PASS $1"; else RESULTS="$RESULTS
FAIL $1 -> $3"; fi; }
  req(){ curl -sS -m 30 -o /tmp/a.json -w '%{http_code}' -H "apikey: $KEYP" -H 'Content-Type: application/json' "$@"; }
  msg(){ jq -r '(.error_code // "") + " " + (.msg // .error_description // .message // "")' /tmp/a.json 2>/dev/null | cut -c1-120; }
  cleanup(){ "${PSQL[@]}" -At -c "delete from public.docs where data->>'email' in ('$EV','$ER'); delete from auth.users where email in ('$EV','$ER')" >/dev/null 2>&1 || true; }
  trap cleanup EXIT
  # משתמש "נרשם" שעדיין לא אימת מייל, עם אסימון אימות (כמו אחרי הרשמה)
  "${PSQL[@]}" -At -c "
    with u as (insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,confirmation_token,confirmation_sent_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000',gen_random_uuid(),'authenticated','authenticated','$EV',crypt('$P1',gen_salt('bf')),null,'$TV',now(),'{\"provider\":\"email\",\"providers\":[\"email\"]}','{}',now(),now(),'','','') returning id),
    i as (insert into auth.identities (id,provider_id,user_id,identity_data,provider,created_at,updated_at)
      select gen_random_uuid(),u.id::text,u.id,jsonb_build_object('sub',u.id::text,'email','$EV','email_verified',false),'email',now(),now() from u)
    insert into auth.one_time_tokens (id,user_id,token_type,token_hash,relates_to) select gen_random_uuid(),u.id,'confirmation_token','$TV','$EV' from u;
    with u as (insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,recovery_token,recovery_sent_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,confirmation_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000',gen_random_uuid(),'authenticated','authenticated','$ER',crypt('$P1',gen_salt('bf')),now(),'$TR',now(),'{\"provider\":\"email\",\"providers\":[\"email\"]}','{}',now(),now(),'','','') returning id),
    i as (insert into auth.identities (id,provider_id,user_id,identity_data,provider,created_at,updated_at)
      select gen_random_uuid(),u.id::text,u.id,jsonb_build_object('sub',u.id::text,'email','$ER','email_verified',true),'email',now(),now() from u)
    insert into auth.one_time_tokens (id,user_id,token_type,token_hash,relates_to) select gen_random_uuid(),u.id,'recovery_token','$TR','$ER' from u;" >/dev/null \
    || stop "יצירת משתמשי הבדיקה נכשלה."

  # 1. לפני אימות: אסור להתחבר
  C=$(req -X POST "$AUTH/token?grant_type=password" -d "{\"email\":\"$EV\",\"password\":\"$P1\"}")
  [ "$C" = 400 ] && grep -q 'email_not_confirmed' /tmp/a.json && chk "לפני אימות המייל: ההתחברות נחסמת (email_not_confirmed)" ok || chk "לפני אימות המייל: ההתחברות נחסמת" bad "HTTP $C $(msg)"
  # 2. לחיצה על קישור האימות
  C=$(req -X POST "$AUTH/verify" -d "{\"type\":\"email\",\"token_hash\":\"$TV\"}")
  [ "$C" = 200 ] && [ -n "$(jq -r '.access_token // empty' /tmp/a.json)" ] && chk "קישור אימות המייל: מאמת ומחבר" ok || chk "קישור אימות המייל: מאמת ומחבר" bad "HTTP $C $(msg)"
  CF=$("${RO[@]}" "${PSQL[@]}" -At -c "select email_confirmed_at is not null from auth.users where email='$EV'")
  [ "$CF" = t ] && chk "אחרי האימות: המייל מסומן כמאומת במסד" ok || chk "אחרי האימות: המייל מסומן כמאומת במסד" bad "$CF"
  # 3. אחרי אימות: התחברות בסיסמה עובדת
  C=$(req -X POST "$AUTH/token?grant_type=password" -d "{\"email\":\"$EV\",\"password\":\"$P1\"}")
  [ "$C" = 200 ] && chk "אחרי האימות: התחברות בסיסמה עובדת" ok || chk "אחרי האימות: התחברות בסיסמה עובדת" bad "HTTP $C $(msg)"
  # 4. שימוש חוזר בקישור אימות נדחה
  C=$(req -X POST "$AUTH/verify" -d "{\"type\":\"email\",\"token_hash\":\"$TV\"}")
  [ "$C" != 200 ] && chk "קישור אימות שכבר נוצל: נדחה" ok || chk "קישור אימות שכבר נוצל: נדחה" bad "HTTP $C"
  # 5. איפוס סיסמה: קישור האיפוס פותח session
  C=$(req -X POST "$AUTH/verify" -d "{\"type\":\"recovery\",\"token_hash\":\"$TR\"}")
  AT=$(jq -r '.access_token // empty' /tmp/a.json)
  [ "$C" = 200 ] && [ -n "$AT" ] && chk "קישור איפוס סיסמה: פותח session" ok || chk "קישור איפוס סיסמה: פותח session" bad "HTTP $C $(msg)"
  # 6. קביעת סיסמה חדשה
  C=$(req -X PUT "$AUTH/user" -H "Authorization: Bearer $AT" -d "{\"password\":\"$P2\"}")
  [ "$C" = 200 ] && chk "איפוס: קביעת סיסמה חדשה" ok || chk "איפוס: קביעת סיסמה חדשה" bad "HTTP $C $(msg)"
  C=$(req -X POST "$AUTH/token?grant_type=password" -d "{\"email\":\"$ER\",\"password\":\"$P2\"}")
  [ "$C" = 200 ] && chk "איפוס: התחברות בסיסמה החדשה" ok || chk "איפוס: התחברות בסיסמה החדשה" bad "HTTP $C $(msg)"
  C=$(req -X POST "$AUTH/token?grant_type=password" -d "{\"email\":\"$ER\",\"password\":\"$P1\"}")
  [ "$C" = 400 ] && chk "איפוס: הסיסמה הישנה כבר לא עובדת" ok || chk "איפוס: הסיסמה הישנה כבר לא עובדת" bad "HTTP $C"
  C=$(req -X POST "$AUTH/verify" -d "{\"type\":\"recovery\",\"token_hash\":\"$TR\"}")
  [ "$C" != 200 ] && chk "קישור איפוס שכבר נוצל: נדחה" ok || chk "קישור איפוס שכבר נוצל: נדחה" bad "HTTP $C"
  C=$(req -X POST "$AUTH/verify" -d "{\"type\":\"recovery\",\"token_hash\":\"$(openssl rand -hex 28)\"}")
  [ "$C" != 200 ] && chk "קישור איפוס מזויף: נדחה" ok || chk "קישור איפוס מזויף: נדחה" bad "HTTP $C"

  # 7. הגדרות Auth של Staging: כתובות הפניה ותבניות מייל (קריאה בלבד)
  SBT="${SUPABASE_ACCESS_TOKEN:-}"; unset SUPABASE_ACCESS_TOKEN
  if [ -n "$SBT" ]; then
    [ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$SBT"
    curl -sS -m 20 -o /tmp/cfg.json -H "Authorization: Bearer $SBT" "https://api.supabase.com/v1/projects/$STAGING_REF/config/auth" || true
    CFGI=$(jq -c '{site_url, uri_allow_list, mailer_autoconfirm, external_email_enabled, password_min_length, mailer_otp_exp, rate_limit_email_sent,
      subj:{confirm:.mailer_subjects_confirmation, recovery:.mailer_subjects_recovery, magic:.mailer_subjects_magic_link},
      tpl_has_link:{confirm:((.mailer_templates_confirmation_content//"")|test("ConfirmationURL|TokenHash")), recovery:((.mailer_templates_recovery_content//"")|test("ConfirmationURL|TokenHash")), magic:((.mailer_templates_magic_link_content//"")|test("ConfirmationURL|TokenHash"))},
      tpl_hebrew:{confirm:((.mailer_templates_confirmation_content//"")|test("[א-ת]")), recovery:((.mailer_templates_recovery_content//"")|test("[א-ת]"))},
      recovery_link_has_reset_flag:((.mailer_templates_recovery_content//"")|test("hdm_reset"))}' /tmp/cfg.json 2>&1 | sed -E 's/[A-Za-z0-9._%+-]+@gmail\.com/<gmail>/g' | head -c 1500)
    ann notice "auth-config" "$CFGI"
    jq -e '.site_url | test("shmulikhavivi-design.github.io/haim-derech-misparim")' /tmp/cfg.json >/dev/null 2>&1 && chk "Site URL מפנה לאתר ב-GitHub Pages" ok || chk "Site URL מפנה לאתר ב-GitHub Pages" bad "$(jq -r .site_url /tmp/cfg.json)"
    jq -e '(.uri_allow_list // "") | test("shmulikhavivi-design.github.io/haim-derech-misparim")' /tmp/cfg.json >/dev/null 2>&1 && chk "Redirect URLs כוללות את האתר" ok || chk "Redirect URLs כוללות את האתר" bad "$(jq -r .uri_allow_list /tmp/cfg.json)"
    jq -e '.mailer_autoconfirm == false' /tmp/cfg.json >/dev/null && chk "Confirm email מופעל (נדרש אימות מייל)" ok || chk "Confirm email מופעל" bad "autoconfirm=true"
    unset SBT
  fi
  cleanup; trap - EXIT
  LEFT=$("${RO[@]}" "${PSQL[@]}" -At -c "select count(*) from auth.users where email like 'life.through.numbers333+flow-%'")
  OUTF="$RESULTS
ניקוי: נשארו $LEFT משתמשי בדיקה
SUMMARY $OKN/$ALLN passed"
  echo "$OUTF"; { echo '```'; echo "$OUTF"; echo '```'; } >> "$SUMMARY"
  ann notice "authflow" "$OUTF"
  [ "$OKN" = "$ALLN" ] && ann notice "staging-result" "✅ authflow: $OKN/$ALLN" || ann error "staging-result" "❌ authflow: $OKN/$ALLN"
  exit 0
fi

# ---- יועצי אבטחה של Supabase (קריאה בלבד) ----
if [ "$MODE" = "advisors" ] || [ "$MODE" = "sslfix" ] || [ "$MODE" = "audit" ]; then
  SBT="${SUPABASE_ACCESS_TOKEN:-}"; unset SUPABASE_ACCESS_TOKEN
  [ -n "$SBT" ] || stop "חסר SUPABASE_ACCESS_TOKEN"
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$SBT"
  if [ "$MODE" = "sslfix" ]; then
    SC=$(curl -sS -m 30 -o /tmp/ssl.json -w '%{http_code}' -X PUT -H "Authorization: Bearer $SBT" -H 'Content-Type: application/json' \
      "https://api.supabase.com/v1/projects/$STAGING_REF/ssl-enforcement" -d '{"requestedConfig":{"database":true}}' || echo 000)
    AC=$(curl -sS -m 30 -o /tmp/ac.json -w '%{http_code}' -X PATCH -H "Authorization: Bearer $SBT" -H 'Content-Type: application/json' \
      "https://api.supabase.com/v1/projects/$STAGING_REF/config/auth" -d '{}' || echo 000)
    ann notice "perm-auth-config" "בדיקת הרשאת כתיבה להגדרות Auth (בקשה ריקה, לא משנה כלום): HTTP $AC | $(jq -c '.error // .message // "ok"' /tmp/ac.json 2>/dev/null | head -c 200)"
    ann notice "ssl-fix" "הפעלת אכיפת SSL ב-Staging: HTTP $SC | $(head -c 200 /tmp/ssl.json)"
    sleep 30
  fi
  ADV=$(SBT="$SBT" API="https://api.supabase.com/v1/projects/$STAGING_REF" timeout 120 python3 -I "$HERE/advisors.py" 2>&1 || true)
  echo "$ADV"; ann notice "advisors" "$ADV"
  if [ "$MODE" = "audit" ]; then
    AUD=$(SBT="$SBT" API="https://api.supabase.com/v1/projects/$STAGING_REF" timeout 240 python3 -I "$HERE/access_audit.py" 2>&1 || true)
    ann notice "audit-logs" "$AUD"
    AUD2=$("${RO[@]}" "${PSQL[@]}" -A -F ' : ' -f "$HERE/access_audit.sql" 2>&1 || true)
    ann notice "audit-db" "$AUD2"
    ann notice "staging-result" "audit: הסתיים (קריאה בלבד)"; exit 0
  fi
  FNS=$("${RO[@]}" "${PSQL[@]}" -A -F ' | ' -f "$HERE/exposed_functions.sql" 2>&1 || true)
  echo "$FNS"; ann notice "exposed-functions" "$FNS"
  ann notice "staging-result" "advisors: הסתיים (קריאה בלבד)"
  exit 0
fi

# ---- בדיקת דפדפן ללוח הניהול ----
if [ "$MODE" = "e2eadmin" ]; then
  say ""; say "### בדיקת דפדפן: admin-staging.html (מסך אייפון)"
  OUT=$(STAGING_DB_URL="$URL" PAGE="$ROOT/admin-staging.html" python3 "$ROOT/scripts/staging_e2e/e2e_admin.py" 2>&1) && RC=0 || RC=$?
  echo "$OUT"; { echo '```'; echo "$OUT"; echo '```'; } >> "$SUMMARY"
  ann notice "staging-e2e-admin" "$(echo "$OUT" | grep -E '^(PASS|FAIL|SUMMARY)|ניקוי' | tail -n 40)"
  [ $RC -eq 0 ] || stop "בדיקת הדפדפן של לוח הניהול נכשלה (ראו פלט)."
  ann notice "staging-result" "✅ e2eadmin: $(echo "$OUT" | grep '^SUMMARY' | tail -1)"
  exit 0
fi

# ---- בדיקת דפדפן מלאה ----
if [ "$MODE" = "e2e" ]; then
  if [ -z "${STAGING_PUBLISHABLE_KEY:-}" ]; then   # גיבוי: המפתח הציבורי שכתוב ב-staging.html (ציבורי מעצם הגדרתו)
    STAGING_PUBLISHABLE_KEY=$(sed -n "s/^ *var STAGING_PUBLISHABLE_KEY = '\(sb_publishable_[A-Za-z0-9_-]*\)'.*/\1/p" "$ROOT/staging.html" | head -1)
    export STAGING_PUBLISHABLE_KEY
  fi
  [ -n "${STAGING_PUBLISHABLE_KEY:-}" ] || stop "חסר המפתח הציבורי של Staging (לא במשתנה ולא ב-staging.html)."
  case "$STAGING_PUBLISHABLE_KEY" in sb_publishable_*) ;; *) stop "STAGING_PUBLISHABLE_KEY אינו מפתח ציבורי (sb_publishable_). שום דבר לא הורץ.";; esac
  say ""; say "### בדיקת דפדפן (staging.html מול Staging)"
  OUT=$(STAGING_DB_URL="$URL" PAGE="$ROOT/staging.html" python3 "$ROOT/scripts/staging_e2e/e2e_staging.py" 2>&1) && RC=0 || RC=$?
  echo "$OUT"; { echo '```'; echo "$OUT"; echo '```'; } >> "$SUMMARY"
  ann notice "staging-e2e" "$(echo "$OUT" | grep -E '^(PASS|FAIL|SUMMARY)|ניקוי' | tail -n 60)"
  [ $RC -eq 0 ] || stop "בדיקת הדפדפן נכשלה (ראו פלט)."
  say "✅ בדיקת הדפדפן עברה, ונתוני הבדיקה נמחקו."; ann notice "staging-result" "✅ e2e: $(echo "$OUT" | grep '^SUMMARY' | tail -1)"
  exit 0
fi

# ---- משלוח מיילים: האם המסד של Staging מגיע ל-Google (pg_net), בלי סודות ובלי לשלוח מייל ----
# שולח בקשה לכתובת Apps Script שלא קיימת. 404 מ-Google = יש דרך החוצה, והממסר האמיתי יעבוד.
if [ "$MODE" = "mailnet" ]; then
  "${RO[@]}" "${PSQL[@]}" -At -c "select 1 from public.hdm_staging_marker where version = 'staging_mail_hook_v1'" | grep -q 1 \
    || stop "צריך להתקין קודם את 12_staging_mail_hook.sql (install12)."
  RID=$("${PSQL[@]}" -At -c "select net.http_post(url := 'https://script.google.com/macros/s/AKfycb_hdm_reachability_probe_000/exec', body := '{\"probe\":true}'::jsonb, timeout_milliseconds := 15000)")
  RES=""
  for i in $(seq 1 12); do
    sleep 5
    RES=$("${RO[@]}" "${PSQL[@]}" -At -F ' | ' -c "select status_code, coalesce(error_msg,''), timed_out from net._http_response where id = $RID" 2>/dev/null || true)
    [ -n "$RES" ] && break
  done
  ann notice "mailnet" "בקשה $RID → ${RES:-(אין תשובה אחרי 60 שניות)}"
  case "$RES" in 4[0-9][0-9]*|3[0-9][0-9]*|200*) ann notice "staging-result" "✅ mailnet: המסד של Staging מגיע ל-script.google.com (HTTP ${RES%% *})";;
                 *) ann error "staging-result" "❌ mailnet: אין חיבור מהמסד ל-Google: ${RES:-timeout}";; esac
  exit 0
fi

# ---- משלוח מיילים: Auth → Hook → pg_net → Google, מקצה לקצה, בלי לשלוח מייל אמיתי ----
# אם הממסר עוד לא הוגדר: כתובת בדיקה של Google (שלא קיימת) ומפתח אקראי — רק לזמן ההרצה, ונמחקים בסוף.
# אם הממסר כבר הוגדר — לא נוגעים בו (לבדיקה אמיתית משתמשים במצב smtp).
if [ "$MODE" = "hookwire" ]; then
  KEYP=$(sed -n "s/^ *var STAGING_PUBLISHABLE_KEY = '\(sb_publishable_[A-Za-z0-9_-]*\)'.*/\1/p" "$ROOT/staging.html" | head -1)
  [ -n "$KEYP" ] || stop "חסר המפתח הציבורי של Staging."
  AUTH="https://$STAGING_REF.supabase.co/auth/v1"
  SBT="${SUPABASE_ACCESS_TOKEN:-}"; unset SUPABASE_ACCESS_TOKEN
  if [ -n "$SBT" ]; then
    [ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$SBT"
    CFG=$(curl -sS -m 20 -H "Authorization: Bearer $SBT" "https://api.supabase.com/v1/projects/$STAGING_REF/config/auth" | jq -c '{hook_send_email_enabled, hook_send_email_uri, site_url, uri_allow_list, mailer_autoconfirm}' 2>/dev/null || echo '?')
    ann notice "auth-hook-config" "$CFG"
  fi
  unset SBT
  "${RO[@]}" "${PSQL[@]}" -At -c "select 1 from public.hdm_staging_marker where version = 'staging_mail_hook_v1'" | grep -q 1 || stop "צריך install12 קודם."
  HAVE=$("${RO[@]}" "${PSQL[@]}" -At -c "select count(*) from vault.decrypted_secrets where name like 'hdm_mail_relay_%'")
  PROBE=0
  if [ "$HAVE" = 0 ]; then
    PROBE=1
    "${PSQL[@]}" -At -c "select vault.create_secret('https://script.google.com/macros/s/AKfycb_hdm_reachability_probe_000/exec', 'hdm_mail_relay_url', 'probe'); select vault.create_secret(encode(extensions.gen_random_bytes(24),'hex'), 'hdm_mail_relay_key', 'probe');" >/dev/null || stop "יצירת ממסר בדיקה נכשלה."
  fi
  TAG="${GITHUB_RUN_ID:-local}"; EM="life.through.numbers333+hookwire-$TAG@gmail.com"; EM2="life.through.numbers333+hookwire-su-$TAG@gmail.com"
  cleanup(){ "${PSQL[@]}" -At -c "delete from public.docs where data->>'email' in ('$EM','$EM2'); delete from auth.users where email in ('$EM','$EM2')" >/dev/null 2>&1 || true
             [ "$PROBE" = 1 ] && "${PSQL[@]}" -At -c "delete from vault.secrets where name in ('hdm_mail_relay_url','hdm_mail_relay_key') and description = 'probe'" >/dev/null 2>&1 || true; }
  trap cleanup EXIT
  "${PSQL[@]}" -At -c "with u as (insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change)
      values ('00000000-0000-0000-0000-000000000000',gen_random_uuid(),'authenticated','authenticated','$EM','',now(),'{\"provider\":\"email\",\"providers\":[\"email\"]}','{}',now(),now(),'','','','') returning id)
    insert into auth.identities (id,provider_id,user_id,identity_data,provider,last_sign_in_at,created_at,updated_at)
      select gen_random_uuid(),u.id::text,u.id,jsonb_build_object('sub',u.id::text,'email','$EM','email_verified',true),'email',now(),now(),now() from u" >/dev/null || stop "יצירת משתמש בדיקה נכשלה."
  L0=$("${RO[@]}" "${PSQL[@]}" -At -c "select coalesce(max(id),0) from public.hdm_mail_log")
  call(){ curl -sS -m 60 -o /tmp/r.json -w '%{http_code}' -H "apikey: $KEYP" -H 'Content-Type: application/json' -X POST "$AUTH/$1" -d "$2"; }
  C1=$(call recover "{\"email\":\"$EM\",\"redirect_to\":\"https://shmulikhavivi-design.github.io/haim-derech-misparim/?hdm_reset=1\"}"); M1=$(jq -r '(.msg // .error_description // .message // "")' /tmp/r.json 2>/dev/null)
  C2=$(call signup "{\"email\":\"$EM2\",\"password\":\"Hw-$(openssl rand -hex 10)\"}"); M2=$(jq -r '(.msg // .error_description // .message // "")' /tmp/r.json 2>/dev/null)
  sleep 15
  LOG=$("${RO[@]}" "${PSQL[@]}" -At -F ' ' -c "select l.action, l.messages, l.status, coalesce((select string_agg(coalesce(r.status_code::text, 'pending') || coalesce(':'||r.error_msg,''), ',') from net._http_response r where r.id = any(l.request_ids)), '-') from public.hdm_mail_log l where l.id > $L0 order by l.id")
  RES="ממסר: $([ $PROBE = 1 ] && echo 'כתובת בדיקה זמנית' || echo 'הממסר האמיתי (לא שונה)') ;; שכחתי סיסמה: HTTP $C1 ${M1:+| $M1} ;; הרשמה: HTTP $C2 ${M2:+| $M2} ;; יומן ה-Hook: $(echo "${LOG:-(ריק — ה-Hook לא נקרא)}" | tr '\n' ';')"
  ann notice "hookwire" "$RES"
  if [ "$C1" = 200 ] && [ "$C2" = 200 ] && echo "$LOG" | grep -q '^recovery 1 queued' && echo "$LOG" | grep -q '^signup 1 queued'; then
    ann notice "staging-result" "✅ hookwire: Auth קורא ל-Hook, המייל נבנה ונשלח ל-Google (שכחתי סיסמה + הרשמה)"
  elif [ -z "$LOG" ]; then ann error "staging-result" "❌ hookwire: ה-Hook לא נקרא — עדיין לא הופעל ב-Authentication ← Hooks"
  else ann error "staging-result" "❌ hookwire: $RES"; fi
  exit 0
fi

# ---- הגדרות Auth של Staging דרך Management API: כתובות האתר + הפעלת Send Email Hook ----
# Staging בלבד (הכתובת נבנית ממזהה Staging ונבדקת מול מזהה Production). לא נוגע בסיסמאות, ב-SMTP או בנתונים.
if [ "$MODE" = "authcfg" ]; then
  SBT="${SUPABASE_ACCESS_TOKEN:-}"; unset SUPABASE_ACCESS_TOKEN
  [ -n "$SBT" ] || stop "חסר SUPABASE_ACCESS_TOKEN בסביבה staging."
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$SBT"
  API="https://api.supabase.com/v1/projects/$STAGING_REF/config/auth"
  case "$API" in *"$PRODUCTION_REF"*) stop "Production ref";; esac
  SITE='https://shmulikhavivi-design.github.io/haim-derech-misparim/'
  BODY=$(jq -nc --arg s "$SITE" --arg a "${SITE}**" \
    '{site_url:$s, uri_allow_list:$a, hook_send_email_enabled:true, hook_send_email_uri:"pg-functions://postgres/public/hdm_send_email_hook"}')
  PC=$(curl -sS -m 30 -o /tmp/patch.json -w '%{http_code}' -X PATCH -H "Authorization: Bearer $SBT" -H 'Content-Type: application/json' "$API" -d "$BODY" || echo 000)
  ERR=$(jq -r '.message // .error // empty' /tmp/patch.json 2>/dev/null | cut -c1-300)
  AFTER=$(curl -sS -m 20 -H "Authorization: Bearer $SBT" "$API" | jq -c '{site_url, uri_allow_list, hook_send_email_enabled, hook_send_email_uri}' 2>/dev/null || echo '?')
  unset SBT
  ann notice "authcfg" "PATCH HTTP $PC ${ERR:+| $ERR} ;; אחרי: $AFTER"
  if [ "$PC" = 200 ]; then ann notice "staging-result" "✅ authcfg: Site URL, Redirect URLs ו-Send Email Hook הוגדרו ב-Staging"
  else ann error "staging-result" "❌ authcfg: HTTP $PC — לטוקן אין הרשאת כתיבה להגדרות Auth של Staging"; fi
  exit 0
fi

# ---- מה מותר לכל סוד בסביבה staging (שמות והרשאות בלבד — אף ערך לא מודפס) ----
if [ "$MODE" = "perms" ]; then
  ALLJ=$(jq -nc --arg a "${SUPABASE_ACCESS_TOKEN:-}" --arg b "${SUPABASE_STAGING_READ_TOKEN:-}" --arg c "${URL:+postgres-set}" \
    '{SUPABASE_ACCESS_TOKEN:$a, SUPABASE_STAGING_READ_TOKEN:$b, STAGING_DB_URL:(if $c=="" then "" else "postgresql://set" end)}')
  unset SUPABASE_ACCESS_TOKEN SUPABASE_STAGING_READ_TOKEN
  OUTP=$(ALL="$ALLJ" SREF="$STAGING_REF" PREF="$PRODUCTION_REF" python3 -I "$HERE/perms_probe.py" 2>&1 || true); unset ALLJ
  ann notice "perms" "$OUTP"; ann notice "staging-result" "perms: הסתיים (בלי שינוי)"; exit 0
fi

# ---- מצבים שכותבים (רק אחרי שכל ההגנות עברו) ----
case "$MODE" in
  install03) FILE="$SQLDIR/03_staging_fixes.sql" ;;
  install04) FILE="$SQLDIR/04_staging_profile_id_fix.sql" ;;
  install05) FILE="$SQLDIR/05_staging_profile_hardening.sql" ;;
  install06) FILE="$SQLDIR/06_staging_admin_dashboard.sql" ;;
  tests07)   FILE="$SQLDIR/07_staging_admin_tests.sql" ;;
  install08) FILE="$SQLDIR/08_staging_admin_age_gender.sql" ;;
  tests09)   FILE="$SQLDIR/09_staging_age_gender_tests.sql" ;;
  install10) FILE="$SQLDIR/10_staging_admin_live.sql" ;;
  tests11)   FILE="$SQLDIR/11_staging_admin_live_tests.sql" ;;
  tests02)   FILE="$SQLDIR/02_staging_tests.sql" ;;
  install12) FILE="$SQLDIR/12_staging_mail_hook.sql" ;;
  tests13)   FILE="$SQLDIR/13_staging_mail_hook_tests.sql" ;;
esac
[ -f "$FILE" ] || stop "הקובץ $(basename "$FILE") לא נמצא בענף."
say ""; say "### הרצת $(basename "$FILE")"
OUT=$("${PSQL[@]}" -f "$FILE" 2>&1) && RC=0 || RC=$?
echo "$OUT"; { echo '```'; echo "$OUT" | tail -n 120; echo '```'; } >> "$SUMMARY"
ann notice "staging-output" "$(echo "$OUT" | grep -E '❌|✅|סיכום|ERROR|עצירה' | tail -n 90)"
[ $RC -eq 0 ] || stop "$(basename "$FILE") נעצר או נכשל (ראו פלט). ההרצה היא 'הכול או כלום'."

if [ "$MODE" = "tests13" ]; then
  echo "$OUT" | grep -qE 'סיכום.*✅' || stop "לא כל בדיקות משלוח המיילים עברו (ראו פלט)."
  SUMM=$(echo "$OUT" | grep -oE 'עברו [0-9]+ מתוך [0-9]+' | tail -1)
  ann notice "staging-result" "✅ tests13: $SUMM (הכול בוטל — לא נשמר כלום ולא נשלח מייל)"
  exit 0
fi
if [ "$MODE" = "tests09" ] || [ "$MODE" = "tests11" ]; then
  echo "$OUT" | grep -qE 'סיכום.*✅' || stop "לא כל בדיקות פילוח הגיל והמין עברו (ראו פלט)."
  SUMM=$(echo "$OUT" | grep -oE 'עברו [0-9]+ מתוך [0-9]+' | tail -1)
  say "✅ $MODE: $SUMM (הכול בוטל — לא נשמר כלום)."; ann notice "staging-result" "✅ $MODE: $SUMM"
  exit 0
fi
if [ "$MODE" = "tests07" ]; then
  echo "$OUT" | grep -qE 'סיכום.*✅' || stop "לא כל בדיקות לוח הניהול עברו (ראו פלט)."
  SUMM=$(echo "$OUT" | grep -oE 'עברו [0-9]+ מתוך [0-9]+' | tail -1)
  say "✅ לוח הניהול: $SUMM (הכול בוטל — לא נשמר כלום)."; ann notice "staging-result" "✅ tests07: $SUMM"
  exit 0
fi
if [ "$MODE" = "tests02" ]; then
  echo "$OUT" | grep -q 'עברו 74 מתוך 74' || stop "לא כל 74 הבדיקות עברו (ראו פלט)."
  LEFT=$("${RO[@]}" "${PSQL[@]}" -At -c \
    "select (select count(*) from auth.users where email like '%@example.invalid') + (select count(*) from public.hdm_accounts a where not exists (select 1 from auth.users u where u.id = a.auth_user_id))")
  [ "$LEFT" = "0" ] || stop "נשארו נתוני בדיקה במסד ($LEFT)."
  say "✅ עברו 74 מתוך 74, ולא נשארו נתוני בדיקה במסד."; ann notice "staging-result" "✅ tests02: עברו 74 מתוך 74, ולא נשארו נתוני בדיקה"
else
  say "✅ $(basename "$FILE") הותקן."; ann notice "staging-result" "✅ $MODE: $(basename "$FILE") הותקן"
fi
