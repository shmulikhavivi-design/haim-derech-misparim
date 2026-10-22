#!/usr/bin/env bash
set +e +o pipefail
A="https://api.supabase.com/v1/projects/$PROD_REF"; RW="$A/database/query"
T="${GITHUB_RUN_ID:-x}"; EM="life.through.numbers333+incadm$T@gmail.com"; PW="Hdm-$(openssl rand -hex 8)-Aa1!"; echo "::add-mask::$PW"; U=$(cat /proc/sys/kernel/random/uuid)
Q="insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change, email_change_token_current, phone_change, phone_change_token, reauthentication_token)
 values ('00000000-0000-0000-0000-000000000000', '$U', 'authenticated', 'authenticated', '$EM', extensions.crypt('$PW', extensions.gen_salt('bf')), now(), '{\"provider\":\"email\",\"providers\":[\"email\"]}', '{}', now(), now(), '', '', '', '', '', '', '', '');
 insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at) values (gen_random_uuid(), '$U', '$U', 'email', json_build_object('sub', '$U', 'email', '$EM', 'email_verified', true)::jsonb, now(), now(), now()); select 1"
curl -sS -m 60 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$RW" -d "$(jq -nc --arg q "$Q" '{query:$q}')" >/dev/null
python3 -m pip install -q playwright >/dev/null && python3 -m playwright install --with-deps chromium >/dev/null 2>&1
OUT=$(SITE='https://feature-admin-panel.haim-derech-misparim.pages.dev/' T_EM="$EM" T_PW="$PW" timeout 300 python3 "$HERE/admin_preview_check.py" 2>&1 | tail -c 1500)
ann notice "admpv" "תצוגה מקדימה של PR #41 מול Production, משתמש בדיקה רגיל: $OUT"
ann notice "prod-result" "adminpreview הסתיים — משתמש בדיקה אחד, בלי פרופיל, בלי נתונים"
