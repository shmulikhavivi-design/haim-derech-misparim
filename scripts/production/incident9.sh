#!/usr/bin/env bash
# incident9 — אחרי מיזוג PR #40 (אישור הבעלים 19:20): גרסה חדשה בשתי הכתובות, הרשמה מלאה דרך הטופס (בלי כניסה → בלי פרופיל גלוי),
# כניסה בדפדפן עם משתמש בדיקה מאושר בלי פרופיל (לא נוצר פרופיל), שגיאות דפדפן, וחשבונות קיימים (עסקה שמבוטלת). בלי חיוב, בלי מחיקה.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"; RW="$A/database/query"
clean(){ sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g; s/eyJ[A-Za-z0-9._-]+/<jwt>/g'; }
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
rwq(){ curl -sS -m 120 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
FP="select json_build_object('users',(select count(*) from auth.users),'profiles',(select count(*) from public.docs where collection='profiles'),'subs',(select string_agg(plan||'/'||status||'/'||auto_renew, ',') from public.hdm_subscriptions),'payments',(select count(*) from public.hdm_payments),'charges',(select count(*) from public.hdm_renewal_charges),'h',(select md5(string_agg(id||data::text, ',' order by id)) from public.docs where collection='profiles')) r"
PRE=$(roq "$FP" | jq -c '.[0].r')
# 1. גרסה חדשה בשתי הכתובות (עד 12 דקות)
for i in $(seq 1 72); do
  G=$(curl -sS -m 20 "https://shmulikhavivi-design.github.io/haim-derech-misparim/?v=$i$RANDOM" | grep -c hdmPendingForServer); C=$(curl -sS -m 20 "https://haim-derech-misparim.pages.dev/?v=$i$RANDOM" | grep -c hdmPendingForServer)
  [ "$G" -ge 1 ] && [ "$C" -ge 1 ] && break; sleep 10; done
ann notice "i9-version" "גרסה חדשה — GitHub: $([ "$G" -ge 1 ] && echo ✅ || echo ❌) | Cloudflare: $([ "$C" -ge 1 ] && echo ✅ || echo ❌) (אחרי $((i*10)) שניות)"
python3 -m pip install -q playwright >/dev/null && python3 -m playwright install --with-deps chromium >/dev/null 2>&1
T="${GITHUB_RUN_ID:-x}"
# 2. הרשמה מלאה דרך הטופס בשתי הכתובות (Chrome + אייפון מדומה) — בלי כניסה
OUT=$(T="$T" timeout 900 python3 "$HERE/incident_ui_signup.py" 2>&1 | tail -c 6000)
ann notice "i9-signup" "$(echo "$OUT" | jq -c 'to_entries | map({(.key): ((.value.steps[-1] // "") | .[0:60]) , ((.key)+"_errors"): (.value.errors|length), ((.key)+"_http"): ((.value.net[0] // "") | .[0:3])}) | add' 2>/dev/null | cut -c1-1800)"
META=$(roq "select json_build_object('signups', count(*), 'with_profile_copy', count(*) filter (where raw_user_meta_data ? 'hdm_pending'), 'photo_in_copy', count(*) filter (where (raw_user_meta_data->'hdm_pending'->'profile') ? 'photoUrl'), 'confirmation_sent', count(*) filter (where confirmation_sent_at is not null)) r from auth.users where email like 'life.through.numbers333+incui%$T@gmail.com'" | jq -c '.[0].r')
ann notice "i9-meta" "בהרשמות של הבדיקה: $META"
# 3. כניסה בדפדפן לשתי הכתובות עם משתמש בדיקה מאושר בלי פרופיל — לא נוצר פרופיל
EM="life.through.numbers333+incl$T@gmail.com"; PW="Hdm-$(openssl rand -hex 8)-Aa1!"; echo "::add-mask::$PW"; U=$(cat /proc/sys/kernel/random/uuid)
rwq "insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change, email_change_token_current, phone_change, phone_change_token, reauthentication_token)
 values ('00000000-0000-0000-0000-000000000000', '$U', 'authenticated', 'authenticated', '$EM', extensions.crypt('$PW', extensions.gen_salt('bf')), now(), '{\"provider\":\"email\",\"providers\":[\"email\"]}', '{}', now(), now(), '', '', '', '', '', '', '', '');
 insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at) values (gen_random_uuid(), '$U', '$U', 'email', json_build_object('sub', '$U', 'email', '$EM', 'email_verified', true)::jsonb, now(), now(), now()); select 1" >/dev/null
L=""
for S in https://shmulikhavivi-design.github.io/haim-derech-misparim/ https://haim-derech-misparim.pages.dev/; do
  O=$(SITE="$S" T_EM="$EM" T_PW="$PW" timeout 300 python3 "$HERE/incident_login.py" 2>&1 | tail -c 4000)
  L="$L | $(echo $S | cut -d/ -f3 | cut -d. -f1): $(echo "$O" | jq -c '{session: .logged_in, console_errors: (.console|length), page_errors: (.pageerr|length), bad_requests: .bad_requests, screen: ([.visible_ids[] | select(. == "terms-gate" or . == "login-screen" or . == "screen-register")])}' 2>/dev/null | clean)"
done
ann notice "i9-login" "כניסה בדפדפן (משתמש בדיקה מאושר בלי פרופיל):$L | פרופיל נוצר: $(roq "select count(*) n from public.hdm_accounts a join public.docs d on d.collection='profiles' and d.id=a.profile_id where a.auth_user_id='$U'" | jq -r '.[0].n')"
# 4. חשבונות קיימים: מה שהאפליקציה עושה אחרי כניסה, לכל חשבון קיים, בעסקה שמבוטלת
source "$HERE/incident3.sh" >/dev/null 2>&1
POST=$(roq "$FP" | jq -c '.[0].r')
ann notice "i9-existing" "לפני/אחרי (חוץ ממשתמשי הבדיקה): פרופילים, מנויים ותשלומים $(python3 -c "import json,sys;a=json.loads(sys.argv[1]);b=json.loads(sys.argv[2]);print('זהים ✅' if all(a[k]==b[k] for k in ('profiles','subs','payments','charges','h')) else 'שונים ❌ '+str(a)+' '+str(b))" "$PRE" "$POST") | משתמשי Auth: $(echo "$PRE" | jq .users) → $(echo "$POST" | jq .users) (משתמשי בדיקה בלבד)"
ann notice "prod-result" "incident9 הסתיים — בלי חיוב, בלי פרופיל גלוי, בלי מחיקה"
