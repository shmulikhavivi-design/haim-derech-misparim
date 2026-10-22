#!/usr/bin/env bash
# incident4 — מסלול מלא: הרשמה → קישור אישור אמיתי (generate_link) → מעקב אחרי ההפניה (GitHub/Cloudflare) → כניסה; דפדפנים: Chrome, ספארי (אייפון), Firefox.
# משתמשי בדיקה בתיבת האפליקציה בלבד (+incc…). לא מוחק, לא מחייב, לא משנה הגדרות או מפתחות.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; AU="https://$PROD_REF.supabase.co/auth/v1"
clean(){ sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g; s/eyJ[A-Za-z0-9._-]+/<jwt>/g; s/(token|code)=[A-Za-z0-9_-]+/\1=<x>/g'; }
PUB='sb_publishable_wwoXFH3xChSfQxHKZEbTKA_t_u5aGMP'
SK=$(curl -sS -m 30 -H "Authorization: Bearer $TOK" "$A/api-keys?reveal=true" | jq -r '[.[] | select(.type=="secret" or .name=="service_role") | .api_key // empty][0] // empty')
[ -n "$SK" ] && echo "::add-mask::$SK"
ann warning "i4-adminkey" "מפתח שרת לבדיקת קישורי אישור: $([ -n "$SK" ] && echo זמין || echo 'לא זמין להרשאה הזו')"
T="${GITHUB_RUN_ID:-x}"; R=""
RO="$A/database/query/read-only"
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
SITES_RUN="https://shmulikhavivi-design.github.io/haim-derech-misparim/ https://haim-derech-misparim.pages.dev/"; case "${COMMIT_MSG:-}" in *browsersonly*) SITES_RUN="https://haim-derech-misparim.pages.dev/";; esac
for site in $SITES_RUN; do
  tag=$(echo $site | cut -d/ -f3 | cut -d. -f1 | tr -cd 'a-z'); EM="life.through.numbers333+incc$tag$T@gmail.com"; PW="Hdm-$(openssl rand -hex 8)-Aa1!"; echo "::add-mask::$PW"
  SC=$(curl -sS -m 40 -o /tmp/su.json -w '%{http_code}' -X POST -H "apikey: $PUB" -H 'Content-Type: application/json' "$AU/signup?redirect_to=$(jq -rn --arg s "$site" '$s|@uri')" -d "$(jq -nc --arg e "$EM" --arg p "$PW" '{email:$e,password:$p}')" || echo 000)
  sleep 2
  TH=$(roq "select coalesce((select token_hash from auth.one_time_tokens o join auth.users u on u.id=o.user_id where u.email='$EM' and o.token_type='confirmation_token' order by o.created_at desc limit 1), (select confirmation_token from auth.users where email='$EM')) t" | jq -r '.[0].t // empty')
  [ -n "$TH" ] && echo "::add-mask::$TH"
  LINK="$AU/verify?token=$TH&type=signup&redirect_to=$(jq -rn --arg s "$site" '$s|@uri')"
  LOC=$(curl -sS -m 30 -o /dev/null -w '%{http_code} %{redirect_url}' "$LINK" || echo 000)
  DEST=$(echo "$LOC" | awk '{print $2}' | cut -d'#' -f1 | cut -d'?' -f1); HASTOK=$(echo "$LOC" | grep -c 'access_token=')
  ERR=$(echo "$LOC" | grep -oE 'error_(code|description)=[^&]*' | head -2 | tr '\n' ' ')
  LI=$(curl -sS -m 40 -o /tmp/li.json -w '%{http_code}' -X POST -H "apikey: $PUB" -H 'Content-Type: application/json' "$AU/token?grant_type=password" -d "$(jq -nc --arg e "$EM" --arg p "$PW" '{email:$e,password:$p}')" || echo 000)
  R="$R
[$tag] הרשמה HTTP $SC | קוד אישור נמצא: $([ -n "$TH" ] && echo כן || echo לא) | קישור האישור (כמו במייל): $(echo "$LOC" | awk '{print $1}') → $DEST (כניסה אוטומטית: $HASTOK) $ERR | ביקשנו לחזור ל-$site | כניסה עם סיסמה אחרי אישור: HTTP $LI $(jq -c '{session:(.access_token!=null), code:(.error_code//null)}' /tmp/li.json)"
  if [ "$tag" = haimderech ] || [ -z "${B_EM:-}" ]; then B_EM="$EM"; B_PW="$PW"; fi
done
ann notice "i4-confirm-flow" "$(echo "$R" | clean)"
# Cloudflare: כותרות שיכולות לחסום (CSP / מטמון)
H=$(curl -sS -m 30 -D - -o /dev/null https://haim-derech-misparim.pages.dev/ | tr -d '\r' | grep -iE '^(content-security-policy|cache-control|cf-cache-status|age|x-frame-options|permissions-policy|location|server):' | tr '\n' ' ')
H2=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' https://haim-derech-misparim.pages.dev/index.html)
ann notice "i4-cloudflare" "כותרות Cloudflare: $H | index.html: $H2 (308 = הפניה רגילה לכתובת בלי index.html)"
# דפדפנים
if [ -n "${B_EM:-}" ]; then
  python3 -m pip install -q playwright >/dev/null && python3 -m playwright install --with-deps chromium webkit >/dev/null 2>&1 || stop "התקנת הדפדפנים נכשלה"
  OUT=$(T_EM="$B_EM" T_PW="$B_PW" SU_EM=x python3 "$HERE/incident_browsers.py" 2>&1 | tail -c 3500 | clean)
  ann notice "i4-browsers" "$OUT"
fi
ann notice "prod-result" "incident4 הסתיים — משתמשי בדיקה בתיבת האפליקציה בלבד; לא נמחק ולא שונה כלום"
