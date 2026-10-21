#!/usr/bin/env bash
# =====================================================================
# חיים דרך מספרים — בדיקת קובץ המנויים בתשלום ל-Production (08) על מסד מקומי זמני בלבד.
# לא מתחבר ל-Supabase / Staging / Production ואין בו סודות. נתונים מומצאים, נמחקים בסוף.
#   1. מסד שמדמה את Production של היום: 01 (המעבר המאובטח) + 07, ומנויי פלוס קיימים ללא תשלום
#   2. 08 עובר, לא משנה מסלולים/מחירים/מספר רשומות, ולא יוצר שום תשלום
#   3. הרצה חוזרת של 08 נעצרת בלי לשנות דבר; 08 נעצר גם על מסד Staging
#   4. בדיקות SQL של Staging (18, 20, 22, 25) עוברות על המסד שאחרי 08
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
WORK="$(mktemp -d)"; PORT="${PGPORT_LOCAL:-54392}"
RUNAS=(); [ "$(id -u)" = 0 ] && { chown -R postgres "$WORK"; RUNAS=(su postgres -c); }
run(){ if [ ${#RUNAS[@]} -gt 0 ]; then "${RUNAS[@]}" "$*"; else bash -c "$*"; fi; }
run "$PGBIN/initdb -D $WORK/data -U postgres --auth=trust -E UTF8 --locale=C.UTF-8 >/dev/null"
run "$PGBIN/pg_ctl -D $WORK/data -o '-p $PORT -k $WORK -c listen_addresses=' -l $WORK/pg.log -w start >/dev/null"
trap 'run "$PGBIN/pg_ctl -D $WORK/data -m immediate stop >/dev/null" || true; rm -rf "$WORK"' EXIT
P=(psql -h "$WORK" -p "$PORT" -U postgres -X -v ON_ERROR_STOP=1 -q -P pager=off)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "✅ $1"; }
bad(){ FAIL=$((FAIL+1)); echo "❌ $1 — $2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "צפוי [$2], התקבל [$3]"; fi; }
q(){ "${P[@]}" -d "$1" -At -c "$2" 2>&1; }

python3 "$HERE/build_production_billing_sql.py" >/dev/null
F08="$ROOT/supabase/production/08_production_billing.sql"

# ---------- 1. מסד שמדמה את Production ----------
"${P[@]}" -c 'create database prod'
"${P[@]}" -d prod -f "$HERE/local_supabase_mock.sql" >/dev/null 2>&1
"${P[@]}" -d prod >/dev/null <<'SQL'
create table public.docs (collection text not null, id text not null, data jsonb not null default '{}'::jsonb, primary key (collection,id));
alter table public.docs enable row level security;
insert into public.docs values
 ('profiles','shmulik1','{"name":"Owner Test","birthdate":"1980-01-01"}'),
 ('profiles','noa2','{"name":"Noa Test","birthdate":"1990-01-01"}'),
 ('profiles','free3','{"name":"Free Test","birthdate":"1991-01-01"}'),
 ('data/users/u1','x','{"email":"owner@example.invalid","profileId":"shmulik1","createdAt":1000}'),
 ('data/users/u2','x','{"email":"noa@example.invalid","profileId":"noa2","createdAt":1000}'),
 ('data/users/u3','x','{"email":"free@example.invalid","profileId":"free3","createdAt":1000}');
SQL
"${P[@]}" -d prod -f "$ROOT/supabase/age_gate.sql" >/dev/null 2>&1
if "${P[@]}" -d prod -f "$ROOT/supabase/production/01_production_migration.sql" >"$WORK/01.out" 2>&1; then ok "בסיס: המעבר המאובטח (01)"; else bad "בסיס 01" "$(tail -3 "$WORK/01.out")"; fi
if "${P[@]}" -d prod -f "$ROOT/supabase/production/07_production_plus_no_extended.sql" >"$WORK/07.out" 2>&1; then ok "בסיס: 07"; else bad "בסיס 07" "$(tail -3 "$WORK/07.out")"; fi
# כמו ב-Production: חשבונות קיימים בפלוס ללא הגבלת זמן וללא תשלום
q prod "select public.hdm_admin_set_plan('shmulik1', 'plus', null, 'existing account'); select public.hdm_admin_set_plan('noa2', 'plus', null, 'existing account');" >/dev/null
PLANS_BEFORE=$(q prod "select string_agg(plan||':'||price_agorot, ',' order by sort_order) from public.hdm_plans")
SUBS_BEFORE=$(q prod "select string_agg(p||'='||public.hdm_plan_of(p), ',' order by p) from unnest(array['shmulik1','noa2','free3']) p")
check "לפני 08: שני חשבונות בפלוס, אחד בחינם" "free3=free,noa2=plus,shmulik1=plus" "$SUBS_BEFORE"
DOCS_BEFORE=$(q prod "select md5(string_agg(collection||'|'||id||'|'||data::text, ',' order by collection, id)) from public.docs")

# ---------- 2. 08 ----------
if "${P[@]}" -d prod -f "$F08" >"$WORK/08.out" 2>&1; then ok "08: המנויים בתשלום הותקנו"; else bad "08 עבר" "$(grep -E 'ERROR|עצירה' "$WORK/08.out" | head -3)"; fi
check "08: סימון גרסה ב-Production" "1" "$(q prod "select count(*) from public.hdm_release_marker where version='production_billing_v1'")"
check "08: מסלולים ומחירים ללא שינוי" "$PLANS_BEFORE" "$(q prod "select string_agg(plan||':'||price_agorot, ',' order by sort_order) from public.hdm_plans")"
check "08: מסלול כל משתמש ללא שינוי (פלוס הקיימים נשארו)" "$SUBS_BEFORE" "$(q prod "select string_agg(p||'='||public.hdm_plan_of(p), ',' order by p) from unnest(array['shmulik1','noa2','free3']) p")"
check "08: docs ללא שינוי" "$DOCS_BEFORE" "$(q prod "select md5(string_agg(collection||'|'||id||'|'||data::text, ',' order by collection, id)) from public.docs")"
check "08: לא נוצרו תשלומים / ניסיונות תשלום / כרטיסים" "0" "$(q prod "select (select count(*) from public.hdm_payments)+(select count(*) from public.hdm_checkouts)+(select count(*) from public.hdm_billing_tokens)")"
check "08: פלוס הקיימים לא מתחדשים ולא יחויבו" "0" "$(q prod "select count(*) from public.hdm_subscriptions where auto_renew")"
check "08: פונקציות Morning קיימות" "true|true" "$(q prod "select (to_regprocedure('public.hdm_billing_checkout_lookup(uuid)') is not null)::text||'|'||(to_regprocedure('public.hdm_billing_apply_morning_renewal(jsonb)') is not null)::text")"
check "08: האפליקציה לא יכולה להזין אירוע תשלום" "permission denied" "$(q prod "begin; set local role authenticated; select public.hdm_billing_apply_grow_event('{}'::jsonb); rollback;" | grep -o 'permission denied' | head -1)"

# ---------- 3. הרצה חוזרת / מסד לא נכון ----------
OUT=$("${P[@]}" -d prod -f "$F08" 2>&1) || true
check "08: הרצה חוזרת נעצרת ('כבר מותקן')" "1" "$(echo "$OUT" | grep -c 'כבר מותקן')"
check "08: אחרי ההרצה החוזרת — סימון גרסה אחד בלבד" "1" "$(q prod "select count(*) from public.hdm_release_marker where version='production_billing_v1'")"
"${P[@]}" -c 'create database stg'
"${P[@]}" -d stg -f "$HERE/local_supabase_mock.sql" >/dev/null 2>&1
for f in 01_staging_setup 03_staging_fixes 04_staging_profile_id_fix 05_staging_profile_hardening 14_staging_consent 16_staging_plus_no_extended; do
  "${P[@]}" -d stg -f "$ROOT/supabase/staging_secure/$f.sql" >/dev/null
done
OUT=$("${P[@]}" -d stg -f "$F08" 2>&1) || true
check "08: על מסד Staging — נעצר בלי לשנות" "1|f" "$(echo "$OUT" | grep -c 'לא מסד ה-Production')|$(q stg "select (to_regclass('public.hdm_payments') is not null)::text" | cut -c1)"

# ---------- 4. בדיקות SQL של Staging על המסד שאחרי 08 ----------
for t in 18_staging_billing_tests 20_staging_billing_upgrade_tests 22_staging_billing_cancel_tests 25_staging_billing_morning_tests; do
  T=$("${P[@]}" -d prod -At -F'|' -f "$ROOT/supabase/staging_secure/$t.sql" 2>&1) || true
  SUM=$(echo "$T" | grep -o 'עברו [0-9]* מתוך [0-9]*' | tail -1)
  N=$(echo "$SUM" | awk '{print $2}'); M=$(echo "$SUM" | awk '{print $4}')
  if [ -n "$N" ] && [ "$N" = "$M" ]; then ok "בדיקות ${t%%_*}: $SUM"; else bad "בדיקות ${t%%_*}" "${SUM:-$(echo "$T" | grep -E 'ERROR|עצירה' | head -2)}"; echo "$T" | grep '❌' | head -5 || true; fi
done
check "הבדיקות לא השאירו נתונים" "0" "$(q prod "select (select count(*) from public.hdm_payments)+(select count(*) from public.hdm_checkouts)")"

echo; echo "סיכום: עברו $PASS מתוך $((PASS+FAIL))"
[ "$FAIL" = 0 ]
