#!/usr/bin/env bash
# incident2 — המשך בירור תקלת הכניסה: נתוני Auth במסד (קריאה בלבד), משתמש בדיקה מאושר אחד (תיבת האפליקציה +incb), כניסה אמיתית לאתר החי בדפדפן.
A="https://api.supabase.com/v1/projects/$PROD_REF"; RO="$A/database/query/read-only"; RW="$A/database/query"
clean(){ sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g; s/eyJ[A-Za-z0-9._-]+/<jwt>/g'; }
roq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RO" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
rwq(){ curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --arg q "$1" '{query:$q}')"; }
Q="select json_build_object(
 'users', (select count(*) from auth.users),
 'by_created_day', (select json_object_agg(d, n) from (select to_char(created_at at time zone 'Asia/Jerusalem','DD.MM') d, count(*) n from auth.users group by 1 order by 1) x),
 'confirmed', (select count(*) from auth.users where email_confirmed_at is not null),
 'unconfirmed_created_48h', (select count(*) from auth.users where email_confirmed_at is null and created_at > now()-interval '48 hours'),
 'last_signin_by_day', (select json_object_agg(d, n) from (select to_char(last_sign_in_at at time zone 'Asia/Jerusalem','DD.MM') d, count(*) n from auth.users where last_sign_in_at is not null group by 1 order by 1) x),
 'null_token_cols', (select count(*) from auth.users where confirmation_token is null or recovery_token is null or email_change_token_new is null or email_change is null),
 'without_identity', (select count(*) from auth.users u where not exists (select 1 from auth.identities i where i.user_id = u.id)),
 'audit_48h', (select coalesce(json_object_agg(a, n), '{}') from (select payload->>'action' a, count(*) n from auth.audit_log_entries where created_at > now()-interval '48 hours' group by 1) x),
 'audit_last', (select to_char(max(created_at) at time zone 'Asia/Jerusalem','DD.MM HH24:MI') from auth.audit_log_entries),
 'accounts', (select count(*) from public.hdm_accounts), 'users_without_account', (select count(*) from auth.users u where not exists (select 1 from public.hdm_accounts a where a.auth_user_id = u.id)),
 'profiles', (select count(*) from public.docs where collection='profiles'),
 'consents_by_version', (select coalesce(json_object_agg(version, n), '{}') from (select version, count(*) n from public.hdm_consents group by 1) x),
 'required_terms', (select public.hdm_required_terms_version()),
 'markers_48h', (select coalesce(json_agg(version || ' ' || to_char(installed_at at time zone 'Asia/Jerusalem','DD.MM HH24:MI') order by installed_at), '[]') from public.hdm_release_marker where installed_at > now()-interval '48 hours'),
 'auth_users_triggers', (select coalesce(json_agg(tgname), '[]') from pg_trigger where tgrelid = 'auth.users'::regclass and not tgisinternal),
 'auth_hooks_fns', (select coalesce(json_agg(proname), '[]') from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and proname ilike '%hook%')
) r"
ann notice "i2-db" "$(roq "$Q" | jq -c '.[0].r // .' | clean | cut -c1-2000)"
# משתמש בדיקה מאושר — נוצר כמו ש-Auth יוצר (כל עמודות הטוקנים ריקות ולא NULL, וזהות email)
T="${GITHUB_RUN_ID:-x}"; EM="life.through.numbers333+incb$T@gmail.com"; PW="Hdm-$(openssl rand -hex 8)-Aa1!"; echo "::add-mask::$PW"
U=$(cat /proc/sys/kernel/random/uuid)
CQ="insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change, email_change_token_current, phone_change, phone_change_token, reauthentication_token)
 values ('00000000-0000-0000-0000-000000000000', '$U', 'authenticated', 'authenticated', '$EM', extensions.crypt('$PW', extensions.gen_salt('bf')), now(),
  '{\"provider\":\"email\",\"providers\":[\"email\"]}', '{\"name\":\"בדיקת תקלה\"}', now(), now(), '', '', '', '', '', '', '', '');
 insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
 values (gen_random_uuid(), '$U', '$U', 'email', json_build_object('sub', '$U', 'email', '$EM', 'email_verified', true)::jsonb, now(), now(), now());
 select 'created' r"
CR=$(rwq "$CQ" | jq -c '.' | clean | cut -c1-300)
ann notice "i2-testuser" "משתמש בדיקה מאושר (+incb$T): $CR"
PUB='sb_publishable_wwoXFH3xChSfQxHKZEbTKA_t_u5aGMP'
R=$(curl -sS -m 40 -o /tmp/li.json -w '%{http_code}' -X POST -H "apikey: $PUB" -H 'Content-Type: application/json' "https://$PROD_REF.supabase.co/auth/v1/token?grant_type=password" -d "$(jq -nc --arg e "$EM" --arg p "$PW" '{email:$e,password:$p}')" || echo 000)
ann notice "i2-api-login" "כניסה ישירה ל-Auth עם משתמש מאושר: HTTP $R $(jq -c '{session: (.access_token != null), code: (.error_code // .code), msg: (.msg // .error_description // .message)}' /tmp/li.json | clean)"
python3 -m pip install -q playwright >/dev/null && python3 -m playwright install --with-deps chromium >/dev/null 2>&1 || stop "התקנת הדפדפן נכשלה"
for S in https://shmulikhavivi-design.github.io/haim-derech-misparim/ https://haim-derech-misparim.pages.dev/; do
  OUT=$(SITE="$S" T_EM="$EM" T_PW="$PW" python3 "$HERE/incident_login.py" 2>&1 | tail -c 3000 | clean)
  ann notice "i2-browser-$(echo $S | cut -d/ -f3 | cut -d. -f1-2)" "$OUT"
done
TU=$(roq "select json_build_object('last_sign_in', (select last_sign_in_at is not null from auth.users where id='$U'), 'account', (select count(*) from public.hdm_accounts where auth_user_id='$U'), 'consent', (select count(*) from public.hdm_consents where user_id='$U')) r" | jq -c '.[0].r')
ann notice "i2-after" "משתמש הבדיקה אחרי הכניסה: $TU"
ann notice "prod-result" "incident2 הסתיים — קריאה בלבד + משתמש בדיקה מאושר אחד; לא נמחק כלום"
