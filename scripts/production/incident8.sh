#!/usr/bin/env bash
# incident8 — לפני פרסום PR #40: (1) הפניית Cloudflare אחרי עדכון הבעלים, (2) תצוגה מקדימה של PR #40 (Cloudflare preview) מול Production:
# הרשמה מלאה דרך הטופס ובדיקה שהעותק של הפרופיל נשמר על משתמש ה-Auth. בלי כניסה → בלי פרופיל גלוי. משתמשי בדיקה בתיבת האפליקציה. בלי מחיקה.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"; AU="https://$PROD_REF.supabase.co/auth/v1"; PUB='sb_publishable_wwoXFH3xChSfQxHKZEbTKA_t_u5aGMP'
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
T="${GITHUB_RUN_ID:-x}"; R=""
for site in https://haim-derech-misparim.pages.dev/ https://shmulikhavivi-design.github.io/haim-derech-misparim/; do
  tag=$(echo $site | cut -d/ -f3 | cut -d. -f1 | tr -cd 'a-z'); EM="life.through.numbers333+incr$tag$T@gmail.com"; PW="Hdm-$(openssl rand -hex 8)-Aa1!"; echo "::add-mask::$PW"
  SC=$(curl -sS -m 40 -o /tmp/su.json -w '%{http_code}' -X POST -H "apikey: $PUB" -H 'Content-Type: application/json' "$AU/signup?redirect_to=$(jq -rn --arg s "$site" '$s|@uri')" -d "$(jq -nc --arg e "$EM" --arg p "$PW" '{email:$e,password:$p}')" || echo 000); sleep 2
  TH=$(roq "select coalesce((select token_hash from auth.one_time_tokens o join auth.users u on u.id=o.user_id where u.email='$EM' and o.token_type='confirmation_token' order by o.created_at desc limit 1), (select confirmation_token from auth.users where email='$EM')) t" | jq -r '.[0].t // empty'); [ -n "$TH" ] && echo "::add-mask::$TH"
  LOC=$(curl -sS -m 30 -o /dev/null -w '%{redirect_url}' "$AU/verify?token=$TH&type=signup&redirect_to=$(jq -rn --arg s "$site" '$s|@uri')" || echo -); D=$(echo "$LOC" | cut -d'#' -f1 | cut -d'?' -f1)
  R="$R | ביקשנו $site → חזר ל-$D $( [ "$D" = "$site" ] && echo ✅ || echo ❌)"
done
ann notice "i8-redirect" "הרשמה $SC$R"
PV='https://hotfix-login-messages.haim-derech-misparim.pages.dev/'
curl -sS -m 30 -o /tmp/pv.html "$PV"; HAS=$(grep -c "hdmPendingForServer" /tmp/pv.html); REF=$(grep -c "$PROD_REF" /tmp/pv.html)
ann notice "i8-preview" "תצוגה מקדימה של PR #40: מכילה את התיקון ×$HAS, מחוברת ל-Production ×$REF"
python3 -m pip install -q playwright >/dev/null && python3 -m playwright install --with-deps chromium >/dev/null 2>&1
OUT=$(SITES="$PV" ONE_ENGINE=1 T="$T" timeout 600 python3 "$HERE/incident_ui_signup.py" 2>&1 | tail -c 3000)
ann notice "i8-preview-signup" "$(echo "$OUT" | jq -c '.["chrome-pv"]' 2>/dev/null | cut -c1-1500)"
META=$(roq "select json_build_object('found', count(*), 'has_pending', bool_and(raw_user_meta_data ? 'hdm_pending'), 'profile_fields', max((select count(*) from jsonb_object_keys(raw_user_meta_data->'hdm_pending'->'profile'))), 'has_photo_in_meta', bool_or((raw_user_meta_data->'hdm_pending'->'profile') ? 'photoUrl'), 'has_id', bool_and(raw_user_meta_data->'hdm_pending'->>'id' like 'reg_%'), 'meta_bytes', max(length(raw_user_meta_data::text)), 'visible_profile', (select count(*) from public.hdm_accounts a join public.docs d on d.collection='profiles' and d.id=a.profile_id join auth.users u2 on u2.id=a.auth_user_id where u2.email like 'life.through.numbers333+incuichromepv$T%')) r from auth.users where email like 'life.through.numbers333+incuichromepv$T%'" | jq -c '.[0].r // .')
ann notice "i8-meta" "עותק הפרופיל על משתמש ה-Auth ב-Production: $META"
ann notice "prod-result" "incident8 הסתיים — משתמשי בדיקה בלבד, בלי פרופיל גלוי, בלי מחיקה"
