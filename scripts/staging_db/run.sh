#!/usr/bin/env bash
# =====================================================================
# חיים דרך מספרים — הרצת בדיקות SQL על פרויקט Staging בלבד
#
# שימוש:  STAGING_DB_URL=... scripts/staging_db/run.sh <mode>
#   check    — (ברירת מחדל) בדיקת מצב לקריאה בלבד. לא משנה כלום.
#   install03 — מריץ את 03_staging_fixes.sql (כללי הרשאה בלבד; נעצר אם כבר הותקן)
#   install04 — מריץ את 04_staging_profile_id_fix.sql (נעצר אם כבר הותקן)
#   tests02  — מריץ את 02_staging_tests.sql (74 בדיקות; הכול מתבטל בסוף — לא נשמר כלום)
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

case "$MODE" in check|install03|install04|tests02) ;; *) stop "מצב לא מוכר: $MODE";; esac

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
HAS=$("${RO[@]}" "${PSQL[@]}" -At -c "select to_regclass('public.hdm_staging_marker') is not null" 2>&1) \
  || stop "החיבור נכשל (בדקו את הסוד STAGING_DB_URL)."
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

# ---- מצבים שכותבים (רק אחרי שכל ההגנות עברו) ----
case "$MODE" in
  install03) FILE="$SQLDIR/03_staging_fixes.sql" ;;
  install04) FILE="$SQLDIR/04_staging_profile_id_fix.sql" ;;
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
