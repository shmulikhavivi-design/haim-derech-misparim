#!/usr/bin/env bash
# incident4 — מסלול מלא: הרשמה → קישור אישור אמיתי (generate_link) → מעקב אחרי ההפניה (GitHub/Cloudflare) → כניסה; דפדפנים: Chrome, ספארי (אייפון), Firefox.
# משתמשי בדיקה בתיבת האפליקציה בלבד (+incc…). לא מוחק, לא מחייב, לא משנה הגדרות או מפתחות.
A="https://api.supabase.com/v1/projects/$PROD_REF"; AU="https://$PROD_REF.supabase.co/auth/v1"
clean(){ sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g; s/eyJ[A-Za-z0-9._-]+/<jwt>/g; s/(token|code)=[A-Za-z0-9_-]+/\1=<x>/g'; }
PUB='sb_publishable_wwoXFH3xChSfQxHKZEbTKA_t_u5aGMP'
SK=$(curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/api-keys?reveal=true" | jq -r '[.[] | select(.type=="secret" or .name=="service_role") | .api_key // empty][0] // empty')
[ -n "$SK" ] && echo "::add-mask::$SK"
ann warning "i4-adminkey" "מפתח שרת לבדיקת קישורי אישור: $([ -n "$SK" ] && echo זמין || echo 'לא זמין להרשאה הזו')"
T="${GITHUB_RUN_ID:-x}"; R=""
for site in https://shmulikhavivi-design.github.io/haim-derech-misparim/ https://haim-derech-misparim.pages.dev/; do
  tag=$(echo $site | cut -d/ -f3 | cut -d. -f1 | tr -cd 'a-z'); EM="life.through.numbers333+incc$tag$T@gmail.com"; PW="Hdm-$(openssl rand -hex 8)-Aa1!"; echo "::add-mask::$PW"
  if [ -n "$SK" ]; then
    curl -sS -m 40 -o /tmp/gl.json -X POST -H "apikey: $SK" -H "Authorization: Bearer $SK" -H 'Content-Type: application/json' "$AU/admin/generate_link" \
      -d "$(jq -nc --arg e "$EM" --arg p "$PW" --arg r "$site" '{type:"signup", email:$e, password:$p, redirect_to:$r}')"
    LINK=$(jq -r '.action_link // .properties.action_link // empty' /tmp/gl.json); echo "::add-mask::$LINK"
    LOC=$(curl -sS -m 30 -o /dev/null -w '%{http_code} %{redirect_url}' "$LINK" || echo 000)
    DEST=$(echo "$LOC" | awk '{print $2}' | cut -d'#' -f1 | cut -d'?' -f1); HASTOK=$(echo "$LOC" | grep -c 'access_token=')
    ERR=$(echo "$LOC" | grep -o 'error_description=[^&]*' | head -1)
    LI=$(curl -sS -m 40 -o /tmp/li.json -w '%{http_code}' -X POST -H "apikey: $PUB" -H 'Content-Type: application/json' "$AU/token?grant_type=password" -d "$(jq -nc --arg e "$EM" --arg p "$PW" '{email:$e,password:$p}')" || echo 000)
    R="$R
[$tag] קישור אישור: $(echo "$LOC" | awk '{print $1}') → מוביל ל־$DEST (טוקן כניסה בקישור: $HASTOK) $ERR | ביקשנו חזרה ל־$site | כניסה אחרי אישור: HTTP $LI $(jq -c '{session:(.access_token!=null), code:(.error_code//null)}' /tmp/li.json)"
    [ "$tag" = haimderech ] && { B_EM="$EM"; B_PW="$PW"; }
    [ -z "${B_EM:-}" ] && { B_EM="$EM"; B_PW="$PW"; }
  fi
done
ann notice "i4-confirm-flow" "$(echo "$R" | clean)"
# שליחת מייל אישור אמיתית (הרשמה רגילה) עם חזרה לכתובת Cloudflare — האם Auth מקבל/שולח
EMX="life.through.numbers333+inccmail$T@gmail.com"; PWX="Hdm-$(openssl rand -hex 8)-Aa1!"; echo "::add-mask::$PWX"
C=$(curl -sS -m 40 -o /tmp/su.json -w '%{http_code}' -X POST -H "apikey: $PUB" -H 'Content-Type: application/json' "$AU/signup?redirect_to=$(jq -rn '"https://haim-derech-misparim.pages.dev/"|@uri')" -d "$(jq -nc --arg e "$EMX" --arg p "$PWX" '{email:$e,password:$p}')" || echo 000)
ann notice "i4-signup-mail" "הרשמה רגילה (מייל אישור אמיתי לתיבת האפליקציה, חזרה ל-Cloudflare): HTTP $C $(jq -c '{user:(.id!=null), code:(.error_code//.code//null), msg:(.msg//null)}' /tmp/su.json | clean)"
# Cloudflare: כותרות שיכולות לחסום (CSP / מטמון)
H=$(curl -sS -m 30 -D - -o /dev/null https://haim-derech-misparim.pages.dev/ | tr -d '\r' | grep -iE '^(content-security-policy|cache-control|cf-cache-status|age|x-frame-options|permissions-policy|location|server):' | tr '\n' ' ')
H2=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' https://haim-derech-misparim.pages.dev/index.html)
ann notice "i4-cloudflare" "כותרות Cloudflare: $H | index.html: $H2"
# דפדפנים
if [ -n "${B_EM:-}" ]; then
  python3 -m pip install -q playwright >/dev/null && python3 -m playwright install --with-deps chromium webkit firefox >/dev/null 2>&1 || stop "התקנת הדפדפנים נכשלה"
  OUT=$(T_EM="$B_EM" T_PW="$B_PW" SU_EM=x python3 "$HERE/incident_browsers.py" 2>&1 | tail -c 3500 | clean)
  ann notice "i4-browsers" "$OUT"
fi
ann notice "prod-result" "incident4 הסתיים — משתמשי בדיקה בתיבת האפליקציה בלבד; לא נמחק ולא שונה כלום"
