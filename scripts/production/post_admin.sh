#!/usr/bin/env bash
# postadmin — אחרי מיזוג PR #41: הגרסה החדשה בשתי הכתובות; משתמש רגיל לא רואה ניהול והשרת מסרב; הרשמה וכניסה עובדות; חשבונות קיימים תקינים. בלי חיוב, בלי מחיקה.
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"; RW="$A/database/query"
clean(){ sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g; s/eyJ[A-Za-z0-9._-]+/<jwt>/g'; }
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
FP="select json_build_object('profiles',(select count(*) from public.docs where collection='profiles'),'subs',(select md5(string_agg(profile_id||plan||status||coalesce(to_jsonb(s)->>'auto_renew',''),',')) from public.hdm_subscriptions s),'payments',(select count(*) from public.hdm_payments),'h',(select md5(string_agg(id||data::text, ',' order by id)) from public.docs where collection='profiles')) r"
PRE=$(roq "$FP" | jq -c '.[0].r')
for i in $(seq 1 72); do G=$(curl -sS -m 20 "https://shmulikhavivi-design.github.io/haim-derech-misparim/?v=$i$RANDOM" | grep -c hdmOpenAdmin); C=$(curl -sS -m 20 "https://haim-derech-misparim.pages.dev/?v=$i$RANDOM" | grep -c hdmOpenAdmin); [ "$G" -ge 1 ] && [ "$C" -ge 1 ] && break; sleep 10; done
ann notice "pa-1-version" "גרסה עם לוח הניהול — GitHub: $([ "$G" -ge 1 ] && echo ✅ || echo ❌) | Cloudflare: $([ "$C" -ge 1 ] && echo ✅ || echo ❌) (אחרי $((i*10)) שניות)"
python3 -m pip install -q playwright >/dev/null && python3 -m playwright install --with-deps chromium >/dev/null 2>&1
T="${GITHUB_RUN_ID:-x}"; EM="life.through.numbers333+incpa$T@gmail.com"; PW="Hdm-$(openssl rand -hex 8)-Aa1!"; echo "::add-mask::$PW"; U=$(cat /proc/sys/kernel/random/uuid)
Q="insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change, email_change_token_current, phone_change, phone_change_token, reauthentication_token)
 values ('00000000-0000-0000-0000-000000000000', '$U', 'authenticated', 'authenticated', '$EM', extensions.crypt('$PW', extensions.gen_salt('bf')), now(), '{\"provider\":\"email\",\"providers\":[\"email\"]}', '{}', now(), now(), '', '', '', '', '', '', '', '');
 insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at) values (gen_random_uuid(), '$U', '$U', 'email', json_build_object('sub', '$U', 'email', '$EM', 'email_verified', true)::jsonb, now(), now(), now()); select 1"
curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --arg q "$Q" '{query:$q}')" >/dev/null
L=""; for S in https://shmulikhavivi-design.github.io/haim-derech-misparim/ https://haim-derech-misparim.pages.dev/; do
  O=$(SITE="$S" T_EM="$EM" T_PW="$PW" timeout 300 python3 "$HERE/admin_preview_check.py" 2>&1 | tail -c 1000)
  L="$L | $(echo $S | cut -d/ -f3 | cut -d. -f1): $O"; done
ann notice "pa-2-regular-user" "משתמש רגיל (בדיקה) באתר החי:$L"
OUT=$(ONE_ENGINE=1 T="$T" timeout 600 python3 "$HERE/incident_ui_signup.py" 2>&1 | tail -c 4000)
ann notice "pa-3-signup" "הרשמה דרך הטופס באתר החי: $(echo "$OUT" | jq -c 'to_entries | map({(.key): ((.value.steps[-1] // "") | .[0:45]), ((.key)+"_err"): (.value.errors|length)}) | add' 2>/dev/null)"
source "$HERE/incident3.sh" >/tmp/i3.out 2>&1
ann notice "pa-4-existing" "חשבונות קיימים אחרי כניסה (בוטל): $(grep -o 'i3-errors::שגיאות: .*' /tmp/i3.out | head -1 | sed 's/i3-errors:://' | cut -c1-300)"
POST=$(roq "$FP" | jq -c '.[0].r')
ann notice "pa-5-unchanged" "פרופילים, מנויים ותשלומים: $(python3 -c "import json,sys;a=json.loads(sys.argv[1]);b=json.loads(sys.argv[2]);print('זהים ✅' if a==b else 'שונים ❌ '+str(a)+' → '+str(b))" "$PRE" "$POST")"
ann notice "prod-result" "postadmin הסתיים — משתמשי בדיקה בלבד, בלי חיוב, בלי מחיקה"
