#!/usr/bin/env bash
# cardlink — קישור שמירת כרטיס לבעלים (בלי חיוב), מוצפן במפתח הסשן ומועבר בענף זמני.
OUTD="${RUNNER_TEMP:-/tmp}/hdm-export"; rm -rf "$OUTD"; mkdir -p "$OUTD/out"
command -v deno >/dev/null || { curl -fsSL https://deno.land/install.sh | sh -s -- -y >/dev/null 2>&1; export PATH="$HOME/.deno/bin:$PATH"; }
command -v deno >/dev/null || stop "deno לא הותקן"; ann notice "card-link-env" "deno $(deno --version | head -1)"
echo "::add-mask::$MORNING_CLIENT_SECRET"
OUTF="$OUTD/r.json" deno run --allow-net=api.morning.co,api.greeninvoice.co.il --allow-env --allow-read --allow-write="$OUTD" "$ROOT/scripts/production/owner_card_link.ts" || stop "יצירת הקישור נכשלה"
# בדיקת תקינות הקישור לפני שליחה: טעינת הדף בלבד (בלי הזנה, בלי חיוב) — כפי שהוא, ובקידוד תקני של % (=%25)
RAW=$(jq -r .url "$OUTD/r.json"); ENC=$(printf '%s' "$RAW" | sed -E 's/%([^0-9A-Fa-f]|[0-9A-Fa-f][^0-9A-Fa-f])/%25\1/g')
t(){ local code size title; code=$(curl -sS -L -m 30 -A 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1' -o /tmp/cl.html -w '%{http_code}' "$1" || echo 000)
  size=$(wc -c < /tmp/cl.html 2>/dev/null || echo 0); title=$(grep -o '<title>[^<]*' /tmp/cl.html | head -1 | sed 's/<title>//' | cut -c1-60)
  local form; form=$(grep -ciE 'card|כרטיס|credit|cc-number|iframe' /tmp/cl.html || true); echo "HTTP $code · $size בתים · כותרת: ${title:-—} · סימני טופס: $form"; }
vis(){ curl -sS -L -m 30 -A 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1' "$1" | python3 -c "
import sys,re,html
s=sys.stdin.read(); s=re.sub(r'(?is)<(script|style)[^>]*>.*?</\\1>',' ',s); t=html.unescape(re.sub(r'<[^>]+>',' ',s)); t=re.sub(r'\\s+',' ',t).strip()
print(len(s), '|', t[:220])"; }
BAD="https://secure.meshulam.co.il/credit-checkout-form?l=00000000000000000000000000000000%25MDAwMDAwMDA"
ann notice "card-link-check" "כפי שהוא: $(t "$RAW")%0Aמקודד (%25): $(t "$ENC")%0Aטקסט הדף (מקודד): $(vis "$ENC")%0Aטקסט הדף (קישור שגוי בכוונה): $(vis "$BAD")"
jq --arg e "$ENC" '. + {url_encoded: $e}' "$OUTD/r.json" > "$OUTD/r2.json" && mv "$OUTD/r2.json" "$OUTD/r.json"; rm -f /tmp/cl.html
openssl rand -out "$OUTD/k.bin" 32
openssl enc -aes-256-cbc -pbkdf2 -salt -in "$OUTD/r.json" -out "$OUTD/out/backup.tgz.enc" -pass file:"$OUTD/k.bin"
openssl pkeyutl -encrypt -pubin -inkey "$HERE/session_read_public.pem" -pkeyopt rsa_padding_mode:oaep -in "$OUTD/k.bin" -out "$OUTD/out/key.enc"
shred -u "$OUTD/k.bin" "$OUTD/r.json"
ann notice "prod-result" "✅ cardlink: נוצר ומוצפן"
