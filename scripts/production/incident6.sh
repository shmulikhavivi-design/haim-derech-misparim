#!/usr/bin/env bash
# incident6 — אחרי עדכון הבעלים (17:57): לוגי Auth, הגדרות Auth, Brevo (מפתח + דוח מסירה), הפניית Cloudflare, הרשמות חדשות. קריאה + משתמש בדיקה אחד. בלי מחיקה/שינוי.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"; AU="https://$PROD_REF.supabase.co/auth/v1"; PUB='sb_publishable_wwoXFH3xChSfQxHKZEbTKA_t_u5aGMP'
clean(){ sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g; s/eyJ[A-Za-z0-9._-]+/<jwt>/g; s/[0-9]{1,3}(\.[0-9]{1,3}){3}/<ip>/g'; }
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
# 1. Brevo
if [ -n "${GH_BREVO_API:-}" ]; then
  K="$GH_BREVO_API"; L=$(printf '%s' "$K" | wc -c); P=$(case "$K" in xkeysib-*) echo xkeysib;; xsmtpsib-*) echo xsmtpsib;; *) echo אחר;; esac)
  C1=$(curl -sS -m 30 -o /tmp/ba.json -w '%{http_code}' -H "api-key: $K" https://api.brevo.com/v3/account || echo 000)
  PLAN=$(jq -c '[.plan[]? | {type, credits, creditsType}]' /tmp/ba.json 2>/dev/null)
  C2=$(curl -sS -m 30 -o /tmp/bs.json -w '%{http_code}' -H "api-key: $K" https://api.brevo.com/v3/senders || echo 000)
  SND=$(jq -r --arg f life.through.numbers333@gmail.com '[.senders[]? | select((.email|ascii_downcase)==$f) | (if .active then "פעיל" else "לא פעיל" end)] | if length==0 then "לא נמצא" else join(",") end' /tmp/bs.json 2>/dev/null)
  C3=$(curl -sS -m 30 -o /tmp/be.json -w '%{http_code}' -H "api-key: $K" "https://api.brevo.com/v3/smtp/statistics/events?days=2&limit=500&sort=desc" || echo 000)
  EV=$(jq -c '[.events[]? | .event] | group_by(.) | map({(.[0]): length}) | add' /tmp/be.json 2>/dev/null)
  BAD=$(jq -c '[.events[]? | select(.event|test("bounce|blocked|error|invalid|deferred|spam";"i")) | {e: .event, at: (.date|.[5:16]), r: (.reason // "" | .[0:80]), s: (.subject // "" | .[0:30])}] | .[0:8]' /tmp/be.json 2>/dev/null | clean)
  LAST=$(jq -c '[.events[]? | select(.event=="requests" or .event=="request" or .event=="delivered") | {e: .event, at: (.date|.[5:16]), s: (.subject // "" | .[0:25])}] | .[0:6]' /tmp/be.json 2>/dev/null | clean)
  C4=$(curl -sS -m 30 -o /tmp/ag.json -w '%{http_code}' -H "api-key: $K" "https://api.brevo.com/v3/smtp/statistics/aggregatedReport?days=1" || echo 000)
  AG=$(jq -c '{requests, delivered, hardBounces, softBounces, blocked, invalid, opens, clicks}' /tmp/ag.json 2>/dev/null)
  ann notice "i6-brevo" "מפתח: אורך $L, סוג $P | account $C1 | תוכנית/קרדיטים: $PLAN | senders $C2 (שולח האפליקציה: $SND) | 24 שעות: $C4 $AG | אירועים 48ש׳ ($C3): $EV | בעיות: $BAD | אחרונים: $LAST"
else ann warning "i6-brevo" "BREVO_API_KEY לא זמין לתהליך"; fi
# 2. הגדרות Auth (אם יש הרשאה עכשיו)
C=$(curl -sS -m 30 -o /tmp/cfg.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$A/config/auth" || echo 000)
ann notice "i6-authcfg" "HTTP $C $(jq -c '{site_url, uri_allow_list, confirm_email: (.mailer_autoconfirm == false), smtp_host, smtp_port, smtp_user_set: ((.smtp_user//"")!=""), smtp_pass_set: ((.smtp_pass//"")!=""), sender: .smtp_admin_email, rate_limit_email_sent, rate_limit_verify, rate_limit_otp, smtp_max_frequency, disable_signup, captcha: .security_captcha_enabled, hook_send_email: .hook_send_email_enabled}' /tmp/cfg.json 2>/dev/null | clean | cut -c1-900)"
# 3. לוגי Auth (6 שעות)
lq(){ curl -sS -m 60 -G -H "Authorization: Bearer $TOK" "$A/analytics/endpoints/logs.all" --data-urlencode "sql=$1" --data-urlencode "iso_timestamp_start=$(date -u -d '-8 hours' +%Y-%m-%dT%H:%M:%SZ)" --data-urlencode "iso_timestamp_end=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
lq "select timestamp, event_message from auth_logs order by timestamp desc limit 1000" > /tmp/al.json
if jq -e '.result' /tmp/al.json >/dev/null 2>&1; then
  SUMM=$(jq -c '[.result[] | (.event_message | fromjson? // {}) | select((.level // "") == "error" or ((.status // 0) >= 400) or ((.msg // "") | test("error|fail|limit";"i")))
           | {lvl: .level, st: .status, path: .path, msg: ((.msg // "") | .[0:60]), err: ((.error // "") | .[0:90])}] | group_by(.path, .st, .err, .msg) | map(.[0] + {n: length}) | sort_by(-.n) | .[0:15]' /tmp/al.json | clean)
  REQ=$(jq -c '[.result[] | (.event_message | fromjson? // {}) | select(.path != null) | "\(.method // "") \(.path) \(.status // "")"] | group_by(.) | map({(.[0]): length}) | add' /tmp/al.json | clean)
  ann notice "i6-authlogs" "שגיאות Auth ב-8 שעות: $SUMM | כל הבקשות לפי נתיב וסטטוס: $REQ"
else ann notice "i6-authlogs" "לוגים: $(jq -c '.' /tmp/al.json | cut -c1-200)"; fi
# 4. הפניית Cloudflare (משתמש בדיקה אחד בתיבת האפליקציה)
T="${GITHUB_RUN_ID:-x}"; EM="life.through.numbers333+incf$T@gmail.com"; PW="Hdm-$(openssl rand -hex 8)-Aa1!"; echo "::add-mask::$PW"; site='https://haim-derech-misparim.pages.dev/'
SC=$(curl -sS -m 40 -o /tmp/su.json -w '%{http_code}' -X POST -H "apikey: $PUB" -H 'Content-Type: application/json' "$AU/signup?redirect_to=$(jq -rn --arg s "$site" '$s|@uri')" -d "$(jq -nc --arg e "$EM" --arg p "$PW" '{email:$e,password:$p}')" || echo 000)
SUERR=$(jq -c '{code:(.error_code//.code//null), msg:(.msg//null)}' /tmp/su.json | clean); sleep 2
TH=$(roq "select coalesce((select token_hash from auth.one_time_tokens o join auth.users u on u.id=o.user_id where u.email='$EM' and o.token_type='confirmation_token' order by o.created_at desc limit 1), (select confirmation_token from auth.users where email='$EM')) t" | jq -r '.[0].t // empty'); [ -n "$TH" ] && echo "::add-mask::$TH"
LOC=$(curl -sS -m 30 -o /dev/null -w '%{http_code} %{redirect_url}' "$AU/verify?token=$TH&type=signup&redirect_to=$(jq -rn --arg s "$site" '$s|@uri')" || echo 000)
ann notice "i6-redirect" "הרשמה (חזרה ל-Cloudflare): HTTP $SC $SUERR | קישור האישור מוביל ל: $(echo "$LOC" | awk '{print $2}' | cut -d'#' -f1 | cut -d'?' -f1) $( echo "$LOC" | grep -q 'pages.dev' && echo '✅ Cloudflare' || echo '❌ לא Cloudflare')"
# 5. הרשמות מאז 17:00
Q="select json_agg(x order by x.created) r from (select to_char(u.created_at at time zone 'Asia/Jerusalem','DD.MM HH24:MI') created, case when u.email like 'life.through.numbers333+inc%' then 'בדיקה' else 'לקוח' end kind,
 to_char(u.confirmation_sent_at at time zone 'Asia/Jerusalem','HH24:MI') conf_sent, to_char(u.email_confirmed_at at time zone 'Asia/Jerusalem','HH24:MI') confirmed, to_char(u.last_sign_in_at at time zone 'Asia/Jerusalem','HH24:MI') signin,
 exists (select 1 from public.hdm_accounts a join public.docs d on d.collection='profiles' and d.id=a.profile_id where a.auth_user_id=u.id) profile
 from auth.users u where u.created_at > now() - interval '30 hours' and u.email not like 'life.through.numbers333+inc%') x"
ann notice "i6-new" "חשבונות לקוחות מהיממה האחרונה: $(roq "$Q" | jq -c 'if type=="array" then .[0].r else . end' | tr -d ':')"
ann notice "prod-result" "incident6 הסתיים — קריאה + משתמש בדיקה אחד; לא נמחק ולא שונה כלום"
