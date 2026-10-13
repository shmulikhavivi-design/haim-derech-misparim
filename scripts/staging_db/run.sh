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

case "$MODE" in check|install03|install04|install05|tests02|e2e) ;; *) stop "מצב לא מוכר: $MODE";; esac

# ---- הגנה 1: כתובת החיבור ----
URL="${STAGING_DB_URL:-}"
unset STAGING_DB_URL                      # לא נשאר במשתני הסביבה של פקודות שרצות מכאן
[ -n "$URL" ] || stop "חסר STAGING_DB_URL (Environment Secret בסביבה staging)."
if [ -n "${GITHUB_ACTIONS:-}" ]; then     # הסתרה ביומן: הכתובת כולה והסיסמה לבד, גם אם יופיעו בהודעת שגיאה
  echo "::add-mask::$URL"
  PW=$(printf '%s' "$URL" | sed -n 's#^[a-z]*://[^:/@]*:\([^@]*\)@.*#\1#p')
  [ -n "$PW" ] && echo "::add-mask::$PW"
  unset PW
fi
case "$URL" in *"$PRODUCTION_REF"*) stop "כתובת החיבור שייכת לפרויקט הפעיל. שום דבר לא הורץ.";; esac
case "$URL" in *"$STAGING_REF"*) ;; *) stop "כתובת החיבור לא שייכת לפרויקט Staging ($STAGING_REF). שום דבר לא הורץ.";; esac

PSQL=(psql "$URL" -X -v ON_ERROR_STOP=1 --quiet)
export PGCONNECT_TIMEOUT=20 PGAPPNAME=hdm-staging-ci

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

# ---- בדיקת דפדפן מלאה ----
if [ "$MODE" = "e2e" ]; then
  [ -n "${STAGING_PUBLISHABLE_KEY:-}" ] || stop "חסר STAGING_PUBLISHABLE_KEY (משתנה בסביבה staging)."
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
