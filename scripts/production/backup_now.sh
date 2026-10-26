#!/usr/bin/env bash
# =====================================================================
# backupnow (26.10) — גיבוי מלא של Production לפני פריסה. קריאה בלבד (נקודת הקצה database/query/read-only).
# תיקונים מול export: (1) רק נקודת הקצה לקריאה בלבד; (2) בדיקת שלמות — כל טבלה נספרת מול המסד ונשמרת טביעת SHA-256 לכל קובץ;
# (3) מוצפן לשני מפתחות: מפתח הגיבוי הקבוע (backup_public.pem) ומפתח האימות של הסשן (לבדיקת שחזור מיד אחרי היצירה);
# (4) נשמר כ-artifact ל-90 יום (במקום יום אחד). אף ערך לא מודפס; ביומן — רק מספרי שורות.
# =====================================================================
set +e +o pipefail
RO="https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only"
OUTD="${RUNNER_TEMP:-/tmp}/hdm-export"; rm -rf "$OUTD"; mkdir -p "$OUTD/data" "$OUTD/out"
roq(){ curl -sS -m 120 -o "$2" -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')" || echo 000; }
FAIL=""; L=""
get(){ local n="$1" q="$2" c want got
  c=$(roq "select coalesce(json_agg(t),'[]'::json) as j from ($q) t" "$OUTD/raw.json")
  [ "$c" = 201 ] || { FAIL="$FAIL $n(HTTP $c)"; return; }
  jq -c '.[0].j' "$OUTD/raw.json" > "$OUTD/data/$n.json"; got=$(jq length "$OUTD/data/$n.json")
  c=$(roq "select count(*) n from ($q) t" "$OUTD/cnt.json"); want=$(jq -r '.[0].n' "$OUTD/cnt.json")
  [ "$got" = "$want" ] || FAIL="$FAIL $n(נשמרו $got מתוך $want)"
  L="$L $n=$got"; }
get docs "select collection, id, data, updated_at from public.docs"
get auth_users "select * from auth.users"
get auth_identities "select * from auth.identities"
get storage_objects "select bucket_id, name, metadata->>'size' as size, created_at from storage.objects"
get cron_jobs "select jobid, jobname, schedule, command, active from cron.job"
get policies "select schemaname, tablename, policyname, cmd, roles::text, qual, with_check from pg_policies where schemaname='public'"
get functions_sql "select p.proname, pg_get_function_identity_arguments(p.oid) args, pg_get_functiondef(p.oid) def from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'"
roq "select string_agg(tablename, ' ' order by tablename) t from pg_tables where schemaname='public' and tablename<>'docs'" "$OUTD/t.json" >/dev/null
TABS=$(jq -r '.[0].t // empty' "$OUTD/t.json"); [ -n "$TABS" ] || FAIL="$FAIL table-list"
for t in $TABS; do get "t_$t" "select * from public.\"$t\""; done
roq "select now() taken_at, (select count(*) from auth.users) auth_users, (select count(*) from public.docs where collection='profiles') profiles, (select count(*) from public.hdm_subscriptions) subscriptions, (select count(*) from public.hdm_payments) payments" "$OUTD/fp.json" >/dev/null
jq -c '.[0]' "$OUTD/fp.json" > "$OUTD/data/fingerprint.json"
# הקוד של פונקציות השרת כפי שהוא פרוס עכשיו (נקודת חזרה לפני פריסה) — עם טוקן הפונקציות, קריאה בלבד
if [ -n "${FN_TOK:-}" ]; then
  echo "::add-mask::$FN_TOK"; mkdir -p "$OUTD/data/functions"; FL=""
  for f in morning-checkout morning-webhook morning-renewals hdm-billing-worker; do
    c=$(curl -sS -m 60 -o "$OUTD/data/functions/$f.eszip" -w '%{http_code}' -H "Authorization: Bearer $FN_TOK" "https://api.supabase.com/v1/projects/$PROD_REF/functions/$f/body" || echo 000)
    [ "$c" = 200 ] && [ -s "$OUTD/data/functions/$f.eszip" ] && FL="$FL $f=✅($(wc -c < "$OUTD/data/functions/$f.eszip")B)" || { FL="$FL $f=❌(HTTP $c)"; FAIL="$FAIL fn-$f"; }
  done
  curl -sS -m 30 -H "Authorization: Bearer $FN_TOK" "https://api.supabase.com/v1/projects/$PROD_REF/functions" | jq -c '[.[] | {slug, version, status, verify_jwt, updated_at, entrypoint_path, import_map}]' > "$OUTD/data/functions/list.json"
  ann notice "backup-functions" "קוד הפונקציות הפרוס נשמר:$FL"
fi
(cd "$OUTD/data" && sha256sum *.json > SHA256SUMS; [ -d functions ] && sha256sum functions/* >> SHA256SUMS)
rm -f "$OUTD/raw.json" "$OUTD/cnt.json" "$OUTD/t.json" "$OUTD/fp.json"
[ -z "$FAIL" ] || { rm -rf "$OUTD/data"; ann error "backup" "⛔ הגיבוי לא שלם:$FAIL — לא נשמר"; stop "גיבוי לא שלם"; }
ann notice "backup-counts" "$(echo $L) | $(jq -c . "$OUTD/data/fingerprint.json")"
tar -C "$OUTD" -czf "$OUTD/backup.tgz" data
openssl rand -out "$OUTD/k.bin" 32
openssl enc -aes-256-cbc -pbkdf2 -salt -in "$OUTD/backup.tgz" -out "$OUTD/out/backup.tgz.enc" -pass file:"$OUTD/k.bin"
openssl pkeyutl -encrypt -pubin -inkey "$HERE/backup_public.pem" -pkeyopt rsa_padding_mode:oaep -in "$OUTD/k.bin" -out "$OUTD/out/key.enc"
openssl pkeyutl -encrypt -pubin -inkey "$HERE/session_2610_public.pem" -pkeyopt rsa_padding_mode:oaep -in "$OUTD/k.bin" -out "$OUTD/out/key_verify.enc"
SUM=$(sha256sum "$OUTD/backup.tgz" | cut -d' ' -f1); echo "$SUM" > "$OUTD/out/backup.sha256"
shred -u "$OUTD/k.bin" "$OUTD/backup.tgz"; rm -rf "$OUTD/data"
ann notice "prod-result" "✅ backupnow: גיבוי מלא ושלם, מוצפן ($(du -h "$OUTD/out/backup.tgz.enc" | cut -f1)). Production נקרא בלבד."
