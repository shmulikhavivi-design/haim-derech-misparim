#!/usr/bin/env bash
# cardlink — קישור שמירת כרטיס לבעלים (בלי חיוב), מוצפן במפתח הסשן ומועבר בענף זמני.
OUTD="${RUNNER_TEMP:-/tmp}/hdm-export"; rm -rf "$OUTD"; mkdir -p "$OUTD/out"
command -v deno >/dev/null || { curl -fsSL https://deno.land/install.sh | sh -s -- -y >/dev/null 2>&1; export PATH="$HOME/.deno/bin:$PATH"; }
echo "::add-mask::$MORNING_CLIENT_SECRET"
OUTF="$OUTD/r.json" deno run --allow-net=api.morning.co,api.greeninvoice.co.il --allow-env --allow-read --allow-write="$OUTD" "$ROOT/scripts/production/owner_card_link.ts" || stop "יצירת הקישור נכשלה"
openssl rand -out "$OUTD/k.bin" 32
openssl enc -aes-256-cbc -pbkdf2 -salt -in "$OUTD/r.json" -out "$OUTD/out/backup.tgz.enc" -pass file:"$OUTD/k.bin"
openssl pkeyutl -encrypt -pubin -inkey "$HERE/session_read_public.pem" -pkeyopt rsa_padding_mode:oaep -in "$OUTD/k.bin" -out "$OUTD/out/key.enc"
shred -u "$OUTD/k.bin" "$OUTD/r.json"
ann notice "prod-result" "✅ cardlink: נוצר ומוצפן"
