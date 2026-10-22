#!/usr/bin/env bash
# secureread — מריץ שאילתת קריאה בלבד מ-supabase/production/readonly/<name>.sql ומצפין את התוצאה (AES-256 + RSA)
# במפתח הציבורי session_read_public.pem. שום נתון אישי לא מודפס בלוג (הריפו ציבורי).
NAME=$(printf '%s\n' "$COMMIT_MSG" | head -n1 | sed -n 's/.*{read:\([a-z_]*\)}.*/\1/p'); [ -n "$NAME" ] || stop "חסר {read:name}"
SQLF="$ROOT/supabase/production/readonly/$NAME.sql"; [ -f "$SQLF" ] || stop "אין קובץ $NAME"
OUTD="${RUNNER_TEMP:-/tmp}/hdm-export"; rm -rf "$OUTD"; mkdir -p "$OUTD/out"
C=$(curl -sS -m 120 -o "$OUTD/r.json" -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "https://api.supabase.com/v1/projects/$PROD_REF/database/query/read-only" -d "$(jq -nc --rawfile q "$SQLF" '{query:$q}')" || echo 000)
[ "$C" = 201 ] || [ "$C" = 200 ] || { M=$(jq -r ".message // empty" "$OUTD/r.json" 2>/dev/null | cut -c1-300); rm -f "$OUTD/r.json"; stop "שאילתה $NAME: HTTP $C $M"; }
openssl rand -out "$OUTD/k.bin" 32
openssl enc -aes-256-cbc -pbkdf2 -salt -in "$OUTD/r.json" -out "$OUTD/out/backup.tgz.enc" -pass file:"$OUTD/k.bin"
openssl pkeyutl -encrypt -pubin -inkey "$HERE/session_read_public.pem" -pkeyopt rsa_padding_mode:oaep -in "$OUTD/k.bin" -out "$OUTD/out/key.enc"
shred -u "$OUTD/k.bin" "$OUTD/r.json"
echo "export_dir=$OUTD/out" >> "${GITHUB_OUTPUT:-/dev/null}"
ann notice "prod-result" "✅ secureread $NAME: תוצאה מוצפנת נוצרה. קריאה בלבד."
