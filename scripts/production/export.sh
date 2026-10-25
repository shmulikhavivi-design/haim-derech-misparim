#!/usr/bin/env bash
# =====================================================================
# export — גיבוי חיצוני מלא, קריאה בלבד מ-Production. הקובץ מוצפן (AES-256 + RSA) לפני שהוא יוצא מהשרת,
# כך שגם אם מישהו מוריד את ה-artifact, אי אפשר לקרוא אותו בלי המפתח הפרטי (שלא נמצא בריפו).
# =====================================================================
RO="https://api.supabase.com/v1/projects/$PROD_REF/database/query"  # the current token runs queries read-only
OUTD="${RUNNER_TEMP:-/tmp}/hdm-export"; rm -rf "$OUTD"; mkdir -p "$OUTD/data"
roq(){ curl -sS -m 120 -o "$2" -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')" || echo 000; }
get(){ local n="$1" q="$2"; local c; c=$(roq "select coalesce(json_agg(t),'[]'::json) as j from ($q) t" "$OUTD/raw.json"); [ "$c" = 201 ] || stop "גיבוי $n: HTTP $c $(jq -r '.message // empty' "$OUTD/raw.json" | cut -c1-200)"; jq -c '.[0].j' "$OUTD/raw.json" > "$OUTD/data/$n.json"; echo "$n=$(jq length "$OUTD/data/$n.json")"; }
L=""
L+="$(get docs "select collection, id, data, updated_at from public.docs order by collection, id") "
# (הגיבוי הפנימי מ-9.10 נמחק באישור הבעלים 22.10 — לא נכלל עוד)
L+="$(get auth_users "select * from auth.users order by created_at") "
L+="$(get auth_identities "select * from auth.identities order by created_at") "
L+="$(get docs_policies "select policyname, cmd, roles::text, qual, with_check from pg_policies where schemaname='public' and tablename='docs'") "
L+="$(get storage_objects "select bucket_id, name, metadata->>'size' as size, created_at from storage.objects order by bucket_id, name") "
# כל טבלאות public (כולל מנויים, תשלומים, טוקנים, התראות ותור מיילים) — רשימה דינמית, כדי שטבלה חדשה לא תיפול מהגיבוי
TABS=$(curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d '{"query":"select string_agg(tablename, chr(32) order by tablename) t from pg_tables where schemaname=chr(112)||chr(117)||chr(98)||chr(108)||chr(105)||chr(99) and tablename<>chr(100)||chr(111)||chr(99)||chr(115)"}' | jq -r '.[0].t // empty')
[ -n "$TABS" ] || stop "גיבוי: לא התקבלה רשימת הטבלאות"
for t in $TABS; do
  L+="$(get $t "select * from public.\"$t\"") "
done
L+="$(get cron_jobs "select jobid, jobname, schedule, active from cron.job order by jobid") "
C=$(roq "select md5(string_agg(collection||'|'||id||'|'||data::text, ',' order by collection, id)) as docs_md5, count(*) as n, (select count(*) from public.docs where collection='profiles') as profiles, (select count(*) from public.docs where collection='chats') as chats, (select count(*) from public.docs where collection='matches') as matches, (select count(*) from public.docs where collection='interests') as interests, (select count(*) from public.docs where collection like 'data/users/%') as accounts, (select count(*) from auth.users) as auth_users, now() as taken_at from public.docs" "$OUTD/data/fingerprint_raw.json")
[ "$C" = 201 ] || stop "טביעת אצבע: HTTP $C"; jq -c '.[0]' "$OUTD/data/fingerprint_raw.json" > "$OUTD/data/fingerprint.json"; rm -f "$OUTD/data/fingerprint_raw.json" "$OUTD/raw.json"
ann notice "prod-export-counts" "$L | $(cat "$OUTD/data/fingerprint.json" | jq -c 'del(.docs_md5)')"
tar -C "$OUTD" -czf "$OUTD/backup.tgz" data
openssl rand -out "$OUTD/k.bin" 32
openssl enc -aes-256-cbc -pbkdf2 -salt -in "$OUTD/backup.tgz" -out "$OUTD/backup.tgz.enc" -pass file:"$OUTD/k.bin"
openssl pkeyutl -encrypt -pubin -inkey "$HERE/backup_public.pem" -pkeyopt rsa_padding_mode:oaep -in "$OUTD/k.bin" -out "$OUTD/key.enc"
shred -u "$OUTD/k.bin" "$OUTD/backup.tgz"; rm -rf "$OUTD/data"
mkdir -p "$OUTD/out"; mv "$OUTD/backup.tgz.enc" "$OUTD/key.enc" "$OUTD/out/"
echo "export_dir=$OUTD/out" >> "${GITHUB_OUTPUT:-/dev/null}"
ann notice "prod-result" "✅ export: גיבוי חיצוני מוצפן נוצר ($(du -h "$OUTD/out/backup.tgz.enc" | cut -f1)). Production נקרא בלבד."
