#!/usr/bin/env bash
# paydiag — אבחון תקלת "לא הצלחנו לפתוח את עמוד התשלום": יומני הפונקציות (24 שעות), ניסיונות התשלום במסד, ושמות סודות הפונקציה.
# קריאה בלבד. התוצאה מוצפנת (הריפו ציבורי) ולא מודפסת.
A="https://api.supabase.com/v1/projects/$PROD_REF"; OUTD="${RUNNER_TEMP:-/tmp}/hdm-export"; rm -rf "$OUTD"; mkdir -p "$OUTD/out" "$OUTD/w"
lq(){ curl -sS -m 60 -G -H "Authorization: Bearer $TOK" "$A/analytics/endpoints/logs.all" --data-urlencode "sql=$1" --data-urlencode "iso_timestamp_start=$(date -u -d '-24 hours' +%Y-%m-%dT%H:%M:%SZ)" --data-urlencode "iso_timestamp_end=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
lq "select timestamp, event_message, metadata from function_logs order by timestamp desc limit 80" > "$OUTD/w/fn.json"
lq "select timestamp, event_message, metadata from function_edge_logs order by timestamp desc limit 60" > "$OUTD/w/edge.json"
curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$A/database/query/read-only" \
  -d "$(jq -nc --arg q "select coalesce(json_agg(row_to_json(k) order by created_at desc), '[]') j from (select id, plan, amount_agorot, status, kind, terms_version, created_at, expires_at, closed_at, grow_process_id from public.hdm_checkouts) k" '{query:$q}')" > "$OUTD/w/ck.json"
curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/secrets" | jq -c '[.[] | {name, len: (.value|tostring|length)}]' > "$OUTD/w/secrets.json"
curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/functions" | jq -c '[.[] | {slug, version, status, verify_jwt, updated_at}]' > "$OUTD/w/functions.json"
ann notice "paydiag-sizes" "fn=$(wc -c < "$OUTD/w/fn.json") edge=$(wc -c < "$OUTD/w/edge.json") ck=$(wc -c < "$OUTD/w/ck.json")"
tar -C "$OUTD" -czf "$OUTD/r.json" w; rm -rf "$OUTD/w"
openssl rand -out "$OUTD/k.bin" 32
openssl enc -aes-256-cbc -pbkdf2 -salt -in "$OUTD/r.json" -out "$OUTD/out/backup.tgz.enc" -pass file:"$OUTD/k.bin"
openssl pkeyutl -encrypt -pubin -inkey "$HERE/session_read_public.pem" -pkeyopt rsa_padding_mode:oaep -in "$OUTD/k.bin" -out "$OUTD/out/key.enc"
shred -u "$OUTD/k.bin" "$OUTD/r.json"
ann notice "prod-result" "✅ paydiag: נאסף ומוצפן (קריאה בלבד)"
