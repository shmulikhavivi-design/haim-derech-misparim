#!/usr/bin/env bash
# =====================================================================
# לוח הניהול — בדיקה על Postgres מקומי זמני בלבד (לא מתחבר ל-Supabase)
# מתקין 01+03+04+05+06+08 על מסד שמדמה את Supabase, ומריץ את 07 ו-09 (בדיקות הלוח) ואת 02 (74 בדיקות השרת)
# שימוש: bash scripts/staging_db/test_admin_local.sh
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; SQL="$ROOT/supabase/staging_secure"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
WORK="$(mktemp -d)"; PORT="${PGPORT_LOCAL:-54392}"
RUNAS=(); [ "$(id -u)" = 0 ] && { chown -R postgres "$WORK"; RUNAS=(su postgres -c); }
run(){ if [ ${#RUNAS[@]} -gt 0 ]; then "${RUNAS[@]}" "$*"; else bash -c "$*"; fi; }
run "$PGBIN/initdb -D $WORK/data -U postgres --auth=trust -E UTF8 --locale=C.UTF-8 >/dev/null"
run "$PGBIN/pg_ctl -D $WORK/data -o '-p $PORT -k $WORK -c listen_addresses=' -l $WORK/pg.log -w start >/dev/null"
trap 'run "$PGBIN/pg_ctl -D $WORK/data -m immediate stop >/dev/null" || true; rm -rf "$WORK"' EXIT
P=(psql -h "$WORK" -p "$PORT" -U postgres -d postgres -X -v ON_ERROR_STOP=1 -q -P pager=off)
"${P[@]}" -f "$ROOT/scripts/release/local_supabase_mock.sql" >/dev/null
# ב-Supabase האמיתי קיימת auth.sessions; במדמה המקומי — מוסיפים אותה
"${P[@]}" -c "create table if not exists auth.sessions (id uuid primary key default gen_random_uuid(), user_id uuid references auth.users(id) on delete cascade, created_at timestamptz default now(), updated_at timestamptz default now(), refreshed_at timestamp)"
for f in 01_staging_setup 03_staging_fixes 04_staging_profile_id_fix 05_staging_profile_hardening 06_staging_admin_dashboard 08_staging_admin_age_gender 10_staging_admin_live; do
  "${P[@]}" -f "$SQL/$f.sql" >/dev/null || { echo "❌ ההתקנה של $f נכשלה"; exit 1; }
done
echo "== 07 — לוח הניהול"
OUT7=$("${P[@]}" -f "$SQL/07_staging_admin_tests.sql"); echo "$OUT7"
echo "== 09 — פילוח גיל ומין"
OUT9=$("${P[@]}" -f "$SQL/09_staging_age_gender_tests.sql"); echo "$OUT9"
echo "== 11 — רשומים ומחוברים כרגע"
OUT11=$("${P[@]}" -f "$SQL/11_staging_admin_live_tests.sql"); echo "$OUT11"
echo "== 02 — בדיקות השרת הקיימות (שלא נשבר כלום)"
OUT2=$("${P[@]}" -f "$SQL/02_staging_tests.sql"); echo "$OUT2" | grep -E '❌|סיכום'
echo "$OUT7" | grep -q 'סיכום.*✅' && echo "$OUT9" | grep -q 'סיכום.*✅' && echo "$OUT11" | grep -q 'סיכום.*✅' && echo "$OUT2" | grep -q 'עברו 74 מתוך 74' && echo "✅ הכול עבר" || { echo "❌ יש כשלים"; exit 1; }
