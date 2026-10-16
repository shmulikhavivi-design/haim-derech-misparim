#!/usr/bin/env bash
# =====================================================================
# simulate — סימולציית מעבר מלאה על עותק זמני של נתוני Production, על שרת GitHub בלבד.
# Production נקרא בלבד (נקודת הקצה read-only). העותק נמחק בסוף הריצה. מודפסים רק מספרים ותוצאות בדיקה.
# קלט: TOK, PROD_REF, ROOT, ann()  (נטען מתוך run.sh)
# =====================================================================
RO="https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only"
roq(){ curl -sS -m 60 -o "$2" -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')" || echo 000; }
W="$(mktemp -d)"; chmod 755 "$W"
C=$(roq "select string_agg(column_name||':'||data_type||':'||is_nullable||':'||coalesce(column_default,'-'), ',' order by ordinal_position) as cols, (select string_agg(a.attname, ',' order by array_position(i.indkey, a.attnum)) from pg_index i join pg_attribute a on a.attrelid=i.indrelid and a.attnum = any(i.indkey) where i.indrelid='public.docs'::regclass and i.indisprimary) as pk from information_schema.columns where table_schema='public' and table_name='docs'" "$W/cols.json")
COLS=$(jq -r '.[0].cols' "$W/cols.json"); PK=$(jq -r '.[0].pk' "$W/cols.json"); ann notice "sim-docs-columns" "HTTP $C $COLS | pk=$PK"
[ "$COLS" = "collection:text:NO:-,id:text:NO:-,data:jsonb:NO:'{}'::jsonb,updated_at:timestamp with time zone:NO:now()" ] && [ "$PK" = "collection,id" ] || stop "מבנה docs שונה מהצפוי ($COLS) — הסימולציה צריכה התאמה"
C=$(roq "select coalesce(json_agg(json_build_object('c',collection,'i',id,'d',data,'u',updated_at)),'[]') as j from public.docs" "$W/docs.json"); [ "$C" = 201 ] || stop "קריאת docs: HTTP $C"
jq -c '.[0].j' "$W/docs.json" > "$W/docs1.json"
C=$(roq "select coalesce(json_agg(json_build_object('id',id,'aud',aud,'role',role,'email',email,'email_confirmed_at',email_confirmed_at,'last_sign_in_at',last_sign_in_at,'raw_app_meta_data',raw_app_meta_data,'raw_user_meta_data',raw_user_meta_data,'created_at',created_at,'updated_at',updated_at,'is_sso_user',is_sso_user,'is_anonymous',is_anonymous)),'[]') as j from auth.users" "$W/u.json"); [ "$C" = 201 ] || stop "קריאת auth.users: HTTP $C"
jq -c '.[0].j' "$W/u.json" > "$W/users1.json"
C=$(roq "select coalesce(json_agg(json_build_object('id',id,'provider_id',provider_id,'user_id',user_id,'identity_data',identity_data,'provider',provider,'created_at',created_at,'updated_at',updated_at)),'[]') as j from auth.identities" "$W/i.json"); [ "$C" = 201 ] || stop "קריאת auth.identities: HTTP $C"
jq -c '.[0].j' "$W/i.json" > "$W/ids1.json"
ann notice "sim-copy" "הועתקו לעותק הזמני: docs=$(jq length "$W/docs1.json") auth.users=$(jq length "$W/users1.json") identities=$(jq length "$W/ids1.json") (בלי סיסמאות)"

PGBIN="$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)"; D="$W/pg"; PORT=54399
sudo chown -R postgres "$W"; sudo chmod -R a+rX "$W"
sudo -u postgres "$PGBIN/initdb" -D "$D" -U postgres --auth=trust -E UTF8 --locale=C.UTF-8 >/dev/null
sudo -u postgres "$PGBIN/pg_ctl" -D "$D" -o "-p $PORT -k $W -c listen_addresses=" -l "$W/pg.log" -w start >/dev/null
trap 'sudo -u postgres "$PGBIN/pg_ctl" -D "$D" -m immediate stop >/dev/null 2>&1 || true; sudo rm -rf "$W"' EXIT
P=(psql -h "$W" -p "$PORT" -U postgres -d postgres -X -v ON_ERROR_STOP=1 -q -At -P pager=off)
"${P[@]}" -f "$ROOT/scripts/release/local_supabase_mock.sql" >/dev/null
sed -e "s#__DOCS__#$W/docs1.json#" -e "s#__USERS__#$W/users1.json#" -e "s#__IDS__#$W/ids1.json#" <<'SQL' | "${P[@]}" >/dev/null
create table public.docs (collection text not null, id text not null, data jsonb not null default '{}'::jsonb, updated_at timestamptz not null default now(), primary key (collection,id));
alter table public.docs enable row level security;
create policy "Allow public read" on public.docs for select using (true);
create policy "Allow public insert" on public.docs for insert with check (true);
create policy "Allow public update" on public.docs for update using (true);
create policy "Allow public delete" on public.docs for delete using (true);
grant all on public.docs to anon, authenticated;
\set content `cat __DOCS__`
insert into public.docs select x->>'c', x->>'i', x->'d', coalesce((x->>'u')::timestamptz, now()) from jsonb_array_elements(:'content'::jsonb) x;
\set content `cat __USERS__`
insert into auth.users (id,aud,role,email,email_confirmed_at,last_sign_in_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,is_sso_user,is_anonymous)
  select (x->>'id')::uuid, x->>'aud', x->>'role', x->>'email', (x->>'email_confirmed_at')::timestamptz, (x->>'last_sign_in_at')::timestamptz,
         x->'raw_app_meta_data', x->'raw_user_meta_data', (x->>'created_at')::timestamptz, (x->>'updated_at')::timestamptz,
         coalesce((x->>'is_sso_user')::bool,false), coalesce((x->>'is_anonymous')::bool,false)
  from jsonb_array_elements(:'content'::jsonb) x;
\set content `cat __IDS__`
insert into auth.identities (id,provider_id,user_id,identity_data,provider,created_at,updated_at)
  select (x->>'id')::uuid, x->>'provider_id', (x->>'user_id')::uuid, x->'identity_data', x->>'provider', (x->>'created_at')::timestamptz, (x->>'updated_at')::timestamptz
  from jsonb_array_elements(:'content'::jsonb) x;
create schema hdm_backup; create table hdm_backup.docs_20261009 as table public.docs;
SQL
SNAP="select md5(string_agg(collection||'|'||id||'|'||data::text, ',' order by collection, id)) from public.docs"
BEFORE=$("${P[@]}" -c "$SNAP"); N0=$("${P[@]}" -c "select count(*) from public.docs"); MAN=$("${P[@]}" -c "select md5(string_agg(collection||'|'||id, ',' order by collection,id)) from hdm_backup.docs_20261009")
CH0=$("${P[@]}" -c "select md5(string_agg(id||'|'||(data->'messages')::text, ',' order by id)) from public.docs where collection='chats'")
PASS=0; FAIL=0; RES=""
chk(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); RES+="✅ $1"$'\n'; else FAIL=$((FAIL+1)); RES+="❌ $1 (צפוי $2, התקבל $3)"$'\n'; fi; }

PRE=$("${P[@]}" -F'|' -f "$ROOT/supabase/production/00_production_preflight_readonly.sql" 2>&1) || true
chk "בדיקה מקדימה על העותק: אין ❌" "0" "$(printf '%s\n' "$PRE" | grep -c '❌' || true)"
if MIG=$("${P[@]}" -F'|' -f "$ROOT/supabase/production/01_production_migration.sql" 2>&1); then chk "המעבר רץ עד הסוף" ok ok; ann notice "sim-migration-status" "$(printf '%s' "$MIG" | tail -2)"
else chk "המעבר רץ עד הסוף" ok "שגיאה"; ann error "sim-migration-error" "$(printf '%s' "$MIG" | tail -5)"; fi
chk "כל רשומות docs נשמרו בגיבוי" "$N0" "$("${P[@]}" -c "select count(*) from hdm_backup.docs_before_migration")"
chk "כל רשומה קיימת עדיין קיימת (לפי מפתח)" "$N0" "$("${P[@]}" -c "select count(*) from public.docs d join hdm_backup.docs_before_migration b using (collection,id)")"
chk "תוכן הגיבוי זהה למצב לפני" "$BEFORE" "$("${P[@]}" -c "select md5(string_agg(collection||'|'||id||'|'||data::text, ',' order by collection, id)) from hdm_backup.docs_before_migration")"
chk "השיחות וההודעות לא השתנו" "$CH0" "$("${P[@]}" -c "select md5(string_agg(id||'|'||(data->'messages')::text, ',' order by id)) from public.docs where collection='chats'")"
chk "תאריכי לידה הוצאו מהפרופיל הגלוי" "0" "$("${P[@]}" -c "select count(*) from public.docs where collection='profiles' and data ? 'birthdate'")"
chk "לכל פרופיל רשומה פרטית" "$("${P[@]}" -c "select count(*) from public.docs where collection='profiles'")" "$("${P[@]}" -c "select count(*) from public.hdm_profile_private")"
chk "4 החשבונות הקיימים מוכנים לקישור" "4" "$("${P[@]}" -c "select count(*) from public.hdm_legacy_accounts")"
chk "אין פרופילים לבדיקה ידנית" "0" "$("${P[@]}" -c "select count(distinct profile_id) from public.hdm_legacy_review")"
chk "הגיבוי הידני מ-9.10 לא השתנה" "$MAN" "$("${P[@]}" -c "select md5(string_agg(collection||'|'||id, ',' order by collection,id)) from hdm_backup.docs_20261009")"
chk "משתמשי Auth לא נמחקו" "$(jq length "$W/users1.json")" "$("${P[@]}" -c "select count(*) from auth.users where id in (select (x->>'id')::uuid from jsonb_array_elements('$(cat "$W/users1.json" | jq -c '[.[]|{id}]')'::jsonb) x)")"
chk "anon לא יכול לקרוא תאריכי לידה" "f" "$("${P[@]}" -c "select has_table_privilege('anon','public.hdm_profile_private','select')")"
chk "אישור מסמכים: גרסה נדרשת 2026-10-16" "2026-10-16" "$("${P[@]}" -c "select public.hdm_required_terms_version()")"
chk "אישור מסמכים: המעבר לא אישר בשם אף משתמש" "0" "$("${P[@]}" -c "select count(*) from public.hdm_consents")"
T15=$("${P[@]}" -F'|' -f "$ROOT/supabase/staging_secure/15_staging_consent_tests.sql" 2>&1 || true)
chk "בדיקות האישור (15) על העותק אחרי המעבר" "1" "$(printf '%s\n' "$T15" | grep -cE 'עברו ([0-9]+) מתוך \1$' || true)"
if PL=$("${P[@]}" -f "$ROOT/supabase/production/03_existing_accounts_plus.sql" 2>&1); then chk "Plus לחשבונות הקיימים רץ" ok ok; else chk "Plus לחשבונות הקיימים רץ" ok "שגיאה"; ann error "sim-plus-error" "$(printf '%s' "$PL" | tail -5)"; fi
chk "4 מנויי Plus פעילים" "4" "$("${P[@]}" -c "select count(*) from public.hdm_subscriptions where plan='plus' and status='active'")"
"${P[@]}" -f "$ROOT/supabase/production/03_existing_accounts_plus.sql" >/dev/null 2>&1 || true
chk "הרצה חוזרת של Plus לא מוסיפה" "4" "$("${P[@]}" -c "select count(*) from public.hdm_subscriptions")"
STATS=$("${P[@]}" -c "select 'interests='||(select count(*) from public.docs where collection='interests')||' chats='||(select count(*) from public.docs where collection='chats')||' subs='||(select count(*) from public.hdm_subscriptions)||' policies='||(select count(*) from pg_policies where schemaname='public')")
ann notice "sim-after" "$STATS"
if RB=$("${P[@]}" -f "$ROOT/supabase/production/99_production_rollback.sql" 2>&1); then chk "ביטול (rollback) רץ" ok ok; else chk "ביטול (rollback) רץ" ok "שגיאה"; ann error "sim-rollback-error" "$(printf '%s' "$RB" | tail -5)"; fi
chk "אחרי ביטול: docs זהה בדיוק למצב לפני" "$BEFORE" "$("${P[@]}" -c "$SNAP")"
ann notice "sim-results" "$RES"
[ "$FAIL" = 0 ] && ann notice "prod-result" "✅ סימולציה: $PASS/$((PASS+FAIL)) עברו. Production נקרא בלבד, העותק נמחק." \
                || stop "סימולציה: $FAIL נכשלו מתוך $((PASS+FAIL)). Production נקרא בלבד, לא שונה כלום."
