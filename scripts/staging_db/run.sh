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

case "$MODE" in check|install03|install04|install05|tests02|e2e|smtp|smtpfix) ;; *) stop "מצב לא מוכר: $MODE";; esac

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
      --data-urlencode "sql=SELECT timestamp, event_message FROM logs WHERE source_name = 'auth_logs' ORDER BY timestamp DESC LIMIT 300" \
      --data-urlencode "iso_timestamp_start=$(date -u -d '-30 minutes' +%Y-%m-%dT%H:%M:%SZ)" \
      --data-urlencode "iso_timestamp_end=$(date -u +%Y-%m-%dT%H:%M:%SZ)" || echo 000)
    sleep 45
    LC=$(curl -sS -m 30 -o /tmp/logs.json -w '%{http_code}' -G -H "Authorization: Bearer $SBT" "$API/analytics/endpoints/logs" \
      --data-urlencode "sql=SELECT timestamp, event_message FROM logs WHERE source_name = 'auth_logs' ORDER BY timestamp DESC LIMIT 200" \
      --data-urlencode "iso_timestamp_start=$(date -u -d '-6 hours' +%Y-%m-%dT%H:%M:%SZ)" \
      --data-urlencode "iso_timestamp_end=$(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ)" || echo 000)
    NROWS=$(jq '.result|length' /tmp/logs.json 2>/dev/null || echo '?')
    ann notice "smtp-log-rows" "יומן Auth (6 שעות): HTTP $LC | שורות: $NROWS | $(jq -r '.error // empty' /tmp/logs.json 2>/dev/null | cut -c1-200)"
    ERRS=$( { jq -r '.result[]? | .event_message' /tmp/logs.json 2>/dev/null || true; } | grep -iE 'error|smtp|mail|535|534|dial|tls|sender|eof|timeout' \
      | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/<email>/g' | cut -c1-600 | head -6 || true)
    ann notice "smtp-log-errors" "${ERRS:-(אין שורות שגיאה)}"
    ann notice "smtp-log-http" "יומן Auth: HTTP $LC | שורות: $(jq '.result|length' /tmp/logs.json 2>/dev/null) | $(jq -r '.error.message // .message // empty' /tmp/logs.json 2>/dev/null | cut -c1-200)"
    LOGS=$( { curl -sS -m 30 -G -H "Authorization: Bearer $SBT" "$API/analytics/endpoints/logs" \
      --data-urlencode "sql=SELECT timestamp, event_message FROM logs WHERE source_name = 'auth_logs' ORDER BY timestamp DESC LIMIT 300" \
      --data-urlencode "iso_timestamp_start=$(date -u -d '-30 minutes' +%Y-%m-%dT%H:%M:%SZ)" \
      --data-urlencode "iso_timestamp_end=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      | jq -r '.result[]? | .event_message' | grep -iE 'smtp|mail|535|534|tls|dial|auth' \
      | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/<email>/g' | cut -c1-300 | head -8; } 2>&1 || true)
    ann notice "smtp-auth-log" "${LOGS:-(לא נמצאו שורות מייל ביומן)}"
  else
    ann notice "smtp-auth-log" "אין SUPABASE_ACCESS_TOKEN בסביבה staging — היומן לא נקרא"
  fi
  unset SBT
  case "${R1%% *}${R2%% *}${R3%% *}" in
    200200200) ann notice "staging-result" "✅ smtp: איפוס סיסמה, קישור כניסה ומייל אישור הרשמה — כולם נשלחו";;
    200200*)   ann error "staging-result" "⚠️ smtp: מיילים למשתמש קיים נשלחים, אבל מייל אישור ההרשמה נכשל (התבנית / ההגדרה)";;
    *)         ann error "staging-result" "❌ smtp: מיילים למשתמש קיים נכשלים — הבעיה בחיבור ל-Gmail";;
  esac
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

# ---- מצבים שכותבים (רק אחרי שכל ההגנות עברו) ----
case "$MODE" in
  install03) FILE="$SQLDIR/03_staging_fixes.sql" ;;
  install04) FILE="$SQLDIR/04_staging_profile_id_fix.sql" ;;
  install05) FILE="$SQLDIR/05_staging_profile_hardening.sql" ;;
  tests02)   FILE="$SQLDIR/02_staging_tests.sql" ;;
esac
[ -f "$FILE" ] || stop "הקובץ $(basename "$FILE") לא נמצא בענף."
say ""; say "### הרצת $(basename "$FILE")"
OUT=$("${PSQL[@]}" -f "$FILE" 2>&1) && RC=0 || RC=$?
echo "$OUT"; { echo '```'; echo "$OUT" | tail -n 120; echo '```'; } >> "$SUMMARY"
ann notice "staging-output" "$(echo "$OUT" | grep -E '❌|✅|סיכום|ERROR|עצירה' | tail -n 90)"
[ $RC -eq 0 ] || stop "$(basename "$FILE") נעצר או נכשל (ראו פלט). ההרצה היא 'הכול או כלום'."

if [ "$MODE" = "tests02" ]; then
  echo "$OUT" | grep -q 'עברו 74 מתוך 74' || stop "לא כל 74 הבדיקות עברו (ראו פלט)."
  LEFT=$("${RO[@]}" "${PSQL[@]}" -At -c \
    "select (select count(*) from auth.users where email like '%@example.invalid') + (select count(*) from public.hdm_accounts a where not exists (select 1 from auth.users u where u.id = a.auth_user_id))")
  [ "$LEFT" = "0" ] || stop "נשארו נתוני בדיקה במסד ($LEFT)."
  say "✅ עברו 74 מתוך 74, ולא נשארו נתוני בדיקה במסד."; ann notice "staging-result" "✅ tests02: עברו 74 מתוך 74, ולא נשארו נתוני בדיקה"
else
  say "✅ $(basename "$FILE") הותקן."; ann notice "staging-result" "✅ $MODE: $(basename "$FILE") הותקן"
fi
