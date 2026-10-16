#!/usr/bin/env bash
# =====================================================================
# חיים דרך מספרים — בדיקת המעבר ל-Production על מסד מקומי בלבד
#
# לא מתחבר ל-Supabase ולא לשום פרויקט: יוצר Postgres זמני על המחשב/השרת שמריץ,
# עם נתונים מומצאים שמדמים את Production של היום, ובודק:
#   1. בדיקה מקדימה (00) — מזהה פרופיל עם כמה אימיילים כ-⚠️
#   2. מעבר (01) — עובר, שומר את כל הרשומות, לא מקשר פרופיל שנויים במחלוקת
#   3. קישור חשבון קיים רק אחרי אימות מייל, וחסימת השתלטות
#   4. החלטה ידנית (hdm_admin_link_legacy) ולא זמינה לאפליקציה
#   5. ביטול (99) — מחזיר את docs בדיוק למצב הקודם
#   6. 74 בדיקות SQL של Staging על אותו קוד שרת (01+03+04+05+02)
# שימוש: bash scripts/release/test_migration_local.sh   (דורש postgresql 14+ מותקן)
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
WORK="$(mktemp -d)"; PORT="${PGPORT_LOCAL:-54391}"
RUNAS=(); [ "$(id -u)" = 0 ] && { chown -R postgres "$WORK"; RUNAS=(su postgres -c); }
run(){ if [ ${#RUNAS[@]} -gt 0 ]; then "${RUNAS[@]}" "$*"; else bash -c "$*"; fi; }
run "$PGBIN/initdb -D $WORK/data -U postgres --auth=trust -E UTF8 --locale=C.UTF-8 >/dev/null"
run "$PGBIN/pg_ctl -D $WORK/data -o '-p $PORT -k $WORK -c listen_addresses=' -l $WORK/pg.log -w start >/dev/null"
trap 'run "$PGBIN/pg_ctl -D $WORK/data -m immediate stop >/dev/null" || true; rm -rf "$WORK"' EXIT
P=(psql -h "$WORK" -p "$PORT" -U postgres -X -v ON_ERROR_STOP=1 -q -P pager=off)

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "✅ $1"; }
bad(){ FAIL=$((FAIL+1)); echo "❌ $1 — $2"; }
check(){ # $1 שם, $2 צפוי, $3 התקבל
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "צפוי [$2], התקבל [$3]"; fi; }
q(){ "${P[@]}" -d "$1" -At -c "$2" 2>&1; }

# ---------- מסד שמדמה את Production של היום (נתונים מומצאים) ----------
"${P[@]}" -c 'create database prod'
"${P[@]}" -d prod -f "$HERE/local_supabase_mock.sql" >/dev/null 2>&1
"${P[@]}" -d prod >/dev/null <<'SQL'
create table public.docs (collection text not null, id text not null, data jsonb not null default '{}'::jsonb, primary key (collection,id));
alter table public.docs enable row level security;
create policy open_all on public.docs for all to anon, authenticated using (true) with check (true);
grant all on public.docs to anon, authenticated;
insert into public.docs values
 ('profiles','alice1','{"name":"Alice Test","birthdate":"1990-05-05","likes":["bobby2"]}'),
 ('profiles','bobby2','{"name":"Bob Test","birthdate":"1985-01-01","likes":["alice1"]}'),
 ('profiles','carol3','{"name":"Carol Test"}'),
 ('profiles','dave4','{"name":"Dave Test","birthdate":"1980-02-02"}'),
 ('data/users/u1','x','{"email":"alice@example.invalid","profileId":"alice1","createdAt":1000}'),
 ('data/users/u2','x','{"email":"Bob@Example.invalid ","profileId":"bobby2","createdAt":1000}'),
 ('data/users/u3','x','{"email":"carol@example.invalid","profileId":"carol3","createdAt":1000}'),
 ('data/users/u4','x','{"email":"dave@example.invalid","profileId":"carol3","createdAt":10}'),
 ('data/users/u5','x','{"email":"dave@example.invalid","profileId":"dave4","createdAt":2000}'),
 ('data/users/evil','x','{"email":"aaa-attacker@example.invalid","profileId":"alice1","createdAt":500}'),
 ('chats','alice1__bobby2','{"messages":[{"from":"alice1","text":"hi"}]}'),
 ('matches','alice1__bobby2','{}');
SQL
"${P[@]}" -d prod -f "$ROOT/supabase/age_gate.sql" >/dev/null 2>&1
# כמו ב-Production: גיבוי ידני קיים מ-9.10 בסכימה hdm_backup — המעבר והביטול לא אמורים לגעת בו
"${P[@]}" -d prod -q -c "create schema hdm_backup; create table hdm_backup.docs_20261009 as table public.docs;"
MANUAL=$(q prod "select md5(string_agg(collection||'|'||id||'|'||data::text, ',' order by collection, id)) from hdm_backup.docs_20261009")
"${P[@]}" -c 'create database prod_before template prod'
SNAP="select md5(string_agg(collection||'|'||id||'|'||data::text, ',' order by collection, id)) from public.docs"
BEFORE=$(q prod "$SNAP")

# ---------- 1. בדיקה מקדימה ----------
PRE=$("${P[@]}" -d prod -At -F'|' -f "$ROOT/supabase/production/00_production_preflight_readonly.sql")
check "בדיקה מקדימה: שורה 7 מסמנת ⚠️ פרופיל עם כמה אימיילים" "2|⚠️" "$(echo "$PRE" | awk -F'|' '$1==7{print $3"|"$4}')"
check "בדיקה מקדימה: לא שינתה כלום" "$BEFORE" "$(q prod "$SNAP")"
check "בדיקה מקדימה: גיבוי ידני קיים לא חוסם (שורה 2 ✅)" "✅" "$(echo "$PRE" | awk -F'|' '$1==2{print $4}')"

# ---------- 2. מעבר ----------
if "${P[@]}" -d prod -f "$ROOT/supabase/production/01_production_migration.sql" >"$WORK/mig.out" 2>&1; then ok "המעבר עבר"; else bad "המעבר עבר" "$(tail -3 "$WORK/mig.out")"; fi
check "כל הרשומות הקיימות ב-docs נשמרו (לפי מפתח)" "$(q prod_before 'select count(*) from public.docs')" "$(q prod 'select count(*) from public.docs d join hdm_backup.docs_before_migration b using (collection, id)')"
check "likes ישנים הפכו ל-🎯 (interests)" "2" "$(q prod "select count(*) from public.docs where collection='interests'")"
check "גיבוי מלא קיים" "$BEFORE" "$(q prod "select md5(string_agg(collection||'|'||id||'|'||data::text, ',' order by collection, id)) from hdm_backup.docs_before_migration")"
check "הגיבוי הידני מ-9.10 לא השתנה במעבר" "$MANUAL" "$(q prod "select md5(string_agg(collection||'|'||id||'|'||data::text, ',' order by collection, id)) from hdm_backup.docs_20261009")"
check "תאריך לידה עבר לטבלה הסגורה" "0" "$(q prod "select count(*) from public.docs where collection='profiles' and data ? 'birthdate'")"
check "השיחה הישנה שלמה" '[{"from": "alice1", "text": "hi"}]' "$(q prod "select data->'messages' from public.docs where collection='chats' and id='alice1__bobby2'")"
check "פרופיל עם כמה אימיילים לא קושר אוטומטית (alice1, carol3)" "0" "$(q prod "select count(*) from public.hdm_legacy_accounts where profile_id in ('alice1','carol3')")"
check "לאימייל התוקף לא נוצר משתמש התחברות" "0" "$(q prod "select count(*) from auth.users where email='aaa-attacker@example.invalid'")"
check "הם נשמרו לבדיקה ידנית" "alice1,carol3" "$(q prod "select string_agg(distinct profile_id, ',' order by profile_id) from public.hdm_legacy_review")"
check "חשבון רגיל קושר (אימייל מנורמל)" "bobby2" "$(q prod "select profile_id from public.hdm_legacy_accounts where email='bob@example.invalid'")"
check "אימייל עם כמה פרופילים: הפרופיל התקין האחרון" "dave4" "$(q prod "select profile_id from public.hdm_legacy_accounts where email='dave@example.invalid'")"
check "נוצרו משתמשי התחברות רק לחשבונות המקושרים" "2" "$(q prod "select count(*) from auth.users")"

# ---------- 3. קישור חשבון קיים ----------
claim(){ # $1 = email, $2 = amr method → מחזיר profile id או שגיאה
  q prod "begin; select set_config('request.jwt.claims', json_build_object('sub',(select id from auth.users where email='$1'),'role','authenticated','amr',json_build_array(json_build_object('method','$2')))::text, true);
          set local role authenticated; select public.hdm_claim_profile(); rollback;"; }
check "כניסה בסיסמה בלבד לא מקשרת חשבון קיים" "HDM_LEGACY_VERIFY_EMAIL" "$(claim bob@example.invalid password | grep -o HDM_LEGACY_VERIFY_EMAIL)"
check "אחרי 'שכחתי סיסמה' החשבון מתקשר לפרופיל שלו" "bobby2" "$(claim bob@example.invalid recovery | tail -1)"
check "פרופיל בבדיקה ידנית לא זמין כמזהה לחשבון חדש" "HDM_PROFILE_ID_TAKEN" "$(q prod "begin; insert into auth.users(id,email) values ('00000000-0000-0000-0000-0000000000aa','new@example.invalid'); select set_config('request.jwt.claims','{\"sub\":\"00000000-0000-0000-0000-0000000000aa\",\"role\":\"authenticated\"}',true); set local role authenticated; select public.hdm_claim_profile('alice1'); rollback;" | grep -o HDM_PROFILE_ID_TAKEN)"

# ---------- 4. החלטה ידנית ----------
check "האפליקציה לא יכולה להפעיל את הקישור הידני" "permission denied" "$(q prod "begin; set local role authenticated; select public.hdm_admin_link_legacy('alice@example.invalid','alice1'); rollback;" | grep -o 'permission denied')"
check "האפליקציה לא יכולה לקרוא את רשימת הבדיקה הידנית" "permission denied" "$(q prod "begin; set local role authenticated; select * from public.hdm_legacy_review; rollback;" | grep -o 'permission denied')"
check "קישור ידני לצמד שלא ברשימה נדחה" "hdm_legacy_review" "$(q prod "select public.hdm_admin_link_legacy('bob@example.invalid','alice1')" | grep -o 'hdm_legacy_review' | head -1)"
q prod "select public.hdm_admin_link_legacy('alice@example.invalid','alice1')" >/dev/null
check "קישור ידני: האימייל הנכון מקושר ונוצר לו משתמש" "alice1|1" "$(q prod "select (select profile_id from public.hdm_legacy_accounts where email='alice@example.invalid') || '|' || (select count(*) from auth.users where email='alice@example.invalid')")"
check "אחרי הקישור הידני: 'שכחתי סיסמה' מחבר את alice1" "alice1" "$(claim alice@example.invalid recovery | tail -1)"

# ---------- 4א. פתרון זמני בלי מייל (02_temp_link_existing_account.sql) ----------
TMPL="$ROOT/supabase/production/02_temp_link_existing_account.sql"
OUT=$("${P[@]}" -d prod -f "$TMPL" 2>&1) || true; check "פתרון זמני: בלי החלפת הערכים — נעצר" "1" "$(echo "$OUT" | grep -c 'יש להחליף')"
sed -e "s/EMAIL_HERE/Dave@Example.invalid/" -e "s/'TEMP_PASSWORD_HERE'/'Temp-Pass-12345'/" "$TMPL" > "$WORK/tmp_link.sql"
OUT=$("${P[@]}" -d prod -f "$WORK/tmp_link.sql" 2>&1) && ok "פתרון זמני: רץ בהצלחה" || bad "פתרון זמני: רץ בהצלחה" "$(echo "$OUT" | tail -2)"
check "פתרון זמני: כניסה בסיסמה מחברת את dave4 בלי מייל" "dave4" "$(claim dave@example.invalid password | tail -1)"
check "פתרון זמני: הסיסמה הזמנית נשמרה (מוצפנת)" "t" "$(q prod "select encrypted_password = $(q prod "select case when to_regnamespace('extensions') is not null and exists (select 1 from pg_proc where proname='crypt' and pronamespace='extensions'::regnamespace) then 'extensions.' else 'public.' end")crypt('Temp-Pass-12345', encrypted_password) from auth.users where email='dave@example.invalid'")"
OUT=$("${P[@]}" -d prod -f "$WORK/tmp_link.sql" 2>&1) || true; check "פתרון זמני: הרצה חוזרת נעצרת" "1" "$(echo "$OUT" | grep -c 'כבר מחובר')"
sed -e "s/EMAIL_HERE/aaa-attacker@example.invalid/" -e "s/'TEMP_PASSWORD_HERE'/'Temp-Pass-12345'/" "$TMPL" > "$WORK/tmp_bad.sql"
OUT=$("${P[@]}" -d prod -f "$WORK/tmp_bad.sql" 2>&1) || true; check "פתרון זמני: אימייל שאינו חשבון קיים נדחה" "1" "$(echo "$OUT" | grep -c 'לא נמצא')"

# ---------- 5. ביטול ----------
if "${P[@]}" -d prod -f "$ROOT/supabase/production/99_production_rollback.sql" >"$WORK/rb.out" 2>&1; then ok "הביטול עבר"; else bad "הביטול עבר" "$(tail -3 "$WORK/rb.out")"; fi
check "אחרי הביטול docs זהה בדיוק למצב שלפני" "$BEFORE" "$(q prod "$SNAP")"
check "אחרי הביטול נמחקו משתמשי ההתחברות שנוצרו במעבר" "0" "$(q prod 'select count(*) from auth.users')"
check "הגיבוי הידני מ-9.10 לא השתנה בביטול" "$MANUAL" "$(q prod "select md5(string_agg(collection||'|'||id||'|'||data::text, ',' order by collection, id)) from hdm_backup.docs_20261009")"
check "אחרי הביטול אין טבלאות hdm_ חדשות" "0" "$(q prod "select count(*) from pg_class where relnamespace='public'::regnamespace and relname like 'hdm\_%'")"

# ---------- 6. בדיקות השרת של Staging (אותו קוד שרת) ----------
"${P[@]}" -c 'create database stg'
"${P[@]}" -d stg -f "$HERE/local_supabase_mock.sql" >/dev/null 2>&1
for f in 01_staging_setup 03_staging_fixes 04_staging_profile_id_fix 05_staging_profile_hardening; do
  "${P[@]}" -d stg -f "$ROOT/supabase/staging_secure/$f.sql" >/dev/null
done
T=$("${P[@]}" -d stg -At -F'|' -f "$ROOT/supabase/staging_secure/02_staging_tests.sql")
TOT=$(echo "$T" | awk -F'|' '$1>0 && $1<999' | wc -l); OKN=$(echo "$T" | awk -F'|' '$1>0 && $1<999 && $6=="✅"' | wc -l)
echo "$T" | awk -F'|' '$1>0 && $1<999 && $6!="✅" {print "   ❌ " $2 ": " $3 " (צפוי " $4 ", התקבל " $5 ")"}'
check "בדיקות SQL של Staging (מנויים חינם/בסיסי/פלוס/VIP, RLS, עקיפות)" "$TOT/$TOT" "$OKN/$TOT"
check "בדיקות SQL: לא נשארו נתוני בדיקה" "0|0" "$(q stg "select (select count(*) from public.docs)||'|'||(select count(*) from auth.users)")"

echo; echo "סיכום: עברו $PASS מתוך $((PASS+FAIL))"
[ "$FAIL" = 0 ]
