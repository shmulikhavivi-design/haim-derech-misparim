#!/usr/bin/env bash
# =====================================================================
# חיים דרך מספרים — בדיקת Grow מקצה לקצה על מסד מקומי זמני בלבד (לא מתחבר לשום פרויקט, לא ל-Grow).
# מקים Postgres זמני + סביבת Supabase מדומה + שכבת המנויים (SQL 01–26), ומריץ את scripts/grow_local/e2e_test.ts.
# שימוש: bash scripts/grow_local/run.sh   (דורש postgresql 14+ ו-deno)
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
DENO="${DENO:-$(command -v deno || echo /tmp/denobin/deno)}"
WORK="$(mktemp -d)"; PORT="${PGPORT_LOCAL:-54393}"
RUNAS=(); [ "$(id -u)" = 0 ] && { chown -R postgres "$WORK"; chmod 755 "$WORK"; RUNAS=(su postgres -c); }
run(){ if [ ${#RUNAS[@]} -gt 0 ]; then "${RUNAS[@]}" "$*"; else bash -c "$*"; fi; }
run "$PGBIN/initdb -D $WORK/data -U postgres --auth=trust -E UTF8 --locale=C.UTF-8 >/dev/null"
run "$PGBIN/pg_ctl -D $WORK/data -o '-p $PORT -k $WORK -c listen_addresses=' -l $WORK/pg.log -w start >/dev/null"
trap 'run "$PGBIN/pg_ctl -D $WORK/data -m immediate stop >/dev/null" || true; rm -rf "$WORK"' EXIT
P=(psql -h "$WORK" -p "$PORT" -U postgres -X -v ON_ERROR_STOP=1 -q)
"${P[@]}" -d postgres -c 'create database stg' >/dev/null
"${P[@]}" -d stg -f "$ROOT/scripts/release/local_supabase_mock.sql" >/dev/null 2>&1
for f in 01_staging_setup 03_staging_fixes 04_staging_profile_id_fix 05_staging_profile_hardening 14_staging_consent 16_staging_plus_no_extended \
         17_staging_billing 19_staging_billing_upgrade 21_staging_billing_cancel 23_staging_billing_statutory_cancel 24_staging_billing_morning 26_staging_billing_grow 28_staging_billing_card_renewal; do
  "${P[@]}" -d stg -f "$ROOT/supabase/staging_secure/$f.sql" >/dev/null
done
echo "מסד זמני מוכן (01–28). מריץ בדיקה מקצה לקצה…"
PGHOST="$WORK" PGPORT="$PORT" "$DENO" test --no-check --allow-run=psql --allow-env "$ROOT/scripts/grow_local/e2e_test.ts"
